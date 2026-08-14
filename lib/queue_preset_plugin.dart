import 'dart:math';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// How many of a listener's top plays to consider "favorites" for the
/// [QueuePresetPlugin.presets] name of that name — wide enough to
/// include real listening habit, narrow enough that "forgotten" still
/// means something (the whole library ranked by play count would just
/// be "most played," a different, already-existing view).
const _forgottenFavoritesCandidatePool = 200;

/// How many of a listener's most-recent plays count as "not forgotten"
/// — a track played within this window is still active listening, not
/// something to be reminded of.
const _forgottenFavoritesRecentWindow = 30;

/// Curated queue presets built from objective, always-available track data
/// (genre keywords, BPM) — deliberately independent of `BaseTrack.mood`,
/// which only ever gets populated by opt-in enrichment/analysis/manual
/// tagging. `SmartPlaylistPlugin` already covers mood-string matching for
/// libraries that *have* that data; this plugin exists so a preset still
/// does something useful for a freshly scanned library that has none of
/// it yet — previously this class held nothing but four static label
/// strings and a `uiSlot` that always returned `null`, so tapping "Sleep"
/// (a preset unique to this plugin) could never work no matter what was
/// in the library.
///
/// Implements [IQueueBuilder] alongside `SmartPlaylistPlugin` — see that
/// interface's doc for why this plugin must register *after* it
/// (`bundled_plugins.dart`'s list order): this plugin's fallback always
/// returns something non-empty, so if it registered first it would
/// short-circuit every query before `SmartPlaylistPlugin`'s curated match
/// ever got a chance to run.
class QueuePresetPlugin extends MusicPlugin implements IQueueBuilder {
  static const _workoutBpmKey = 'workout_bpm_threshold';
  static const _sleepBpmKey = 'sleep_bpm_threshold';
  static const _defaultWorkoutBpm = 120.0;
  static const _defaultSleepBpm = 80.0;

  final List<String> presets = [
    'Chill',
    'Focus',
    'Workout',
    'Sleep',
    'Forgotten Favorites',
  ];

  @override
  List<String> get supportedQueries => presets;

  static const _genreKeywords = <String, List<String>>{
    'workout': ['edm', 'dance', 'hip hop', 'hip-hop', 'rock', 'pop', 'metal'],
    'sleep': ['ambient', 'sleep', 'classical', 'piano', 'lo-fi', 'lofi', 'drone'],
    'focus': ['ambient', 'instrumental', 'lo-fi', 'lofi', 'classical', 'focus', 'study'],
    'chill': ['chill', 'lo-fi', 'lofi', 'acoustic', 'jazz', 'soul', 'chillout'],
  };

  /// "Workout" matches a track at or above this BPM. User-adjustable —
  /// tap this plugin in the Plugins list — since what counts as an
  /// energetic tempo is genuinely subjective.
  double get workoutBpmThreshold =>
      storage.getDouble(_workoutBpmKey) ?? _defaultWorkoutBpm;

  Future<void> setWorkoutBpmThreshold(double bpm) =>
      storage.setDouble(_workoutBpmKey, bpm);

  /// "Sleep" matches a track at or below this BPM.
  double get sleepBpmThreshold =>
      storage.getDouble(_sleepBpmKey) ?? _defaultSleepBpm;

  Future<void> setSleepBpmThreshold(double bpm) =>
      storage.setDouble(_sleepBpmKey, bpm);

  bool _matchesGenre(BaseTrack track, List<String> keywords) => track.genres
      .any((g) => keywords.any((k) => g.toLowerCase().contains(k)));

  /// True when [track] fits [preset] by BPM/genre. Unknown [preset]
  /// names match nothing.
  bool matchesPreset(BaseTrack track, String preset) {
    final keywords = _genreKeywords[preset.toLowerCase()];
    if (keywords == null) return false;
    final byGenre = _matchesGenre(track, keywords);
    final bpm = track.bpm;
    final byBpm = switch (preset.toLowerCase()) {
      'workout' => bpm != null && bpm >= workoutBpmThreshold,
      'sleep' => bpm != null && bpm <= sleepBpmThreshold,
      _ => false,
    };
    return byGenre || byBpm;
  }

  /// Builds a shuffled queue for [preset] from [tracks]. Falls back to a
  /// shuffled sample of the *whole* library when nothing matches the
  /// preset's criteria — an unusual library legitimately might have
  /// nothing that fits "Workout," but the user still tapped a "play
  /// something" button and deserves a queue, not a dead end.
  List<BaseTrack> buildQueue(
    List<BaseTrack> tracks,
    String preset, {
    int limit = 50,
    Random? random,
  }) {
    final matches = tracks.where((t) => matchesPreset(t, preset)).toList();
    final pool = matches.isNotEmpty ? matches : List<BaseTrack>.from(tracks);
    final shuffled = List<BaseTrack>.from(pool)..shuffle(random);
    return shuffled.take(limit).toList();
  }

  /// "Forgotten Favorites" — real listening-history data (via
  /// [IPlayHistoryProvider], today backed by `ScrobblePlugin`), not
  /// BPM/genre like every other preset here: tracks among a listener's
  /// most-played that haven't shown up in their most-*recent* plays,
  /// i.e. things they clearly used to love and have since drifted away
  /// from. One of the spec's named recommendation algorithms (§39) —
  /// previously none of them existed anywhere in either repo despite
  /// `FavoritesPlugin`/`RatingsPlugin`/`ScrobblePlugin` all already
  /// collecting real signal nothing consumed.
  ///
  /// Deliberately returns an **empty** list rather than [buildQueue]'s
  /// whole-library shuffle fallback when there's no real history yet —
  /// unlike "Workout"/"Sleep," which describe a track's own objective
  /// properties and so can reasonably fall back to "something in that
  /// spirit," "Forgotten Favorites" is a claim about *this listener's
  /// actual history*; a shuffled library isn't a smaller version of that
  /// claim, it's a different, misleading one.
  List<BaseTrack> _buildForgottenFavorites(
    List<BaseTrack> tracks, {
    int limit = 50,
    Random? random,
  }) {
    final history = context?.services.get<IPlayHistoryProvider>();
    if (history == null) return const [];
    final mostPlayed =
        history.mostPlayedIds(limit: _forgottenFavoritesCandidatePool);
    if (mostPlayed.isEmpty) return const [];
    final recentIds = history
        .recentlyPlayed(limit: _forgottenFavoritesRecentWindow)
        .map((r) => r.trackId)
        .toSet();
    final byId = {for (final t in tracks) t.id: t};
    final forgotten = mostPlayed
        .map((entry) => entry.key)
        .where((id) => !recentIds.contains(id))
        .map((id) => byId[id])
        .whereType<BaseTrack>()
        .toList();
    if (forgotten.isEmpty) return const [];
    final shuffled = List<BaseTrack>.from(forgotten)..shuffle(random);
    return shuffled.take(limit).toList();
  }

  @override
  List<BaseTrack> buildQueueFor(List<BaseTrack> tracks, String query) {
    if (query.toLowerCase() == 'forgotten favorites') {
      return _buildForgottenFavorites(tracks);
    }
    return buildQueue(tracks, query);
  }

  @override
  String get id => 'queue_presets';

  @override
  String get name => 'Queue Presets';

  @override
  String get description =>
      'Builds ready-to-play queues from BPM/genre — no tagging required.';

  @override
  String get version => '2.0.0';

  @override
  String get author => 'Omnis Team';

  // Must initialize after SmartPlaylistPlugin — see the class doc above
  // and bundled_plugins.dart's ordering note. Without this, this plugin's
  // always-non-empty fallback can register under IQueueBuilder before
  // SmartPlaylistPlugin's curated match does, under PluginManager's
  // parallel initializeAll() round.
  @override
  bool get requiresSequentialInit => true;

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
      locationID == 'plugin_settings' ? _QueuePresetSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    context?.services.unregister(IQueueBuilder, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(IQueueBuilder, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IQueueBuilder, this);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. Genre keywords stay fixed (editing a keyword list well needs
/// more UI than this warrants), but the BPM thresholds — genuinely
/// subjective — are adjustable.
class _QueuePresetSettings extends StatefulWidget {
  final QueuePresetPlugin plugin;

  const _QueuePresetSettings({required this.plugin});

  @override
  State<_QueuePresetSettings> createState() => _QueuePresetSettingsState();
}

class _QueuePresetSettingsState extends State<_QueuePresetSettings> {
  @override
  Widget build(BuildContext context) {
    final workout = widget.plugin.workoutBpmThreshold;
    final sleep = widget.plugin.sleepBpmThreshold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('"Workout" BPM threshold'),
          subtitle: Slider(
            value: workout,
            min: 90,
            max: 180,
            divisions: 90,
            label: '${workout.round()} BPM or faster',
            onChanged: (value) async {
              await widget.plugin.setWorkoutBpmThreshold(value);
              if (mounted) setState(() {});
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('"Sleep" BPM threshold'),
          subtitle: Slider(
            value: sleep,
            min: 40,
            max: 110,
            divisions: 70,
            label: '${sleep.round()} BPM or slower',
            onChanged: (value) async {
              await widget.plugin.setSleepBpmThreshold(value);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}
