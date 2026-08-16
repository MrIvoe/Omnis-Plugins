import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/hardware_eq_band.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/equalizer_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

BaseTrack _track({
  required String id,
  List<String> artists = const ['Artist'],
  String album = 'Album',
}) =>
    BaseTrack(
      id: id,
      title: 'Title $id',
      artists: artists,
      album: album,
      duration: 180,
      type: TrackType.local,
    );

/// A no-op stand-in for PluginContext — only `services`, `hardwareEqBands`,
/// `setGain`, and `ensureHardwareEqLoaded` are stubbed, since those are
/// all EqualizerPlugin.initialize() touches on a context with no real
/// hardware bands.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry;
  _FakeContext(this.servicesRegistry);

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  List<HardwareEqBand>? get hardwareEqBands => const [];

  @override
  Future<void> setGain(String source, double multiplier) async {}

  @override
  Future<void> ensureHardwareEqLoaded() async {}

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// A minimal IDeviceConnectivityProvider whose device can be changed on
/// demand, for testing EqualizerPlugin's per-device persistence without
/// a real BluetoothPlaybackPlugin.
class _FakeDeviceProvider implements IDeviceConnectivityProvider {
  final _controller = StreamController<String?>.broadcast();
  String? _current;

  @override
  String? get connectedDeviceName => _current;

  @override
  Stream<String?> get deviceChanges => _controller.stream;

  void connect(String? device) {
    _current = device;
    _controller.add(device);
  }
}

/// Virtual-band math and storage persistence — no `PluginContext`
/// needed. `hardwareBands` reads `context?.hardwareEqBands ?? const []`,
/// so an unattached instance always takes the virtual-model path, which
/// is exactly what these tests exercise. Hardware-band restoration
/// (needs a real/fake `AudioEngine`) stays covered in Omnis's own test
/// suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('every virtual band starts flat at 0.0', () {
    final plugin = EqualizerPlugin();
    for (final key in EqualizerPlugin.virtualBandKeys) {
      expect(plugin.getBand(key), 0.0);
    }
  });

  test('setBand updates the band and clamps to +/-12dB', () {
    final plugin = EqualizerPlugin();
    plugin.setBand('bass', 6.0);
    expect(plugin.getBand('bass'), 6.0);

    plugin.setBand('bass', 99.0);
    expect(plugin.getBand('bass'), 12.0);

    plugin.setBand('bass', -99.0);
    expect(plugin.getBand('bass'), -12.0);
  });

  test('setBand on an unknown key is a harmless no-op', () {
    final plugin = EqualizerPlugin();
    plugin.setBand('nonexistent', 6.0);
    expect(plugin.getBand('nonexistent'), 0.0);
  });

  test('combinedMultiplier is 1.0 when every band is flat', () {
    final plugin = EqualizerPlugin();
    expect(plugin.combinedMultiplier, 1.0);
  });

  test('combinedMultiplier increases with a positive band boost', () {
    final plugin = EqualizerPlugin();
    plugin.setBand('bass', 6.0);
    expect(plugin.combinedMultiplier, greaterThan(1.0));
  });

  test('persistVirtualBands survives a fresh plugin instance', () async {
    final plugin = EqualizerPlugin();
    plugin.setBand('treble', 4.0);
    await plugin.persistVirtualBands();

    final restored = EqualizerPlugin();
    await restored.storage.initialize();
    await restored.initialize();

    expect(restored.getBand('treble'), 4.0);
  });

  test('hasHardwareBands is false without a real PluginContext attached',
      () {
    final plugin = EqualizerPlugin();
    expect(plugin.hasHardwareBands, isFalse);
  });

  group('per-device profiles', () {
    test(
        'each connected device gets its own virtual-band profile, and '
        'switching devices swaps in the right one', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);
      final context = _FakeContext(registry);

      final plugin = EqualizerPlugin();
      plugin.attach(context);
      await plugin.storage.initialize();
      await plugin.initialize();

      // No device connected yet — this is the shared default profile.
      plugin.setBand('bass', 2.0);
      await plugin.persistVirtualBands();

      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      // A fresh device with no saved profile starts flat, not carrying
      // over the default profile's bass boost.
      expect(plugin.getBand('bass'), 0.0);
      plugin.setBand('bass', 8.0);
      await plugin.persistVirtualBands();

      deviceProvider.connect('Headphones');
      await Future<void>.delayed(Duration.zero);
      expect(plugin.getBand('bass'), 0.0);
      plugin.setBand('bass', -5.0);
      await plugin.persistVirtualBands();

      // Switching back to a previously-configured device restores its
      // own profile, not the most recently edited one.
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      expect(plugin.getBand('bass'), 8.0);

      deviceProvider.connect(null);
      await Future<void>.delayed(Duration.zero);
      expect(plugin.getBand('bass'), 2.0,
          reason: 'disconnecting restores the shared default profile');
    });

    test(
        'a device profile persists across a fresh plugin instance, keyed '
        'independently of the default profile', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);

      final plugin = EqualizerPlugin();
      plugin.attach(_FakeContext(registry));
      await plugin.storage.initialize();
      await plugin.initialize();
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      plugin.setBand('treble', 6.0);
      await plugin.persistVirtualBands();

      final restored = EqualizerPlugin();
      restored.attach(_FakeContext(registry));
      await restored.storage.initialize();
      await restored.initialize();
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);

      expect(restored.getBand('treble'), 6.0);
      expect(restored.getBand('bass'), 0.0,
          reason: 'the default profile is untouched by the device one');
    });
  });

  group('per-artist/per-album profiles (item 20)', () {
    test('currentArtist/currentAlbum are null before any track has '
        'started', () {
      final plugin = EqualizerPlugin();
      expect(plugin.currentArtist, isNull);
      expect(plugin.currentAlbum, isNull);
    });

    test('onTrackStart exposes the track\'s primary artist and album',
        () async {
      final plugin = EqualizerPlugin();
      await plugin.storage.initialize();
      await plugin.initialize();

      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Boards of Canada'], album: 'Geogaddi'),
      );

      expect(plugin.currentArtist, 'Boards of Canada');
      expect(plugin.currentAlbum, 'Geogaddi');
    });

    test('persistVirtualBandsForArtist/Album are no-ops with no track '
        'played yet', () async {
      final plugin = EqualizerPlugin();
      plugin.setBand('bass', 5.0);

      await expectLater(plugin.persistVirtualBandsForArtist(), completes);
      await expectLater(plugin.persistVirtualBandsForAlbum(), completes);

      final restored = EqualizerPlugin();
      await restored.storage.initialize();
      // Nothing should have been saved under any artist/album key — the
      // default profile is still whatever it was (flat).
      await restored.initialize();
      expect(restored.getBand('bass'), 0.0);
    });

    test('a saved artist profile auto-applies for another track by the '
        'same artist, distinct from the shared default', () async {
      final plugin = EqualizerPlugin();
      await plugin.storage.initialize();
      await plugin.initialize();

      // Shared default profile.
      plugin.setBand('bass', 1.0);
      await plugin.persistVirtualBands();

      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Album 1'),
      );
      expect(plugin.getBand('bass'), 1.0,
          reason: 'no artist/album profile yet for this track — falls '
              'back to the shared default profile, same as before '
              'artist/album profiles existed');
      plugin.setBand('bass', 7.0);
      await plugin.persistVirtualBandsForArtist();

      // A different track, same artist, different album.
      await plugin.onTrackStart(
        _track(id: '2', artists: const ['Artist A'], album: 'Album 2'),
      );
      expect(plugin.getBand('bass'), 7.0,
          reason: 'the artist profile applies regardless of album');

      // A track by a different artist gets the shared default again,
      // not the other artist's profile.
      await plugin.onTrackStart(
        _track(id: '3', artists: const ['Artist B'], album: 'Album 3'),
      );
      expect(plugin.getBand('bass'), 1.0);
    });

    test('an album profile takes precedence over an artist profile for '
        'the same track', () async {
      final plugin = EqualizerPlugin();
      await plugin.storage.initialize();
      await plugin.initialize();

      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Loud Album'),
      );
      plugin.setBand('bass', 6.0);
      await plugin.persistVirtualBandsForArtist();

      plugin.setBand('bass', -4.0);
      await plugin.persistVirtualBandsForAlbum();

      // Re-trigger the same track — album should win over artist.
      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Loud Album'),
      );
      expect(plugin.getBand('bass'), -4.0);

      // A different album by the same artist falls back to the artist
      // profile, since no album-specific one exists for it.
      await plugin.onTrackStart(
        _track(id: '2', artists: const ['Artist A'], album: 'Quiet Album'),
      );
      expect(plugin.getBand('bass'), 6.0);
    });

    test('an artist/album profile takes precedence over the device '
        'profile', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);
      final plugin = EqualizerPlugin();
      plugin.attach(_FakeContext(registry));
      await plugin.storage.initialize();
      await plugin.initialize();

      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      plugin.setBand('bass', 3.0);
      await plugin.persistVirtualBands();

      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Album 1'),
      );
      expect(plugin.getBand('bass'), 3.0,
          reason: 'no artist/album profile yet — the connected device\'s '
              'profile still applies');

      plugin.setBand('bass', 9.0);
      await plugin.persistVirtualBandsForArtist();

      // Move away and back to the same track — a real re-resolve, not
      // just reading back the in-memory value setBand just set, is what
      // actually proves the artist profile outranks the device one.
      await plugin.onTrackStart(
        _track(id: '99', artists: const ['Someone Else'], album: 'Other'),
      );
      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Album 1'),
      );
      expect(plugin.getBand('bass'), 9.0,
          reason: 'the artist profile now takes precedence over the '
              'still-connected device\'s own profile');
    });

    test('plain edits after saving an artist profile update that '
        'profile, not the device/default one', () async {
      final plugin = EqualizerPlugin();
      await plugin.storage.initialize();
      await plugin.initialize();

      await plugin.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Album 1'),
      );
      plugin.setBand('bass', 5.0);
      await plugin.persistVirtualBandsForArtist();

      // A plain edit + the ordinary persist (as a slider's onChangeEnd
      // would call) should update the now-active artist profile.
      plugin.setBand('bass', 2.0);
      await plugin.persistVirtualBands();

      final restored = EqualizerPlugin();
      await restored.storage.initialize();
      await restored.initialize();
      await restored.onTrackStart(
        _track(id: '1', artists: const ['Artist A'], album: 'Album 1'),
      );
      expect(restored.getBand('bass'), 2.0);
    });

    test('a track with a blank artist/album never gets a profile key '
        'built for it', () async {
      final plugin = EqualizerPlugin();
      await plugin.storage.initialize();
      await plugin.initialize();

      await plugin.onTrackStart(
        _track(id: '1', artists: const [''], album: '   '),
      );

      expect(plugin.currentArtist, isNull);
      expect(plugin.currentAlbum, isNull);
    });
  });
}
