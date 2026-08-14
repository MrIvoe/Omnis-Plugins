import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/smart_playlist_rule.dart';

/// A bundled plugin that suggests smart autoplay queues based on mood or
/// genre.
///
/// Implements [IQueueBuilder] and registers itself under that interface —
/// see the interface's own doc for why registration order relative to
/// [QueuePresetPlugin] (also an `IQueueBuilder`) matters: this plugin's
/// curated mood-tag match is meant to win over that plugin's objective
/// BPM/genre fallback whenever this one actually finds something.
class SmartPlaylistPlugin extends MusicPlugin implements IQueueBuilder {
  static const _moodsStorageKey = 'moods';
  static const _defaultMoods = ['Chill', 'Focus', 'Workout'];

  /// User-editable mood vocabulary — tap this plugin in the Plugins list
  /// to add/remove entries. Matched against `BaseTrack.mood` (from manual
  /// tagging or `MetadataEnrichmentPlugin`'s Last.fm lookup).
  List<String> get moods =>
      storage.getStringList(_moodsStorageKey) ?? _defaultMoods;

  Future<void> setMoods(List<String> moods) =>
      storage.setStringList(_moodsStorageKey, moods);

  @override
  List<String> get supportedQueries => moods;

  List<BaseTrack> buildQueue(List<BaseTrack> tracks, {String? mood}) {
    final requestedMood = mood ?? moods.first;
    return tracks.where((track) {
      final matched = track.mood?.toLowerCase() ?? '';
      return matched.contains(requestedMood.toLowerCase()) || requestedMood.toLowerCase() == 'focus' && track.genres.any((g) => g.toLowerCase().contains('ambient'));
    }).toList();
  }

  @override
  List<BaseTrack> buildQueueFor(List<BaseTrack> tracks, String query) =>
      buildQueue(tracks, mood: query);

  // --- Real rule-based smart playlists (§42) — additive to, not a
  // --- replacement of, the mood-vocabulary matching above: that serves
  // --- the Moods tab's ephemeral "build me something in this mood"
  // --- flow, this is a separate, *saved, named* playlist whose
  // --- membership is a real ALL/ANY/NONE condition tree, recomputed
  // --- fresh against the library every time it's played rather than a
  // --- fixed list of track ids the way `PlaylistStore`'s ordinary
  // --- playlists are. See `smart_playlist_rule.dart` for the model.

  static const _rulesStorageKey = 'smart_rules_json';

  /// Every saved smart playlist rule, decoded per-entry defensively —
  /// the same "one corrupted record can't wipe the rest" contract every
  /// JSON-backed store in this app follows.
  List<SmartPlaylistRule> get savedRules {
    final raw = storage.getString(_rulesStorageKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final rules = <SmartPlaylistRule>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final rule = SmartPlaylistRule.fromJson(Map<String, dynamic>.from(entry));
        if (rule != null) rules.add(rule);
      }
      return rules;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistRules(List<SmartPlaylistRule> rules) =>
      storage.setString(
          _rulesStorageKey, jsonEncode(rules.map((r) => r.toJson()).toList()));

  /// Saves [rule] — adds it if [SmartPlaylistRule.id] is new, replaces
  /// the existing one with that id otherwise (an edit, not a duplicate).
  Future<void> saveRule(SmartPlaylistRule rule) async {
    final rules = savedRules.where((r) => r.id != rule.id).toList()..add(rule);
    await _persistRules(rules);
  }

  /// Deletes the saved rule with [ruleId], if one exists. A harmless
  /// no-op otherwise — matches `FavoritesPlugin`/`RatingsPlugin`'s
  /// existing "removing something already gone is not an error"
  /// convention.
  Future<void> deleteRule(String ruleId) async {
    final rules = savedRules;
    final filtered = rules.where((r) => r.id != ruleId).toList();
    if (filtered.length == rules.length) return;
    await _persistRules(filtered);
  }

  /// Builds a queue from the saved rule with id [ruleId], evaluated
  /// fresh against [tracks]. Returns an empty list (never throws) for
  /// an unknown rule id, matching every other "no match" path in this
  /// app. Reaches rating data through [IRatingsProvider] — a
  /// capability lookup, not a direct reference to `RatingsPlugin`, so
  /// this plugin works whether or not Ratings happens to be enabled
  /// (a `rating:` condition in the rule just never matches without it,
  /// the same "matches nothing without a supplied lookup" contract
  /// `RuleCondition.matches` documents).
  List<BaseTrack> buildQueueForRule(List<BaseTrack> tracks, String ruleId) {
    SmartPlaylistRule? rule;
    for (final candidate in savedRules) {
      if (candidate.id == ruleId) {
        rule = candidate;
        break;
      }
    }
    if (rule == null) return const [];
    final ratingsProvider = context?.services.get<IRatingsProvider>();
    return rule.apply(tracks, ratingOf: ratingsProvider?.ratingOf);
  }

  @override
  String get id => 'smart_playlist';

  @override
  String get name => 'Smart Playlist';

  @override
  String get description => 'Builds mood-based queues for autoplay and playlist suggestions.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IQueueBuilder, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _SmartPlaylistSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    context?.services.register(IQueueBuilder, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IQueueBuilder, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IQueueBuilder, this);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. Lets a user add/remove entries from the mood vocabulary the
/// Moods tab shows and this plugin matches against `BaseTrack.mood`.
class _SmartPlaylistSettings extends StatefulWidget {
  final SmartPlaylistPlugin plugin;

  const _SmartPlaylistSettings({required this.plugin});

  @override
  State<_SmartPlaylistSettings> createState() =>
      _SmartPlaylistSettingsState();
}

/// One condition row's mutable UI state in the "create a rule" form —
/// [RuleCondition] itself is immutable (it's the saved/evaluated model),
/// this is the editable draft a `TextField`/two dropdowns feed before
/// [RuleCondition] is actually constructed on save.
class _EditableCondition {
  RuleField field = RuleField.artist;
  RuleOperator operator = RuleOperator.contains;
  final TextEditingController valueController = TextEditingController();
}

class _SmartPlaylistSettingsState extends State<_SmartPlaylistSettings> {
  final _controller = TextEditingController();

  final _ruleNameController = TextEditingController();
  RuleMatchType _matchType = RuleMatchType.all;
  final List<_EditableCondition> _editableConditions = [_EditableCondition()];
  bool _buildingRule = false;
  String? _playFeedback;

  @override
  void dispose() {
    _controller.dispose();
    _ruleNameController.dispose();
    for (final c in _editableConditions) {
      c.valueController.dispose();
    }
    super.dispose();
  }

  static String _fieldLabel(RuleField field) => switch (field) {
        RuleField.title => 'Title',
        RuleField.artist => 'Artist',
        RuleField.album => 'Album',
        RuleField.genre => 'Genre',
        RuleField.mood => 'Mood',
        RuleField.year => 'Year',
        RuleField.rating => 'Rating',
      };

  /// String fields only ever support `contains` in this UI (matching
  /// `RuleCondition.matches`'s own behavior — an `equals` on a string
  /// field is technically supported by the model but adds little for a
  /// simple builder); numeric fields (`year`/`rating`) get the full
  /// comparison set.
  static List<RuleOperator> _operatorsFor(RuleField field) =>
      field == RuleField.year || field == RuleField.rating
          ? const [
              RuleOperator.equals,
              RuleOperator.greaterThanOrEqual,
              RuleOperator.lessThanOrEqual,
              RuleOperator.greaterThan,
              RuleOperator.lessThan,
            ]
          : const [RuleOperator.contains];

  static String _operatorLabel(RuleOperator op) => switch (op) {
        RuleOperator.contains => 'contains',
        RuleOperator.equals => '=',
        RuleOperator.greaterThanOrEqual => '>=',
        RuleOperator.lessThanOrEqual => '<=',
        RuleOperator.greaterThan => '>',
        RuleOperator.lessThan => '<',
      };

  Future<void> _saveRule() async {
    final name = _ruleNameController.text.trim();
    if (name.isEmpty) return;
    final conditions = _editableConditions
        .where((c) => c.valueController.text.trim().isNotEmpty)
        .map((c) => RuleCondition(
              field: c.field,
              operator: c.operator,
              value: c.valueController.text.trim(),
            ))
        .toList();
    if (conditions.isEmpty) return;
    await widget.plugin.saveRule(SmartPlaylistRule(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      matchType: _matchType,
      conditions: conditions,
    ));
    _ruleNameController.clear();
    for (final c in _editableConditions) {
      c.valueController.dispose();
    }
    if (!mounted) return;
    setState(() {
      _matchType = RuleMatchType.all;
      _editableConditions
        ..clear()
        ..add(_EditableCondition());
    });
  }

  Future<void> _deleteRule(String ruleId) async {
    await widget.plugin.deleteRule(ruleId);
    if (mounted) setState(() {});
  }

  Future<void> _playRule(SmartPlaylistRule rule) async {
    final context = widget.plugin.context;
    if (context == null) return;
    setState(() {
      _buildingRule = true;
      _playFeedback = null;
    });
    final library = await context.loadLibraryTracks();
    final queue = widget.plugin.buildQueueForRule(library, rule.id);
    if (!mounted) return;
    if (queue.isEmpty) {
      setState(() {
        _buildingRule = false;
        _playFeedback = '"${rule.name}" has no matching tracks right now.';
      });
      return;
    }
    await context.setQueue(queue);
    await context.play();
    if (!mounted) return;
    setState(() {
      _buildingRule = false;
      _playFeedback = 'Playing ${queue.length} track'
          '${queue.length == 1 ? '' : 's'} from "${rule.name}".';
    });
  }

  Future<void> _add() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    final current = widget.plugin.moods;
    if (current.any((m) => m.toLowerCase() == value.toLowerCase())) {
      _controller.clear();
      return;
    }
    await widget.plugin.setMoods([...current, value]);
    _controller.clear();
    if (mounted) setState(() {});
  }

  Future<void> _remove(String mood) async {
    final current = widget.plugin.moods;
    if (current.length <= 1) return; // always leave at least one
    await widget.plugin.setMoods(current.where((m) => m != mood).toList());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final moods = widget.plugin.moods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mood vocabulary', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Shown on the Moods tab, and matched against a track\'s mood '
          '(from manual tagging or Last.fm enrichment) when building an '
          'autoplay queue.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final mood in moods)
              Chip(
                label: Text(mood),
                onDeleted: moods.length > 1 ? () => _remove(mood) : null,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'Add a mood',
                  hintText: 'e.g. "Party", "Rainy day"',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _add, child: const Text('Add')),
          ],
        ),
        const Divider(height: 32),
        Text('Smart playlists', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Saved rules with real ALL/ANY/NONE conditions — membership is '
          'recomputed fresh against your library every time you play one, '
          'unlike an ordinary playlist\'s fixed track list.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ..._buildSavedRules(),
        if (_playFeedback != null) ...[
          const SizedBox(height: 4),
          Text(_playFeedback!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        Text('Create a smart playlist',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _ruleNameController,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. "Recent Rock"',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('Match'),
            const SizedBox(width: 8),
            DropdownButton<RuleMatchType>(
              value: _matchType,
              items: RuleMatchType.values
                  .map((m) => DropdownMenuItem(
                        value: m,
                        child: Text(m.name.toUpperCase()),
                      ))
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _matchType = value);
              },
            ),
            const SizedBox(width: 4),
            const Text('of the following conditions:'),
          ],
        ),
        const SizedBox(height: 8),
        for (final condition in _editableConditions) _buildConditionRow(condition),
        TextButton(
          onPressed: () =>
              setState(() => _editableConditions.add(_EditableCondition())),
          child: const Text('Add condition'),
        ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _saveRule, child: const Text('Save')),
      ],
    );
  }

  List<Widget> _buildSavedRules() {
    final rules = widget.plugin.savedRules;
    if (rules.isEmpty) {
      return [
        Text('No smart playlists yet.',
            style: Theme.of(context).textTheme.bodySmall),
      ];
    }
    return [
      for (final rule in rules)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rule.name),
                    Text(
                      '${rule.matchType.name.toUpperCase()} of '
                      '${rule.conditions.length} condition'
                      '${rule.conditions.length == 1 ? '' : 's'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _buildingRule ? null : () => _playRule(rule),
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Play',
              ),
              IconButton(
                onPressed: () => _deleteRule(rule.id),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
              ),
            ],
          ),
        ),
    ];
  }

  Widget _buildConditionRow(_EditableCondition condition) {
    final availableOperators = _operatorsFor(condition.field);
    if (!availableOperators.contains(condition.operator)) {
      condition.operator = availableOperators.first;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          DropdownButton<RuleField>(
            value: condition.field,
            items: RuleField.values
                .map((f) => DropdownMenuItem(
                      value: f,
                      child: Text(_fieldLabel(f)),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => condition.field = value);
            },
          ),
          const SizedBox(width: 8),
          DropdownButton<RuleOperator>(
            value: condition.operator,
            items: availableOperators
                .map((o) => DropdownMenuItem(
                      value: o,
                      child: Text(_operatorLabel(o)),
                    ))
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => condition.operator = value);
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: condition.valueController,
              decoration: const InputDecoration(
                hintText: 'Value',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_editableConditions.length > 1)
            IconButton(
              onPressed: () => setState(() {
                _editableConditions.remove(condition);
                condition.valueController.dispose();
              }),
              icon: const Icon(Icons.close),
              tooltip: 'Remove condition',
            ),
        ],
      ),
    );
  }
}
