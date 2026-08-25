import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugins/custom_mood_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;

  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;

  @override
  Future<String?> getApplicationSupportPath() async => tempDir;

  @override
  Future<String?> getTemporaryPath() async => tempDir;
}

BaseTrack _track({
  String id = 't1',
  List<String> genres = const [],
  String? mood,
  double? bpm,
}) {
  return BaseTrack(
    id: id,
    title: 'Title',
    artists: const ['Artist'],
    album: 'Album',
    duration: 200,
    type: TrackType.local,
    genres: genres,
    mood: mood,
    bpm: bpm,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CustomMood.matches', () {
    test('an unconfigured mood (no criteria at all) matches nothing', () {
      const mood = CustomMood(id: 'm1', name: 'Empty');
      final track = _track(genres: const ['Rock'], bpm: 120);
      expect(
        mood.matches(track, ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
    });

    test('genres OR-match, case-insensitively', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Rock or Synth',
        genres: ['rock', 'synthwave'],
      );
      expect(
        mood.matches(_track(genres: const ['Rock']),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isTrue,
      );
      expect(
        mood.matches(_track(genres: const ['Jazz']),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
    });

    test('mood tags OR-match against BaseTrack.mood', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Dark or Relaxed',
        moodTags: ['Dark', 'Relaxed'],
      );
      expect(
        mood.matches(_track(mood: 'Dark'),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isTrue,
      );
      expect(
        mood.matches(_track(mood: 'Happy'),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
      expect(
        mood.matches(_track(),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
    });

    test('BPM range requires a non-null track.bpm within bounds', () {
      const mood = CustomMood(id: 'm1', name: 'Mid tempo', minBpm: 80, maxBpm: 130);
      expect(
        mood.matches(_track(bpm: 100),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isTrue,
      );
      expect(
        mood.matches(_track(bpm: 200),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
      expect(
        mood.matches(_track(),
            ratingOf: (_) => 0, recentlyPlayedIds: const {}),
        isFalse,
      );
    });

    test('rating floor uses the caller-supplied ratingOf lookup', () {
      const mood = CustomMood(id: 'm1', name: 'Great tracks', ratingFloor: 4);
      expect(
        mood.matches(_track(id: 'high'),
            ratingOf: (id) => id == 'high' ? 5 : 1,
            recentlyPlayedIds: const {}),
        isTrue,
      );
      expect(
        mood.matches(_track(id: 'low'),
            ratingOf: (id) => id == 'high' ? 5 : 1,
            recentlyPlayedIds: const {}),
        isFalse,
      );
    });

    test('excludes tracks whose id is in recentlyPlayedIds', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Fresh',
        ratingFloor: 1,
        excludeRecentlyPlayedDays: 7,
      );
      expect(
        mood.matches(_track(id: 'played'),
            ratingOf: (_) => 5, recentlyPlayedIds: const {'played'}),
        isFalse,
      );
      expect(
        mood.matches(_track(id: 'unplayed'),
            ratingOf: (_) => 5, recentlyPlayedIds: const {'played'}),
        isTrue,
      );
    });

    test('all configured criteria are ANDed together', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Everything',
        genres: ['Rock'],
        minBpm: 100,
        maxBpm: 140,
        ratingFloor: 3,
      );
      // Genre matches, BPM matches, rating fails.
      expect(
        mood.matches(_track(genres: const ['Rock'], bpm: 120),
            ratingOf: (_) => 1, recentlyPlayedIds: const {}),
        isFalse,
      );
      // Everything matches.
      expect(
        mood.matches(_track(genres: const ['Rock'], bpm: 120),
            ratingOf: (_) => 4, recentlyPlayedIds: const {}),
        isTrue,
      );
    });
  });

  group('CustomMood.isInTimeWindow', () {
    test('always true when no window is configured', () {
      const mood = CustomMood(id: 'm1', name: 'No window');
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 3, 0)), isTrue);
    });

    test('a same-day window (e.g. 9am-5pm)', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Daytime',
        windowStartMinutes: 9 * 60,
        windowEndMinutes: 17 * 60,
      );
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 12, 0)), isTrue);
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 20, 0)), isFalse);
    });

    test('a window that wraps past midnight (9 PM - 3 AM)', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Late Night Drive',
        windowStartMinutes: 21 * 60,
        windowEndMinutes: 3 * 60,
      );
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 23, 0)), isTrue);
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 1, 0)), isTrue);
      expect(mood.isInTimeWindow(DateTime(2026, 1, 1, 12, 0)), isFalse);
    });
  });

  group('CustomMood JSON round-trip', () {
    test('toJson/fromJson preserves every field', () {
      const mood = CustomMood(
        id: 'm1',
        name: 'Late Night Drive',
        genres: ['Rock', 'Synthwave'],
        moodTags: ['Dark', 'Relaxed'],
        minBpm: 80,
        maxBpm: 130,
        ratingFloor: 3,
        excludeRecentlyPlayedDays: 7,
        windowStartMinutes: 21 * 60,
        windowEndMinutes: 3 * 60,
        color: Colors.deepPurple,
        icon: CustomMoodIcon.moon,
      );
      final decoded = CustomMood.fromJson(mood.toJson())!;
      expect(decoded.id, mood.id);
      expect(decoded.name, mood.name);
      expect(decoded.genres, mood.genres);
      expect(decoded.moodTags, mood.moodTags);
      expect(decoded.minBpm, mood.minBpm);
      expect(decoded.maxBpm, mood.maxBpm);
      expect(decoded.ratingFloor, mood.ratingFloor);
      expect(decoded.excludeRecentlyPlayedDays, mood.excludeRecentlyPlayedDays);
      expect(decoded.windowStartMinutes, mood.windowStartMinutes);
      expect(decoded.windowEndMinutes, mood.windowEndMinutes);
      expect(decoded.icon, mood.icon);
    });

    test('a malformed entry (missing id/name) decodes to null', () {
      expect(CustomMood.fromJson({'name': 'No id'}), isNull);
      expect(CustomMood.fromJson({'id': 'no-name'}), isNull);
    });

    test('a null color round-trips as null, not a crash', () {
      const mood = CustomMood(id: 'm1', name: 'No color');
      final decoded = CustomMood.fromJson(mood.toJson())!;
      expect(decoded.color, isNull);
    });
  });

  group('CustomMoodStore', () {
    late String tempDir;

    setUp(() async {
      tempDir = (await Directory.systemTemp.createTemp('omnis_mood_test')).path;
      PathProviderPlatform.instance = _FakePathProvider(tempDir);
      CustomMoodStore.instance.resetForTesting();
    });

    test('loading with no saved file returns an empty list', () async {
      expect(await CustomMoodStore.instance.load(), isEmpty);
    });

    test('a real save/load round-trip', () async {
      const moods = [
        CustomMood(id: 'm1', name: 'Chill', genres: ['Lofi']),
        CustomMood(id: 'm2', name: 'Workout', minBpm: 140, maxBpm: 180),
      ];
      await CustomMoodStore.instance.save(moods);
      final reloaded = await CustomMoodStore.instance.load();
      expect(reloaded.map((m) => m.id), ['m1', 'm2']);
      expect(reloaded[0].name, 'Chill');
      expect(reloaded[1].maxBpm, 180);
    });

    test('a corrupt file is treated as empty, never throws', () async {
      final file = File('$tempDir/omnis_custom_moods.json');
      await file.writeAsString('{not valid json');
      expect(await CustomMoodStore.instance.load(), isEmpty);
    });
  });
}
