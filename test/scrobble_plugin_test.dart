import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/play_record.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/scrobble_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only `services` is stubbed — the only context member this plugin's
/// lifecycle touches, same "stub only what's used" shape
/// `replay_gain_plugin_test.dart`'s `_FakeContext` already establishes.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track({
    required String id,
    String title = 'Title',
    List<String> artists = const ['Artist'],
  }) =>
      BaseTrack(
        id: id,
        title: title,
        artists: artists,
        album: 'Album',
        duration: 200,
        type: TrackType.local,
      );

  group('onTrackStart', () {
    test('records a PlayRecord with joined artist names and persists it',
        () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1', title: 'Song', artists: const ['A', 'B']));

      expect(plugin.playRecords, hasLength(1));
      final record = plugin.playRecords.single;
      expect(record.trackId, 't1');
      expect(record.title, 'Song');
      expect(record.artist, 'A, B');

      // Persisted, not just in-memory: a fresh instance reading the same
      // storage should see it too.
      final fresh = ScrobblePlugin();
      await fresh.storage.initialize();
      await fresh.initialize();
      expect(fresh.playRecords, hasLength(1));
      expect(fresh.playRecords.single.trackId, 't1');
    });

    test('history caps at 500 entries, dropping the oldest first', () async {
      final plugin = ScrobblePlugin();
      for (var i = 0; i < 505; i++) {
        await plugin.onTrackStart(track(id: 't$i'));
      }
      expect(plugin.playRecords, hasLength(500));
      // The oldest 5 (t0..t4) should have been evicted; the first
      // surviving entry is t5, the last is t504.
      expect(plugin.playRecords.first.trackId, 't5');
      expect(plugin.playRecords.last.trackId, 't504');

      // The cap applies to what's persisted too, not just the in-memory
      // list.
      final fresh = ScrobblePlugin();
      await fresh.storage.initialize();
      await fresh.initialize();
      expect(fresh.playRecords, hasLength(500));
    });
  });

  group('recentlyPlayed', () {
    test('newest first', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't2'));
      await plugin.onTrackStart(track(id: 't3'));

      expect(
        plugin.recentlyPlayed().map((r) => r.trackId).toList(),
        ['t3', 't2', 't1'],
      );
    });

    test('deduped to one (most recent) entry per track', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1', title: 'First play'));
      await plugin.onTrackStart(track(id: 't2'));
      await plugin.onTrackStart(track(id: 't1', title: 'Second play'));

      final result = plugin.recentlyPlayed();
      expect(result.map((r) => r.trackId).toList(), ['t1', 't2']);
      // The kept t1 entry is the most recent play, not the first.
      expect(result.first.title, 'Second play');
    });

    test('tracks with an empty trackId are skipped', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: ''));
      await plugin.onTrackStart(track(id: 't1'));

      expect(plugin.recentlyPlayed().map((r) => r.trackId).toList(), ['t1']);
    });

    test('respects limit', () async {
      final plugin = ScrobblePlugin();
      for (var i = 0; i < 5; i++) {
        await plugin.onTrackStart(track(id: 't$i'));
      }
      expect(plugin.recentlyPlayed(limit: 2), hasLength(2));
    });

    test('empty history returns empty', () {
      final plugin = ScrobblePlugin();
      expect(plugin.recentlyPlayed(), isEmpty);
    });
  });

  group('mostPlayedIds', () {
    test('counts plays per track, sorted most-played first', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't2'));
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't2'));

      final result = plugin.mostPlayedIds();
      expect(result.map((e) => e.key), ['t1', 't2']);
      expect(result.map((e) => e.value), [3, 2]);
    });

    test('tracks with an empty trackId are excluded from the count',
        () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: ''));
      await plugin.onTrackStart(track(id: ''));
      await plugin.onTrackStart(track(id: 't1'));

      final result = plugin.mostPlayedIds();
      expect(result.map((e) => e.key), ['t1']);
      expect(result.map((e) => e.value), [1]);
    });

    test('respects limit', () async {
      final plugin = ScrobblePlugin();
      for (var i = 0; i < 5; i++) {
        await plugin.onTrackStart(track(id: 't$i'));
      }
      expect(plugin.mostPlayedIds(limit: 2), hasLength(2));
    });

    test('empty history returns empty', () {
      final plugin = ScrobblePlugin();
      expect(plugin.mostPlayedIds(), isEmpty);
    });
  });

  group('playCountFor', () {
    test('counts exact matches only', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't1'));
      await plugin.onTrackStart(track(id: 't2'));

      expect(plugin.playCountFor('t1'), 2);
      expect(plugin.playCountFor('t2'), 1);
      expect(plugin.playCountFor('never-played'), 0);
    });
  });

  group('persistence — defensive decoding', () {
    test('a fresh instance with no stored history starts empty', () async {
      final plugin = ScrobblePlugin();
      await plugin.storage.initialize();
      await plugin.initialize();
      expect(plugin.playRecords, isEmpty);
    });

    test('malformed JSON in storage degrades to empty history, not a '
        'thrown error', () async {
      final plugin = ScrobblePlugin();
      await plugin.storage.initialize();
      await plugin.storage.setString('play_history', 'not json');
      await plugin.initialize();
      expect(plugin.playRecords, isEmpty);
    });

    test('a non-list JSON value in storage degrades to empty history',
        () async {
      final plugin = ScrobblePlugin();
      await plugin.storage.initialize();
      await plugin.storage.setString('play_history', '{"not":"a list"}');
      await plugin.initialize();
      expect(plugin.playRecords, isEmpty);
    });

    test('a malformed entry among otherwise-valid ones does not take down '
        'the whole list — PlayRecord.fromJson degrades per-field, not '
        'per-entry, so an entry with unexpected field types still decodes '
        'rather than throwing', () async {
      final plugin = ScrobblePlugin();
      await plugin.storage.initialize();
      await plugin.storage.setString(
        'play_history',
        '[{"trackId":"t1","title":"A","artist":"B","playedAtMs":1000},'
        '{"trackId":123,"title":null,"artist":null,"playedAtMs":"oops"}]',
      );
      await plugin.initialize();
      expect(plugin.playRecords, hasLength(2));
      expect(plugin.playRecords.first.trackId, 't1');
    });
  });

  group('clearHistory', () {
    test('resets the in-memory list and removes the persisted key', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      expect(plugin.playRecords, isNotEmpty);

      await plugin.clearHistory();
      expect(plugin.playRecords, isEmpty);

      final fresh = ScrobblePlugin();
      await fresh.storage.initialize();
      await fresh.initialize();
      expect(fresh.playRecords, isEmpty);
    });
  });

  group('legacy history getter', () {
    test('formats each record as "title • artist"', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1', title: 'Song', artists: const ['Band']));
      expect(plugin.history, ['Song • Band']);
    });
  });

  group('playRecords', () {
    test('is unmodifiable', () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      final extra = PlayRecord(trackId: 't2', title: 'X', artist: 'Y', playedAt: DateTime.now());
      expect(() => plugin.playRecords.add(extra), throwsUnsupportedError);
    });
  });

  group('uiSlot', () {
    test('now_playing_overlay returns null when history is empty', () {
      final plugin = ScrobblePlugin();
      expect(plugin.uiSlot('now_playing_overlay'), isNull);
    });

    test('now_playing_overlay returns a widget once there is history',
        () async {
      final plugin = ScrobblePlugin();
      await plugin.onTrackStart(track(id: 't1'));
      expect(plugin.uiSlot('now_playing_overlay'), isNotNull);
    });

    test('plugin_settings always returns a widget', () {
      final plugin = ScrobblePlugin();
      expect(plugin.uiSlot('plugin_settings'), isNotNull);
    });

    test('an unknown location returns null', () {
      final plugin = ScrobblePlugin();
      expect(plugin.uiSlot('not_a_real_slot'), isNull);
    });
  });

  group('lifecycle', () {
    test('initialize registers IPlayHistoryProvider; dispose unregisters it',
        () async {
      final plugin = ScrobblePlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isTrue);
      expect(ctx.servicesRegistry.get<IPlayHistoryProvider>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = ScrobblePlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IPlayHistoryProvider>(), isTrue);
    });

    test('initialize/enable/disable/dispose are no-ops without an attached '
        'context', () async {
      final plugin = ScrobblePlugin();
      await plugin.initialize();
      await plugin.enable();
      await plugin.disable();
      await plugin.dispose();
    });
  });
}
