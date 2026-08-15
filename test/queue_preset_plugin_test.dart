import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/play_record.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/queue_preset_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `Omnis/test/queue_preset_plugin_test.dart` (the main app repo) already
/// exercises Forgotten Favorites/Rediscover exhaustively against the real
/// `OmnisPluginContext`. This file is the standalone, Omnis-Plugins-side
/// suite that doesn't depend on the main app at all — same "a bundled
/// plugin should be testable from within its own package" bar every other
/// `*_plugin_test.dart` here already meets — plus the angles the app-repo
/// suite doesn't cover: lifecycle registration, BPM threshold persistence,
/// the genre-OR-BPM match condition, and mutation safety.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

class _FakeHistory implements IPlayHistoryProvider {
  List<PlayRecord> recent = [];
  List<MapEntry<String, int>> mostPlayed = [];

  @override
  List<PlayRecord> recentlyPlayed({int limit = 25}) => recent.take(limit).toList();

  @override
  List<MapEntry<String, int>> mostPlayedIds({int limit = 25}) =>
      mostPlayed.take(limit).toList();

  @override
  int playCountFor(String trackId) =>
      mostPlayed.firstWhere((e) => e.key == trackId, orElse: () => const MapEntry('', 0)).value;
}

class _FakeRatings implements IRatingsProvider {
  Map<String, int> ratings = {};

  @override
  int ratingOf(String trackId) => ratings[trackId] ?? 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track({
    required String id,
    List<String> genres = const [],
    double? bpm,
  }) =>
      BaseTrack(
        id: id,
        title: 'Track $id',
        artists: const ['Artist'],
        album: 'Album',
        duration: 200,
        type: TrackType.local,
        genres: genres,
        bpm: bpm,
      );

  group('matchesPreset', () {
    test('preset names are matched case-insensitively', () {
      final plugin = QueuePresetPlugin();
      final t = track(id: 't1', genres: const ['Chillout']);
      expect(plugin.matchesPreset(t, 'CHILL'), isTrue);
      expect(plugin.matchesPreset(t, 'Chill'), isTrue);
    });

    test('"chill"/"focus" never consider BPM — only genre', () {
      final plugin = QueuePresetPlugin();
      final fastNoGenreMatch = track(id: 't1', genres: const [], bpm: 200);
      expect(plugin.matchesPreset(fastNoGenreMatch, 'chill'), isFalse);
      expect(plugin.matchesPreset(fastNoGenreMatch, 'focus'), isFalse);
    });

    test('a genre match alone is enough even when BPM would not match, and '
        'vice versa (byGenre || byBpm)', () {
      final plugin = QueuePresetPlugin();
      final genreOnly = track(id: 't1', genres: const ['metal'], bpm: 60);
      expect(plugin.matchesPreset(genreOnly, 'workout'), isTrue);

      final bpmOnly = track(id: 't2', genres: const [], bpm: 140);
      expect(plugin.matchesPreset(bpmOnly, 'workout'), isTrue);
    });

    test('custom BPM thresholds change the match boundary', () async {
      final plugin = QueuePresetPlugin();
      await plugin.setWorkoutBpmThreshold(150);
      expect(plugin.matchesPreset(track(id: 't1', bpm: 130), 'workout'), isFalse);
      expect(plugin.matchesPreset(track(id: 't1', bpm: 150), 'workout'), isTrue);

      await plugin.setSleepBpmThreshold(60);
      expect(plugin.matchesPreset(track(id: 't2', bpm: 70), 'sleep'), isFalse);
      expect(plugin.matchesPreset(track(id: 't2', bpm: 60), 'sleep'), isTrue);
    });
  });

  group('buildQueue', () {
    test('does not mutate the input list', () {
      final plugin = QueuePresetPlugin();
      final tracks = [
        track(id: 't1', genres: const ['metal']),
        track(id: 't2', genres: const ['metal']),
        track(id: 't3', genres: const ['metal']),
      ];
      final before = List<BaseTrack>.from(tracks);
      plugin.buildQueue(tracks, 'workout', random: Random(1));
      expect(tracks, before);
    });

    test('an unrecognized preset name matches nothing, so buildQueue always '
        'falls back to the whole library rather than an empty queue', () {
      final plugin = QueuePresetPlugin();
      final tracks = [track(id: 't1'), track(id: 't2')];
      final result = plugin.buildQueue(tracks, 'not_a_real_preset', random: Random(1));
      expect(result.toSet(), tracks.toSet());
    });
  });

  group('buildQueueFor dispatch', () {
    test('"Forgotten Favorites"/"Rediscover" bypass BPM/genre matching '
        'entirely — an empty history/ratings setup returns empty even for '
        'a track that would satisfy every BPM/genre preset', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final tracks = [track(id: 't1', genres: const ['metal'], bpm: 130)];
      expect(plugin.buildQueueFor(tracks, 'Forgotten Favorites'), isEmpty);
      expect(plugin.buildQueueFor(tracks, 'Rediscover'), isEmpty);
    });

    test('any other query name goes through the BPM/genre matcher', () {
      final plugin = QueuePresetPlugin();
      final matching = track(id: 'm1', genres: const ['metal']);
      final result = plugin.buildQueueFor([matching], 'Workout');
      expect(result, [matching]);
    });

    test('supportedQueries lists exactly the six presets, in order', () {
      final plugin = QueuePresetPlugin();
      expect(plugin.supportedQueries, [
        'Chill',
        'Focus',
        'Workout',
        'Sleep',
        'Forgotten Favorites',
        'Rediscover',
      ]);
    });
  });

  group('Forgotten Favorites — result size', () {
    test('result never exceeds the default limit of 50, even with more '
        'forgotten candidates available', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final history = _FakeHistory()
        ..mostPlayed = List.generate(80, (i) => MapEntry('t$i', 80 - i))
        ..recent = [];
      ctx.servicesRegistry.register(IPlayHistoryProvider, history);

      final tracks = List.generate(80, (i) => track(id: 't$i'));
      final result = plugin.buildQueueFor(tracks, 'Forgotten Favorites');
      expect(result.length, 50);
    });
  });

  group('Rediscover — happy path via the lightweight Omnis-Plugins-side '
      'context (no dependency on the main app)', () {
    test('a highly rated track absent from recent plays is surfaced', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IRatingsProvider, _FakeRatings()..ratings = {'t1': 5});
      ctx.servicesRegistry.register(IPlayHistoryProvider, _FakeHistory());

      final t1 = track(id: 't1');
      expect(plugin.buildQueueFor([t1], 'Rediscover'), [t1]);
    });
  });

  group('lifecycle', () {
    test('initialize registers IQueueBuilder; dispose unregisters it',
        () async {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isTrue);
      expect(ctx.servicesRegistry.get<IQueueBuilder>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IQueueBuilder>(), isTrue);
    });

    test('requiresSequentialInit is true — must init after '
        'SmartPlaylistPlugin so its always-non-empty fallback never wins '
        'the registration-order race', () {
      final plugin = QueuePresetPlugin();
      expect(plugin.requiresSequentialInit, isTrue);
    });

    test('initialize/enable/disable/dispose are no-ops without an attached '
        'context', () async {
      final plugin = QueuePresetPlugin();
      await plugin.initialize();
      await plugin.enable();
      await plugin.disable();
      await plugin.dispose();
    });
  });

  group('BPM threshold storage', () {
    test('defaults are 120 (workout) / 80 (sleep)', () {
      final plugin = QueuePresetPlugin();
      expect(plugin.workoutBpmThreshold, 120.0);
      expect(plugin.sleepBpmThreshold, 80.0);
    });

    test('setters persist and are reflected by the getters', () async {
      final plugin = QueuePresetPlugin();
      await plugin.setWorkoutBpmThreshold(140);
      await plugin.setSleepBpmThreshold(70);
      expect(plugin.workoutBpmThreshold, 140.0);
      expect(plugin.sleepBpmThreshold, 70.0);
    });
  });
}
