import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/hardware_eq_band.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/equalizer_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
