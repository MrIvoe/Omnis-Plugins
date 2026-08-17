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

class _FakeFavorites implements IFavoritesProvider {
  List<String> ids = [];

  @override
  bool isFavorite(String trackId) => ids.contains(trackId);

  @override
  List<String> favoriteIds() => ids;
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
    List<String> artists = const ['Artist'],
    int? year,
    DateTime? releaseDate,
  }) =>
      BaseTrack(
        id: id,
        title: 'Track $id',
        artists: artists,
        album: 'Album',
        duration: 200,
        type: TrackType.local,
        genres: genres,
        bpm: bpm,
        year: year,
        releaseDate: releaseDate,
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
    test('"Forgotten Favorites"/"Rediscover"/"Favorites Mix" bypass BPM/'
        'genre matching entirely — an empty history/ratings/favorites '
        'setup returns empty even for a track that would satisfy every '
        'BPM/genre preset', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final tracks = [track(id: 't1', genres: const ['metal'], bpm: 130)];
      expect(plugin.buildQueueFor(tracks, 'Forgotten Favorites'), isEmpty);
      expect(plugin.buildQueueFor(tracks, 'Rediscover'), isEmpty);
      expect(plugin.buildQueueFor(tracks, 'Favorites Mix'), isEmpty);
    });

    test('any other query name goes through the BPM/genre matcher', () {
      final plugin = QueuePresetPlugin();
      final matching = track(id: 'm1', genres: const ['metal']);
      final result = plugin.buildQueueFor([matching], 'Workout');
      expect(result, [matching]);
    });

    test('supportedQueries lists exactly the eleven presets, in order', () {
      final plugin = QueuePresetPlugin();
      expect(plugin.supportedQueries, [
        'Chill',
        'Focus',
        'Workout',
        'Sleep',
        'Forgotten Favorites',
        'Rediscover',
        'Favorites Mix',
        'Deep Cuts',
        'New Releases',
        'Daily Mix',
        'Weekly Mix',
      ]);
    });
  });

  group('Favorites Mix', () {
    test('no IFavoritesProvider registered: empty, no crash', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      expect(plugin.buildQueueFor([track(id: 't1')], 'Favorites Mix'), isEmpty);
    });

    test('favorites provider with nothing favorited: empty', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(IFavoritesProvider, _FakeFavorites());
      expect(plugin.buildQueueFor([track(id: 't1')], 'Favorites Mix'), isEmpty);
    });

    test('a favorited track missing from the current library (deleted/'
        'never scanned) is skipped rather than producing a broken entry',
        () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['gone']);
      expect(
        plugin.buildQueueFor([track(id: 'unrelated')], 'Favorites Mix'),
        isEmpty,
      );
    });

    test('favorited tracks present in the library are surfaced, '
        'non-favorited tracks are excluded', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(
        IFavoritesProvider,
        _FakeFavorites()..ids = ['t1', 't2'],
      );
      final t1 = track(id: 't1');
      final t2 = track(id: 't2');
      final t3 = track(id: 't3');
      final result = plugin.buildQueueFor([t1, t2, t3], 'Favorites Mix');
      expect(result.toSet(), {t1, t2});
    });

    test('result never exceeds the default limit of 50', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final ids = List.generate(80, (i) => 't$i');
      ctx.servicesRegistry.register(IFavoritesProvider, _FakeFavorites()..ids = ids);
      final tracks = List.generate(80, (i) => track(id: 't$i'));
      final result = plugin.buildQueueFor(tracks, 'Favorites Mix');
      expect(result.length, 50);
    });

    test('query matching is case-insensitive, same as every other preset '
        'name here', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['t1']);
      final t1 = track(id: 't1');
      expect(plugin.buildQueueFor([t1], 'favorites mix'), [t1]);
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

  group('Deep Cuts', () {
    test('no IFavoritesProvider registered: empty, no crash', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(IPlayHistoryProvider, _FakeHistory());
      expect(plugin.buildQueueFor([track(id: 't1')], 'Deep Cuts'), isEmpty);
    });

    test('no IPlayHistoryProvider registered: empty, no crash', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(IFavoritesProvider, _FakeFavorites());
      expect(plugin.buildQueueFor([track(id: 't1')], 'Deep Cuts'), isEmpty);
    });

    test('nothing favorited at all: empty', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(IFavoritesProvider, _FakeFavorites());
      ctx.servicesRegistry.register(IPlayHistoryProvider, _FakeHistory());
      expect(plugin.buildQueueFor([track(id: 't1')], 'Deep Cuts'), isEmpty);
    });

    test('a favorite artist whose every track ranks as a hit (too few '
        'tracks for a meaningful split) contributes nothing', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      // Only one track by this artist at all — no "rest of the catalog"
      // to be a deep cut relative to.
      final only = track(id: 'only', artists: const ['Solo Artist']);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['only']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()..mostPlayed = [const MapEntry('only', 100)],
      );
      expect(plugin.buildQueueFor([only], 'Deep Cuts'), isEmpty);
    });

    test('a favorite artist\'s genuinely low-played tracks are surfaced, '
        'the top-played "hit" is excluded', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final hit = track(id: 'hit', artists: const ['Fave']);
      final deepCut1 = track(id: 'deep1', artists: const ['Fave']);
      final deepCut2 = track(id: 'deep2', artists: const ['Fave']);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['hit']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('hit', 100),
            const MapEntry('deep1', 2),
            const MapEntry('deep2', 0),
          ],
      );
      final result =
          plugin.buildQueueFor([hit, deepCut1, deepCut2], 'Deep Cuts');
      expect(result.toSet(), {deepCut1, deepCut2});
      expect(result, isNot(contains(hit)));
    });

    test('a non-favorite artist\'s low-played tracks are never surfaced, '
        'even alongside a genuine favorite artist', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final favHit = track(id: 'fav_hit', artists: const ['Fave']);
      final favDeepCut = track(id: 'fav_deep', artists: const ['Fave']);
      final otherHit = track(id: 'other_hit', artists: const ['Other']);
      final otherDeepCut = track(id: 'other_deep', artists: const ['Other']);
      ctx.servicesRegistry.register(
          IFavoritesProvider, _FakeFavorites()..ids = ['fav_hit']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('fav_hit', 100),
            const MapEntry('fav_deep', 1),
            const MapEntry('other_hit', 100),
            const MapEntry('other_deep', 1),
          ],
      );
      final result = plugin.buildQueueFor(
          [favHit, favDeepCut, otherHit, otherDeepCut], 'Deep Cuts');
      expect(result, [favDeepCut]);
    });

    test('each favorite artist\'s hit/deep-cut split is computed from '
        'its own play counts, not one library-wide cutoff', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      // Artist A: a huge hit (1000 plays) and a deep cut (5 plays).
      final aHit = track(id: 'a_hit', artists: const ['A']);
      final aDeep = track(id: 'a_deep', artists: const ['A']);
      // Artist B: a much smaller "hit" (20 plays) that would look like a
      // deep cut next to Artist A's numbers, and B's own deep cut (1
      // play) — proving the split is per-artist, not absolute.
      final bHit = track(id: 'b_hit', artists: const ['B']);
      final bDeep = track(id: 'b_deep', artists: const ['B']);
      ctx.servicesRegistry.register(
        IFavoritesProvider,
        _FakeFavorites()..ids = ['a_hit', 'b_hit'],
      );
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('a_hit', 1000),
            const MapEntry('a_deep', 5),
            const MapEntry('b_hit', 20),
            const MapEntry('b_deep', 1),
          ],
      );
      final result =
          plugin.buildQueueFor([aHit, aDeep, bHit, bDeep], 'Deep Cuts');
      expect(result.toSet(), {aDeep, bDeep});
    });

    test('a track by multiple artists, one of them a favorite, is only '
        'ever counted once', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final hit = track(id: 'hit', artists: const ['Fave']);
      final collab =
          track(id: 'collab', artists: const ['Fave', 'Guest']);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['hit']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('hit', 100),
            const MapEntry('collab', 1),
          ],
      );
      final result = plugin.buildQueueFor([hit, collab], 'Deep Cuts');
      expect(result, [collab]);
    });

    test('result never exceeds the default limit of 50', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final tracks = [
        track(id: 'hit', artists: const ['Fave']),
        ...List.generate(
            80, (i) => track(id: 'deep$i', artists: const ['Fave'])),
      ];
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['hit']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('hit', 1000),
            ...List.generate(80, (i) => MapEntry('deep$i', 1)),
          ],
      );
      final result = plugin.buildQueueFor(tracks, 'Deep Cuts');
      expect(result.length, 50);
    });

    test('query matching is case-insensitive, same as every other preset '
        'name here', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final hit = track(id: 'hit', artists: const ['Fave']);
      final deep = track(id: 'deep', artists: const ['Fave']);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['hit']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()
          ..mostPlayed = [
            const MapEntry('hit', 100),
            const MapEntry('deep', 1),
          ],
      );
      expect(plugin.buildQueueFor([hit, deep], 'deep cuts'), [deep]);
    });
  });

  group('New Releases', () {
    // Every year is expressed relative to the real wall-clock "now" — the
    // preset's own cutoff is DateTime.now().year - 2, and buildQueueFor's
    // dispatch has no way to inject a fixed `now` (that parameter only
    // exists on the private _buildNewReleases method itself, unreachable
    // through the public IQueueBuilder-facing entry point) — so a
    // hardcoded absolute year here would silently start failing as real
    // time passes rather than testing the boundary logic itself.
    final currentYear = DateTime.now().year;
    final cutoffYear = currentYear - 2;

    test('no track has year or releaseDate at all: empty, not the '
        'whole-library shuffle fallback', () {
      final plugin = QueuePresetPlugin();
      final t1 = track(id: 't1');
      expect(
        plugin.buildQueueFor([t1], 'New Releases'),
        isEmpty,
      );
    });

    test('a track with releaseDate inside the window is included; one '
        'many years old is excluded', () {
      final plugin = QueuePresetPlugin();
      final recent =
          track(id: 'recent', releaseDate: DateTime(currentYear, 1, 1));
      final old = track(id: 'old', releaseDate: DateTime(2010, 1, 1));
      final dispatched = plugin.buildQueueFor([recent, old], 'New Releases');
      expect(dispatched, [recent]);
    });

    test('a track with only year set (no releaseDate) still counts', () {
      final plugin = QueuePresetPlugin();
      final t1 = track(id: 't1', year: currentYear);
      expect(plugin.buildQueueFor([t1], 'New Releases'), [t1]);
    });

    test('exactly at the cutoff year is included; one year older is '
        'excluded — >=, not >', () {
      final plugin = QueuePresetPlugin();
      final atCutoff = track(id: 'at_cutoff', year: cutoffYear);
      final justOlder = track(id: 'just_older', year: cutoffYear - 1);
      final result = plugin.buildQueueFor(
        [atCutoff, justOlder],
        'New Releases',
      );
      expect(result, [atCutoff]);
    });

    test('results sort newest-first by year', () {
      final plugin = QueuePresetPlugin();
      final oldest = track(id: 'oldest', year: cutoffYear);
      final newest = track(id: 'newest', year: currentYear);
      final middle = track(id: 'middle', year: currentYear - 1);
      final result = plugin.buildQueueFor(
        [oldest, newest, middle],
        'New Releases',
      );
      expect(result, [newest, middle, oldest]);
    });

    test('two tracks sharing a year sort alphabetically by title as a '
        'deterministic tie-break', () {
      final plugin = QueuePresetPlugin();
      final b = track(id: 'b', year: currentYear);
      final a = track(id: 'a', year: currentYear);
      final result = plugin.buildQueueFor([b, a], 'New Releases');
      expect(result, [a, b]);
    });

    test('result never exceeds the default limit of 50', () {
      final plugin = QueuePresetPlugin();
      final tracks =
          List.generate(80, (i) => track(id: 't$i', year: currentYear));
      final result = plugin.buildQueueFor(tracks, 'New Releases');
      expect(result.length, 50);
    });

    test('query matching is case-insensitive, same as every other preset '
        'name here', () {
      final plugin = QueuePresetPlugin();
      final t1 = track(id: 't1', year: currentYear);
      expect(plugin.buildQueueFor([t1], 'new releases'), [t1]);
    });
  });

  group('dailyMixSeed/weeklyMixSeed (item 39, Daily/Weekly Mix)', () {
    test('dailyMixSeed is identical for two calls on the same date', () {
      final date = DateTime(2026, 3, 15);
      expect(dailyMixSeed(date), dailyMixSeed(DateTime(2026, 3, 15)));
    });

    test('dailyMixSeed differs for different days', () {
      expect(dailyMixSeed(DateTime(2026, 3, 15)),
          isNot(dailyMixSeed(DateTime(2026, 3, 16))));
    });

    test('weeklyMixSeed is identical for two days within the same week '
        'bucket', () {
      // Both fall in the same day-of-year/7 bucket (day 59 and 61 for a
      // non-leap year both floor-divide to the same week number).
      expect(weeklyMixSeed(DateTime(2026, 3, 1)),
          weeklyMixSeed(DateTime(2026, 3, 3)));
    });

    test('weeklyMixSeed differs across a week boundary', () {
      expect(weeklyMixSeed(DateTime(2026, 1, 1)),
          isNot(weeklyMixSeed(DateTime(2026, 1, 10))));
    });

    test('a year boundary does not collide dailyMixSeed values', () {
      expect(dailyMixSeed(DateTime(2025, 12, 31)),
          isNot(dailyMixSeed(DateTime(2026, 1, 1))));
    });

    test('a year boundary does not collide weeklyMixSeed values', () {
      expect(weeklyMixSeed(DateTime(2025, 12, 31)),
          isNot(weeklyMixSeed(DateTime(2026, 1, 1))));
    });
  });

  group('Daily Mix / Weekly Mix (item 39)', () {
    test('no IFavoritesProvider and no IPlayHistoryProvider registered: '
        'empty, no crash', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      expect(plugin.buildQueueFor([track(id: 't1')], 'Daily Mix'), isEmpty);
      expect(plugin.buildQueueFor([track(id: 't1')], 'Weekly Mix'), isEmpty);
    });

    test('only IFavoritesProvider registered: a favorited track and its '
        'artist\'s other tracks appear', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['fav1']);
      final fav = track(id: 'fav1', artists: const ['Same Artist']);
      final otherByArtist =
          track(id: 'other1', artists: const ['Same Artist']);
      final unrelated = track(id: 'unrelated', artists: const ['Someone Else']);

      final result = plugin.buildQueueFor(
        [fav, otherByArtist, unrelated],
        'Daily Mix',
      );

      expect(result.map((t) => t.id).toSet(), {'fav1', 'other1'});
    });

    test('a favorited id no longer present in the current library is '
        'silently dropped, not a broken entry', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['gone']);
      expect(
        plugin.buildQueueFor([track(id: 'unrelated')], 'Daily Mix'),
        isEmpty,
      );
    });

    test('only IPlayHistoryProvider registered: top-played tracks appear',
        () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()..mostPlayed = [const MapEntry('played1', 10)],
      );
      final played = track(id: 'played1');
      final unrelated = track(id: 'unrelated');

      final result = plugin.buildQueueFor([played, unrelated], 'Weekly Mix');

      expect(result.map((t) => t.id).toSet(), {'played1'});
    });

    test('both providers registered, overlapping pools: a track that is '
        'both favorited and top-played appears exactly once', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['t1']);
      ctx.servicesRegistry.register(
        IPlayHistoryProvider,
        _FakeHistory()..mostPlayed = [const MapEntry('t1', 10)],
      );
      final overlapping = track(id: 't1');

      final result = plugin.buildQueueFor([overlapping], 'Daily Mix');

      expect(result, [overlapping]);
    });

    // buildQueueFor's public dispatch has no way to inject a fixed `now`
    // (that parameter only exists on the private _buildDailyMix/
    // _buildWeeklyMix/_buildFamiliarMix methods themselves) — the same
    // constraint the New Releases entry's own tests already hit and
    // resolved the same way: exercise real wall-clock stability (two
    // calls within the same real test run necessarily share the same
    // real calendar day/week) rather than hardcoding or injecting a
    // date. "the seed actually varies by date" is already proven at the
    // pure-function level by the dailyMixSeed/weeklyMixSeed group above,
    // so it doesn't need re-proving through the full plugin stack too.
    test('two Daily Mix calls on the same real day return identical '
        'track order — the actual point of this feature', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(
        IFavoritesProvider,
        _FakeFavorites()..ids = ['t1', 't2', 't3', 't4', 't5'],
      );
      final tracks = List.generate(5, (i) => track(id: 't${i + 1}'));

      final first = plugin.buildQueueFor([...tracks], 'Daily Mix');
      final second = plugin.buildQueueFor([...tracks], 'Daily Mix');

      expect(first.map((t) => t.id), second.map((t) => t.id));
    });

    test('two Weekly Mix calls on the same real day (necessarily the '
        'same week) return identical track order', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry.register(
        IFavoritesProvider,
        _FakeFavorites()..ids = ['t1', 't2', 't3', 't4', 't5'],
      );
      final tracks = List.generate(5, (i) => track(id: 't${i + 1}'));

      final first = plugin.buildQueueFor([...tracks], 'Weekly Mix');
      final second = plugin.buildQueueFor([...tracks], 'Weekly Mix');

      expect(first.map((t) => t.id), second.map((t) => t.id));
    });

    test('result never exceeds the default limit of 50', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      final ids = List.generate(80, (i) => 't$i');
      ctx.servicesRegistry.register(IFavoritesProvider, _FakeFavorites()..ids = ids);
      final tracks = List.generate(80, (i) => track(id: 't$i'));

      final result = plugin.buildQueueFor(tracks, 'Daily Mix');

      expect(result.length, 50);
    });

    test('an empty tracks list returns empty without crashing', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['t1']);

      expect(plugin.buildQueueFor(const [], 'Daily Mix'), isEmpty);
    });

    test('query matching is case-insensitive, same as every other preset '
        'name here', () {
      final plugin = QueuePresetPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      ctx.servicesRegistry
          .register(IFavoritesProvider, _FakeFavorites()..ids = ['t1']);
      final t1 = track(id: 't1');

      expect(plugin.buildQueueFor([t1], 'daily mix'), [t1]);
      expect(plugin.buildQueueFor([t1], 'weekly mix'), [t1]);
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
