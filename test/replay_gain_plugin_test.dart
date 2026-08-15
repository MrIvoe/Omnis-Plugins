import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/replay_gain_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A no-op stand-in for PluginContext — only `currentTrack` and `setGain`
/// are stubbed, since those are all `setPreampDb`/`setUseAlbumGain`'s
/// "re-apply immediately" behavior touches, the same shape
/// `equalizer_plugin_test.dart`'s own `_FakeContext` already establishes.
class _FakeContext implements PluginContext {
  BaseTrack? currentTrackOverride;
  String? lastGainSource;
  double? lastGainMultiplier;

  @override
  BaseTrack? get currentTrack => currentTrackOverride;

  @override
  ServiceRegistry get services => ServiceRegistry();

  @override
  Future<void> setGain(String source, double multiplier) async {
    lastGainSource = source;
    lastGainMultiplier = multiplier;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track({double? trackGain, double? albumGain}) => BaseTrack(
        id: 't1',
        title: 'Title',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: TrackType.local,
        replayGain: (trackGain == null && albumGain == null)
            ? null
            : ReplayGainValues(trackGain: trackGain, albumGain: albumGain),
      );

  group('track gain (default mode)', () {
    test('uses trackGain when present', () {
      final plugin = ReplayGainPlugin();
      plugin.setReplayGain(track(trackGain: -6.0));

      expect(plugin.multiplier, closeTo(1.3, 0.0001));
    });

    test('ignores albumGain even when present — default mode is track '
        'gain only', () {
      final plugin = ReplayGainPlugin();
      plugin.setReplayGain(track(trackGain: -6.0, albumGain: -3.0));

      expect(plugin.multiplier, closeTo(1.3, 0.0001));
    });

    test('no ReplayGain data at all leaves the multiplier at 1.0', () {
      final plugin = ReplayGainPlugin();
      plugin.setReplayGain(track());

      expect(plugin.multiplier, 1.0);
    });
  });

  group('album gain mode', () {
    test('useAlbumGain defaults to false', () {
      expect(ReplayGainPlugin().useAlbumGain, isFalse);
    });

    test('uses albumGain, not trackGain, once enabled', () async {
      final plugin = ReplayGainPlugin();
      await plugin.setUseAlbumGain(true);
      plugin.setReplayGain(track(trackGain: -6.0, albumGain: -3.0));

      expect(plugin.multiplier, closeTo(1.15, 0.0001));
    });

    test('falls back to trackGain when a track has no album gain tag — '
        'never silently leaves a track unnormalized just because the '
        'specific field asked for is missing', () async {
      final plugin = ReplayGainPlugin();
      await plugin.setUseAlbumGain(true);
      plugin.setReplayGain(track(trackGain: -6.0, albumGain: null));

      expect(plugin.multiplier, closeTo(1.3, 0.0001));
    });

    test('useAlbumGain persists across a fresh plugin instance', () async {
      final plugin = ReplayGainPlugin();
      await plugin.setUseAlbumGain(true);

      final freshInstance = ReplayGainPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.useAlbumGain, isTrue);
    });

    test('setUseAlbumGain re-applies immediately against the current '
        'track, not just the next one', () async {
      final plugin = ReplayGainPlugin();
      final fakeContext = _FakeContext()
        ..currentTrackOverride = track(trackGain: -6.0, albumGain: -3.0);
      plugin.attach(fakeContext);

      await plugin.setUseAlbumGain(true);

      expect(fakeContext.lastGainSource, ReplayGainPlugin.gainSource);
      expect(fakeContext.lastGainMultiplier, closeTo(1.15, 0.0001));
    });

    test('setUseAlbumGain is a harmless no-op for gain re-application '
        'when there is no current track', () async {
      final plugin = ReplayGainPlugin();
      final fakeContext = _FakeContext();
      plugin.attach(fakeContext);

      await plugin.setUseAlbumGain(true);

      expect(fakeContext.lastGainSource, isNull);
    });
  });

  group('preamp composes with either gain mode', () {
    test('a positive preamp still boosts the album-gain-derived base',
        () async {
      final plugin = ReplayGainPlugin();
      await plugin.setUseAlbumGain(true);
      await plugin.setPreampDb(6.0);
      plugin.setReplayGain(track(trackGain: -6.0, albumGain: -3.0));

      // base (album gain -3dB) = 1.15, preamp +6dB multiplier = 1.5
      expect(plugin.multiplier, closeTo((1.15 * 1.5).clamp(0.3, 2.0), 0.0001));
    });
  });
}
