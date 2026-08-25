import 'package:omnis_plugin_api/base_track.dart';

/// "Forgotten Music" (spec §37 / item 39) — tracks a listener owns but
/// hasn't heard in a while, browsable as a real list with a real count
/// ("147 tracks you haven't heard in 6+ months"), distinct from
/// `QueuePresetPlugin`'s "Forgotten Favorites" queue preset, which only
/// ever considers a listener's top-N *most played* tracks and never
/// surfaces a browsable list — this covers every owned track, including
/// ones barely played at all or never played.
///
/// Moved here from the Omnis app's own `lib/core/forgotten_tracks.dart`
/// (Tier 2 task 4) alongside `ForgottenMusicPage`, its only caller — the
/// Forgotten Music page is reached from inside the Moods tab, so it
/// belongs to the same extracted cluster.
///
/// A track counts as forgotten when it's either missing from
/// [lastPlayedById] entirely (never played) or its last play predates
/// `DateTime.now() - threshold`. Never-played tracks sort first (there's
/// no more "forgotten" state than never having been heard), then the
/// rest oldest-last-played-first.
List<BaseTrack> findForgottenTracks(
  List<BaseTrack> tracks,
  Map<String, DateTime> lastPlayedById, {
  Duration threshold = const Duration(days: 180),
  DateTime? now,
}) {
  final cutoff = (now ?? DateTime.now()).subtract(threshold);
  final neverPlayed = <BaseTrack>[];
  final stale = <MapEntry<BaseTrack, DateTime>>[];

  for (final track in tracks) {
    final lastPlayed = lastPlayedById[track.id];
    if (lastPlayed == null) {
      neverPlayed.add(track);
    } else if (lastPlayed.isBefore(cutoff)) {
      stale.add(MapEntry(track, lastPlayed));
    }
  }

  stale.sort((a, b) => a.value.compareTo(b.value));
  return [...neverPlayed, ...stale.map((e) => e.key)];
}
