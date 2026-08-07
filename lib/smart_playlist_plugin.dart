import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

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

class _SmartPlaylistSettingsState extends State<_SmartPlaylistSettings> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      ],
    );
  }
}
