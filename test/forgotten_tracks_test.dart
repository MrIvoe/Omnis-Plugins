import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/forgotten_tracks.dart';

BaseTrack _track(String id) => BaseTrack(
      id: id,
      title: 'Title $id',
      artists: const ['Artist'],
      album: 'Album',
      duration: 180,
      type: TrackType.local,
    );

void main() {
  final now = DateTime(2026, 8, 15);

  group('findForgottenTracks', () {
    test('a track with no history entry at all counts as forgotten', () {
      final tracks = [_track('a')];

      final result = findForgottenTracks(tracks, const {}, now: now);

      expect(result.map((t) => t.id), ['a']);
    });

    test('a track played more recently than the threshold is not '
        'forgotten', () {
      final tracks = [_track('a')];
      final lastPlayed = {'a': now.subtract(const Duration(days: 10))};

      final result = findForgottenTracks(tracks, lastPlayed, now: now);

      expect(result, isEmpty);
    });

    test('a track last played exactly at the threshold boundary is not '
        'yet forgotten', () {
      final tracks = [_track('a')];
      final lastPlayed = {
        'a': now.subtract(const Duration(days: 180)),
      };

      final result = findForgottenTracks(tracks, lastPlayed,
          threshold: const Duration(days: 180), now: now);

      expect(result, isEmpty,
          reason: 'the cutoff itself is not "before" the cutoff');
    });

    test('a track last played one day past the threshold is forgotten',
        () {
      final tracks = [_track('a')];
      final lastPlayed = {
        'a': now.subtract(const Duration(days: 181)),
      };

      final result = findForgottenTracks(tracks, lastPlayed,
          threshold: const Duration(days: 180), now: now);

      expect(result.map((t) => t.id), ['a']);
    });

    test('never-played tracks sort before stale-but-once-played tracks',
        () {
      final tracks = [_track('stale'), _track('never')];
      final lastPlayed = {
        'stale': now.subtract(const Duration(days: 400)),
      };

      final result = findForgottenTracks(tracks, lastPlayed, now: now);

      expect(result.map((t) => t.id), ['never', 'stale']);
    });

    test('stale tracks sort oldest-last-played first', () {
      final tracks = [_track('a'), _track('b'), _track('c')];
      final lastPlayed = {
        'a': now.subtract(const Duration(days: 200)),
        'b': now.subtract(const Duration(days: 500)),
        'c': now.subtract(const Duration(days: 300)),
      };

      final result = findForgottenTracks(tracks, lastPlayed, now: now);

      expect(result.map((t) => t.id), ['b', 'c', 'a']);
    });

    test('a custom threshold changes what counts as forgotten', () {
      final tracks = [_track('a')];
      final lastPlayed = {'a': now.subtract(const Duration(days: 40))};

      expect(
          findForgottenTracks(tracks, lastPlayed,
              threshold: const Duration(days: 30), now: now),
          isNotEmpty);
      expect(
          findForgottenTracks(tracks, lastPlayed,
              threshold: const Duration(days: 60), now: now),
          isEmpty);
    });

    test('an empty library returns empty regardless of history', () {
      final result = findForgottenTracks(const [], {'a': now}, now: now);

      expect(result, isEmpty);
    });

    test('extra history entries for tracks no longer in the library are '
        'ignored', () {
      final tracks = [_track('a')];
      final lastPlayed = {
        'a': now.subtract(const Duration(days: 10)),
        'gone': now.subtract(const Duration(days: 999)),
      };

      final result = findForgottenTracks(tracks, lastPlayed, now: now);

      expect(result, isEmpty);
    });
  });
}
