import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/repeat_mode.dart';
import 'package:omnis_plugins/shuffle_repeat_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A no-op stand-in for PluginContext — only `queue`/`currentTrack`/
/// `setQueue`/`repeatMode`/`setRepeatMode` are stubbed, since those are
/// all `ShuffleRepeatPlugin` ever touches on a context, the same
/// minimal-surface shape `equalizer_plugin_test.dart`'s own
/// `_FakeContext` already establishes.
class _FakeContext implements PluginContext {
  List<BaseTrack> queueOverride = const [];
  BaseTrack? currentTrackOverride;
  RepeatMode repeatModeOverride = RepeatMode.off;

  List<BaseTrack>? lastSetQueue;
  int? lastSetQueueStartIndex;
  final List<RepeatMode> setRepeatModeCalls = [];

  @override
  List<BaseTrack> get queue => queueOverride;

  @override
  BaseTrack? get currentTrack => currentTrackOverride;

  @override
  RepeatMode get repeatMode => repeatModeOverride;

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    repeatModeOverride = mode;
    setRepeatModeCalls.add(mode);
  }

  @override
  Future<void> setQueue(List<BaseTrack> tracks, {int startIndex = 0}) async {
    lastSetQueue = tracks;
    lastSetQueueStartIndex = startIndex;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// Independently re-derives `ShuffleRepeatPlugin._conflicts`'s documented
/// definition (shared primary artist, or a shared non-"Unknown Album"
/// album) rather than calling the private method — this is the property
/// the ordering algorithm promises to avoid, so the test asserts the
/// *outcome* against that definition, not against the implementation's
/// own internals.
bool _conflicts(BaseTrack a, BaseTrack b) {
  final sameArtist = a.artists.isNotEmpty &&
      b.artists.isNotEmpty &&
      a.artists.first == b.artists.first;
  final sameAlbum =
      a.album.isNotEmpty && a.album != 'Unknown Album' && a.album == b.album;
  return sameArtist || sameAlbum;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id,
          {required String artist, String album = 'Album'}) =>
      BaseTrack(
        id: id,
        title: 'Title $id',
        artists: [artist],
        album: album,
        duration: 180,
        type: TrackType.local,
      );

  group('deClusteredOrder', () {
    test('fewer than 3 tracks is returned unchanged, in the same order',
        () {
      final tracks = [track('1', artist: 'A'), track('2', artist: 'A')];

      final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);

      expect(result.map((t) => t.id), ['1', '2']);
    });

    test('an empty list stays empty', () {
      expect(ShuffleRepeatPlugin.deClusteredOrder(const []), isEmpty);
    });

    test('the result is always a permutation of the input — no track '
        'dropped or duplicated', () {
      final tracks = [
        for (var i = 0; i < 12; i++)
          track('$i', artist: 'Artist ${i % 4}', album: 'Album ${i % 3}'),
      ];

      for (var trial = 0; trial < 25; trial++) {
        final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);
        expect(result.map((t) => t.id).toSet(), tracks.map((t) => t.id).toSet());
        expect(result, hasLength(tracks.length));
      }
    });

    test('no two adjacent tracks conflict (same artist or same real '
        'album) when avoiding it is mathematically possible — checked '
        'across many trials since the algorithm shuffles internally',
        () {
      // No artist holds a majority (3 artists x 4 tracks = 12, each
      // exactly 1/3) and albums are deliberately spread so an
      // artist-only interleave can't accidentally leave a same-album
      // pair adjacent without the stage-2 swap pass catching it.
      final tracks = [
        for (var artistIndex = 0; artistIndex < 3; artistIndex++)
          for (var n = 0; n < 4; n++)
            track('$artistIndex-$n',
                artist: 'Artist $artistIndex', album: 'Album $artistIndex-$n'),
      ];

      for (var trial = 0; trial < 50; trial++) {
        final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);
        for (var i = 1; i < result.length; i++) {
          expect(_conflicts(result[i - 1], result[i]), isFalse,
              reason: 'trial $trial: ${result[i - 1].id} and '
                  '${result[i].id} are adjacent and conflict');
        }
      }
    });

    test('same-album adjacency is avoided even across different artists',
        () {
      // Two different artists share one "compilation" album, plus enough
      // other distinct tracks that avoiding the album clash is possible.
      final tracks = [
        track('a1', artist: 'Artist A', album: 'Split EP'),
        track('a2', artist: 'Artist B', album: 'Split EP'),
        track('a3', artist: 'Artist C', album: 'Solo Album C'),
        track('a4', artist: 'Artist D', album: 'Solo Album D'),
        track('a5', artist: 'Artist E', album: 'Solo Album E'),
        track('a6', artist: 'Artist F', album: 'Solo Album F'),
      ];

      for (var trial = 0; trial < 50; trial++) {
        final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);
        for (var i = 1; i < result.length; i++) {
          expect(_conflicts(result[i - 1], result[i]), isFalse,
              reason: 'trial $trial: ${result[i - 1].id} and '
                  '${result[i].id} are adjacent and conflict');
        }
      }
    });

    test('a single dominant artist (>50% of tracks) still produces every '
        'track with no crash — some adjacency is unavoidable here, but '
        'the algorithm must degrade gracefully, not break', () {
      final tracks = [
        track('d1', artist: 'Dominant'),
        track('d2', artist: 'Dominant'),
        track('d3', artist: 'Dominant'),
        track('d4', artist: 'Dominant'),
        track('o1', artist: 'Other'),
      ];

      final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);

      expect(result.map((t) => t.id).toSet(), tracks.map((t) => t.id).toSet());
    });

    test('a track with an "Unknown Album" is never treated as sharing '
        'that album with another "Unknown Album" track', () {
      final tracks = [
        track('u1', artist: 'Artist U1', album: 'Unknown Album'),
        track('u2', artist: 'Artist U2', album: 'Unknown Album'),
        track('u3', artist: 'Artist U3', album: 'Unknown Album'),
      ];

      // These three would only ever conflict on artist (all distinct
      // here) since "Unknown Album" is explicitly excluded from the
      // album-conflict definition — so any order is fine; this just
      // proves it doesn't throw or drop tracks on the special case.
      final result = ShuffleRepeatPlugin.deClusteredOrder(tracks);
      expect(result, hasLength(3));
    });
  });

  group('toggleShuffle', () {
    test('turning shuffle on reorders the live queue and persists the '
        'flag', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext()
        ..queueOverride = [
          track('1', artist: 'A'),
          track('2', artist: 'B'),
          track('3', artist: 'C'),
        ];
      plugin.attach(ctx);

      await plugin.toggleShuffle();

      expect(plugin.shuffleEnabled, isTrue);
      expect(ctx.lastSetQueue, isNotNull);
      expect(ctx.lastSetQueue!.map((t) => t.id).toSet(), {'1', '2', '3'});

      // shuffleEnabled itself is populated by initialize(), which reads
      // storage synchronously — a fresh PluginStorage starts cold until
      // something awaits it, same as ratings_plugin_test.dart's own
      // "persists across a fresh instance" check, so warm it explicitly
      // first.
      final fresh = ShuffleRepeatPlugin();
      await fresh.storage.initialize();
      await fresh.initialize();
      expect(fresh.shuffleEnabled, isTrue);
    });

    test('turning shuffle back off restores the exact pre-shuffle order',
        () async {
      final plugin = ShuffleRepeatPlugin();
      final original = [
        track('1', artist: 'A'),
        track('2', artist: 'B'),
        track('3', artist: 'C'),
      ];
      final ctx = _FakeContext()..queueOverride = original;
      plugin.attach(ctx);

      await plugin.toggleShuffle(); // on
      // Simulate the engine now reporting the shuffled queue back.
      ctx.queueOverride = ctx.lastSetQueue!;

      await plugin.toggleShuffle(); // off

      expect(plugin.shuffleEnabled, isFalse);
      expect(ctx.lastSetQueue!.map((t) => t.id), ['1', '2', '3']);
    });

    test('toggling with no context attached still flips and persists '
        'state without throwing', () async {
      final plugin = ShuffleRepeatPlugin();

      await plugin.toggleShuffle();

      expect(plugin.shuffleEnabled, isTrue);
    });

    test('turning shuffle on with an empty queue does not call setQueue '
        'and does not throw', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext()..queueOverride = const [];
      plugin.attach(ctx);

      await plugin.toggleShuffle();

      expect(plugin.shuffleEnabled, isTrue);
      expect(ctx.lastSetQueue, isNull);
    });

    test('the start index follows the current track into its new '
        'shuffled position', () async {
      final plugin = ShuffleRepeatPlugin();
      final current = track('2', artist: 'B');
      final ctx = _FakeContext()
        ..queueOverride = [
          track('1', artist: 'A'),
          current,
          track('3', artist: 'C'),
        ]
        ..currentTrackOverride = current;
      plugin.attach(ctx);

      await plugin.toggleShuffle();

      final newIndex = ctx.lastSetQueue!.indexWhere((t) => t.id == '2');
      expect(ctx.lastSetQueueStartIndex, newIndex);
    });

    test('a current track no longer present in the reordered queue '
        'clamps the start index to 0 rather than passing through a '
        'raw -1 from indexWhere', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext()
        ..queueOverride = [track('1', artist: 'A'), track('2', artist: 'B')]
        // A "current" track that isn't actually in the queue at all.
        ..currentTrackOverride = track('missing', artist: 'Z');
      plugin.attach(ctx);

      await plugin.toggleShuffle();

      expect(ctx.lastSetQueueStartIndex, 0);
    });
  });

  group('cycleRepeat', () {
    test('cycles off -> all -> one -> off, persisting and forwarding '
        'each step to the context', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      expect(plugin.repeatMode, RepeatMode.off);

      await plugin.cycleRepeat();
      expect(plugin.repeatMode, RepeatMode.all);

      await plugin.cycleRepeat();
      expect(plugin.repeatMode, RepeatMode.one);

      await plugin.cycleRepeat();
      expect(plugin.repeatMode, RepeatMode.off);

      expect(ctx.setRepeatModeCalls,
          [RepeatMode.all, RepeatMode.one, RepeatMode.off]);
    });
  });

  group('cyclePlayMode', () {
    test('from off/off: all -> one -> (off + shuffle on)', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext()
        ..queueOverride = [track('1', artist: 'A'), track('2', artist: 'B')];
      plugin.attach(ctx);

      await plugin.cyclePlayMode();
      expect(plugin.repeatMode, RepeatMode.all);
      expect(plugin.shuffleEnabled, isFalse);

      await plugin.cyclePlayMode();
      expect(plugin.repeatMode, RepeatMode.one);
      expect(plugin.shuffleEnabled, isFalse);

      await plugin.cyclePlayMode();
      expect(plugin.repeatMode, RepeatMode.off);
      expect(plugin.shuffleEnabled, isTrue);
    });

    test('once shuffle is on, cyclePlayMode turns it back off instead '
        'of touching repeat', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext()
        ..queueOverride = [track('1', artist: 'A'), track('2', artist: 'B')];
      plugin.attach(ctx);
      await plugin.toggleShuffle();
      expect(plugin.shuffleEnabled, isTrue);

      await plugin.cyclePlayMode();

      expect(plugin.shuffleEnabled, isFalse);
      expect(plugin.repeatMode, RepeatMode.off);
      expect(ctx.setRepeatModeCalls, isEmpty,
          reason: 'shuffle -> off is a pure toggleShuffle call, repeat '
              'is never touched by this transition');
    });
  });

  group('initialize', () {
    test('restores persisted shuffle and repeat state', () async {
      final seed = ShuffleRepeatPlugin();
      final ctx = _FakeContext();
      seed.attach(ctx);
      await seed.toggleShuffle();
      await seed.cycleRepeat(); // off -> all

      // A fresh PluginStorage starts cold until something awaits it —
      // warm it explicitly, the same as the toggleShuffle group's
      // equivalent check above.
      final fresh = ShuffleRepeatPlugin();
      await fresh.storage.initialize();
      final freshCtx = _FakeContext();
      fresh.attach(freshCtx);
      await fresh.initialize();

      expect(fresh.shuffleEnabled, isTrue);
      expect(freshCtx.setRepeatModeCalls, [RepeatMode.all]);
    });

    test('a fresh install with nothing persisted defaults to shuffle '
        'off, repeat off', () async {
      final plugin = ShuffleRepeatPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.initialize();

      expect(plugin.shuffleEnabled, isFalse);
      expect(ctx.setRepeatModeCalls, [RepeatMode.off]);
    });
  });
}
