import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
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

  /// Item 42's "no import/export" gap — every currently saved rule as
  /// one shareable JSON payload. Thin wrapper: the actual serialization
  /// lives in [exportRulesToJson], kept a pure function in
  /// `smart_playlist_rule.dart` so it's testable without a plugin
  /// instance/storage at all.
  String exportRulesJson() => exportRulesToJson(savedRules);

  /// Decodes [raw] (as produced by [exportRulesJson], though any
  /// correctly-shaped payload works) and persists whatever rules parsed
  /// successfully, replacing an existing rule with the same id (an
  /// import re-applying a previously-exported rule is an update, not a
  /// duplicate — same by-id semantics [saveRule] already has) or adding
  /// a new one otherwise. Returns how many rules were actually
  /// imported, so the caller can report a real count rather than just
  /// "done." A completely malformed [raw] imports zero rules rather
  /// than throwing, matching [importRulesFromJson]'s own contract.
  Future<int> importRulesJson(String raw) async {
    final incoming = importRulesFromJson(raw);
    if (incoming.isEmpty) return 0;
    for (final rule in incoming) {
      await saveRule(rule);
    }
    return incoming.length;
  }

  /// Builds a queue from the saved rule with id [ruleId], evaluated
  /// fresh against [tracks]. Returns an empty list (never throws) for
  /// an unknown rule id, matching every other "no match" path in this
  /// app. Reaches rating/favorite data through [IRatingsProvider]/
  /// [IFavoritesProvider] — capability lookups, not a direct reference
  /// to `RatingsPlugin`/`FavoritesPlugin`, so this plugin works whether
  /// or not either is enabled (a `rating:`/`favorite:` condition in the
  /// rule just never matches without its provider, the same "matches
  /// nothing without a supplied lookup" contract `RuleCondition.matches`
  /// documents).
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
    final favoritesProvider = context?.services.get<IFavoritesProvider>();
    final thumbsProvider = context?.services.get<IThumbsProvider>();
    return rule.apply(
      tracks,
      ratingOf: ratingsProvider?.ratingOf,
      favoriteOf: favoritesProvider?.isFavorite,
      thumbOf: thumbsProvider?.thumbOf,
    );
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

  /// The id of the rule currently being edited, or `null` when the form
  /// is building a brand-new rule. Reusing the *same* id on save is what
  /// turns `_saveRule` into an in-place update — `SmartPlaylistPlugin
  /// .saveRule` already replaces-by-id, so editing needed no new
  /// plugin-level method at all, just the UI remembering which rule (if
  /// any) it's currently populated from.
  String? _editingRuleId;

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
        RuleField.favorite => 'Favorite',
        RuleField.thumbUp => 'Thumbs up',
        RuleField.thumbDown => 'Thumbs down',
        RuleField.bpm => 'BPM',
        RuleField.duration => 'Duration (seconds)',
        RuleField.bitrate => 'Bitrate (kbps)',
        RuleField.codec => 'Format',
      };

  /// String fields support `contains` and `equals` — `RuleCondition
  /// .matches` has always evaluated `equals` correctly for a string
  /// field (case-insensitive exact match, same as `contains`'s own
  /// case-insensitivity), this was previously just a builder-UI
  /// restriction rather than a model limitation. `equals` listed second
  /// since `contains` is the more commonly useful choice for free-text
  /// fields and stays the default for a newly added condition row
  /// (`_EditableCondition.operator`'s initial value). Numeric fields
  /// (`year`/`rating`) get the full comparison set. `favorite` only
  /// ever uses `equals` — the other operators don't mean anything for a
  /// boolean field, matching `RuleCondition._matchesBoolean`'s own
  /// contract.
  static List<RuleOperator> _operatorsFor(RuleField field) {
    if (field == RuleField.year ||
        field == RuleField.rating ||
        field == RuleField.bpm ||
        field == RuleField.duration ||
        field == RuleField.bitrate) {
      return const [
        RuleOperator.equals,
        RuleOperator.greaterThanOrEqual,
        RuleOperator.lessThanOrEqual,
        RuleOperator.greaterThan,
        RuleOperator.lessThan,
      ];
    }
    if (field == RuleField.favorite ||
        field == RuleField.thumbUp ||
        field == RuleField.thumbDown ||
        field == RuleField.codec) {
      return const [RuleOperator.equals];
    }
    return const [RuleOperator.contains, RuleOperator.equals];
  }

  static bool _isBooleanField(RuleField field) =>
      field == RuleField.favorite ||
      field == RuleField.thumbUp ||
      field == RuleField.thumbDown;

  /// (true-value label, false-value label) for a boolean field's value
  /// dropdown — field-specific wording ("Favorited"/"Thumbed up") reads
  /// far better than a generic "True"/"False" for these.
  static (String, String) _booleanLabels(RuleField field) => switch (field) {
        RuleField.favorite => ('Favorited', 'Not favorited'),
        RuleField.thumbUp => ('Thumbed up', 'Not thumbed up'),
        RuleField.thumbDown => ('Thumbed down', 'Not thumbed down'),
        _ => ('True', 'False'),
      };

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
      // Reusing the id being edited makes this an in-place update
      // (SmartPlaylistPlugin.saveRule replaces-by-id); a fresh
      // timestamp id when not editing makes it a genuinely new rule.
      id: _editingRuleId ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      matchType: _matchType,
      conditions: conditions,
    ));
    for (final c in _editableConditions) {
      c.valueController.dispose();
    }
    _resetForm();
  }

  /// Populates the form from [rule] instead of a blank state, and marks
  /// it as an edit-in-place rather than a new rule — the exact form the
  /// rule was originally built from is what a user expects to see again,
  /// not an empty one they'd need to reconstruct by hand just to change
  /// one condition.
  void _editRule(SmartPlaylistRule rule) {
    for (final c in _editableConditions) {
      c.valueController.dispose();
    }
    setState(() {
      _editingRuleId = rule.id;
      _ruleNameController.text = rule.name;
      _matchType = rule.matchType;
      _editableConditions
        ..clear()
        ..addAll(rule.conditions.map((c) => _EditableCondition()
          ..field = c.field
          ..operator = c.operator
          ..valueController.text = c.value));
      if (_editableConditions.isEmpty) {
        _editableConditions.add(_EditableCondition());
      }
    });
  }

  void _cancelEdit() {
    for (final c in _editableConditions) {
      c.valueController.dispose();
    }
    setState(_resetFormState);
  }

  void _resetForm() {
    if (!mounted) return;
    setState(_resetFormState);
  }

  /// Shared by [_saveRule] (after a successful save) and [_cancelEdit]
  /// (discarding in-progress changes) — both return the form to the
  /// same blank, not-editing state. Callers dispose the *old*
  /// `_editableConditions`' controllers themselves before calling this,
  /// since [_saveRule] needs them alive slightly longer (to build the
  /// saved [RuleCondition]s from their text) than [_cancelEdit] does.
  void _resetFormState() {
    _editingRuleId = null;
    _ruleNameController.clear();
    _matchType = RuleMatchType.all;
    _editableConditions
      ..clear()
      ..add(_EditableCondition());
  }

  Future<void> _deleteRule(String ruleId) async {
    await widget.plugin.deleteRule(ruleId);
    if (ruleId == _editingRuleId) _cancelEdit();
    if (mounted) setState(() {});
  }

  /// Item 42's "no import/export" gap, export half — shows every saved
  /// rule as one JSON payload the user can copy elsewhere (another
  /// install, a backup note) via the clipboard, deliberately not a
  /// file save — this package has no `file_picker` dependency, and
  /// adding one just for this would be a heavier lift than the feature
  /// needs.
  Future<void> _exportRules() async {
    final json = widget.plugin.exportRulesJson();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export smart playlists'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(json,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: json));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy to clipboard'),
          ),
        ],
      ),
    );
  }

  /// Item 42's "no import/export" gap, import half — a paste box for a
  /// payload [_exportRules] (or a hand-edited equivalent) produced.
  /// Malformed/empty input imports nothing, reported honestly rather
  /// than as a silent success, matching [importRulesJson]'s own "a bad
  /// paste finds nothing to import, not a crash" contract.
  Future<void> _importRules() async {
    final pasteController = TextEditingController();
    final json = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Import smart playlists'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: pasteController,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Paste exported smart playlist JSON here',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, pasteController.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    // Deferred one frame rather than disposed immediately: `showDialog`'s
    // returned Future completes as soon as `Navigator.pop` is called, not
    // once the route's own exit transition finishes — disposing
    // synchronously here could race a `TextField`/`InputDecorator` still
    // mid-animation and still listening to this exact controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => pasteController.dispose());
    if (json == null || json.trim().isEmpty || !mounted) return;
    final imported = await widget.plugin.importRulesJson(json);
    if (!mounted) return;
    setState(() {
      _playFeedback = imported == 0
          ? 'No valid smart playlists found in that paste.'
          : 'Imported $imported smart playlist${imported == 1 ? '' : 's'}.';
    });
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
        Row(
          children: [
            Text('Smart playlists',
                style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            TextButton(
              onPressed: widget.plugin.savedRules.isEmpty ? null : _exportRules,
              child: const Text('Export'),
            ),
            TextButton(onPressed: _importRules, child: const Text('Import')),
          ],
        ),
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
        Row(
          children: [
            Text(
              _editingRuleId == null
                  ? 'Create a smart playlist'
                  : 'Edit smart playlist',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (_editingRuleId != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _cancelEdit,
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
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
        FilledButton(
          onPressed: _saveRule,
          child: Text(_editingRuleId == null ? 'Save' : 'Update'),
        ),
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
                onPressed: () => _editRule(rule),
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
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
              if (value == null) return;
              setState(() {
                condition.field = value;
                // A boolean field needs a real true/false value, not
                // whatever free text happened to be left over from a
                // different field — default it the moment the row
                // switches into `favorite`/`thumbUp`/`thumbDown`, so the
                // dropdown below and the underlying controller text
                // never disagree.
                if (_isBooleanField(value) &&
                    condition.valueController.text != 'true' &&
                    condition.valueController.text != 'false') {
                  condition.valueController.text = 'true';
                }
              });
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
            child: _isBooleanField(condition.field)
                ? DropdownButton<String>(
                    isExpanded: true,
                    value: condition.valueController.text == 'false'
                        ? 'false'
                        : 'true',
                    items: [
                      DropdownMenuItem(
                          value: 'true',
                          child: Text(_booleanLabels(condition.field).$1)),
                      DropdownMenuItem(
                          value: 'false',
                          child: Text(_booleanLabels(condition.field).$2)),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => condition.valueController.text = value);
                      }
                    },
                  )
                : TextField(
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
