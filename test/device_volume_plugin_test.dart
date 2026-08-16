import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/device_volume_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A no-op stand-in for PluginContext — only `services`, `volume`, and
/// `setVolume` are stubbed, since those are all DeviceVolumePlugin
/// touches.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry;
  double _volume = 1.0;
  _FakeContext(this.servicesRegistry);

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// A minimal IDeviceConnectivityProvider whose device can be changed on
/// demand, for testing DeviceVolumePlugin's per-device persistence
/// without a real BluetoothPlaybackPlugin.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('an unattached plugin has no saved profile and no current device',
      () {
    final plugin = DeviceVolumePlugin();
    expect(plugin.currentDevice, isNull);
    expect(plugin.savedVolumeForCurrentDevice, isNull);
    expect(plugin.hasSavedProfileForCurrentDevice, isFalse);
  });

  test('setVolumeForCurrentDevice applies the volume and persists it',
      () async {
    final registry = ServiceRegistry();
    final context = _FakeContext(registry);
    final plugin = DeviceVolumePlugin();
    plugin.attach(context);
    await plugin.storage.initialize();
    await plugin.initialize();

    await plugin.setVolumeForCurrentDevice(0.4);

    expect(context.volume, 0.4);
    expect(plugin.savedVolumeForCurrentDevice, 0.4);
  });

  test('setVolumeForCurrentDevice clamps to 0..1', () async {
    final registry = ServiceRegistry();
    final context = _FakeContext(registry);
    final plugin = DeviceVolumePlugin();
    plugin.attach(context);
    await plugin.storage.initialize();
    await plugin.initialize();

    await plugin.setVolumeForCurrentDevice(1.7);
    expect(context.volume, 1.0);

    await plugin.setVolumeForCurrentDevice(-0.5);
    expect(context.volume, 0.0);
  });

  group('per-device profiles', () {
    test(
        'each connected device gets its own volume profile, and switching '
        'devices restores the right one', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);
      final context = _FakeContext(registry);

      final plugin = DeviceVolumePlugin();
      plugin.attach(context);
      await plugin.storage.initialize();
      await plugin.initialize();

      // No device connected yet — this is the shared default slot.
      await plugin.setVolumeForCurrentDevice(0.9);

      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      // A fresh device with no saved profile is left alone, not
      // carrying over the default profile's volume.
      expect(plugin.hasSavedProfileForCurrentDevice, isFalse);
      expect(context.volume, 0.9,
          reason: 'volume is untouched until a profile is explicitly set');
      await plugin.setVolumeForCurrentDevice(0.4);

      deviceProvider.connect('Headphones');
      await Future<void>.delayed(Duration.zero);
      expect(plugin.hasSavedProfileForCurrentDevice, isFalse);
      await plugin.setVolumeForCurrentDevice(0.6);

      // Switching back to a previously-configured device restores its
      // own remembered volume, not the most recently set one.
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      expect(context.volume, 0.4);

      deviceProvider.connect(null);
      await Future<void>.delayed(Duration.zero);
      expect(context.volume, 0.9,
          reason: 'disconnecting restores the shared default profile');
    });

    test('a device profile persists across a fresh plugin instance, keyed '
        'independently of the default profile', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);

      final plugin = DeviceVolumePlugin();
      plugin.attach(_FakeContext(registry));
      await plugin.storage.initialize();
      await plugin.initialize();
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      await plugin.setVolumeForCurrentDevice(0.7);

      final restoredContext = _FakeContext(registry);
      final restored = DeviceVolumePlugin();
      restored.attach(restoredContext);
      await restored.storage.initialize();
      deviceProvider.connect('Car Stereo');
      await restored.initialize();

      expect(restored.savedVolumeForCurrentDevice, 0.7);
      expect(restoredContext.volume, 0.7,
          reason: 'initialize() applies an already-saved profile for the '
              'currently connected device immediately');
    });

    test('forgetCurrentDeviceProfile removes the saved profile without '
        'changing the current volume', () async {
      final registry = ServiceRegistry();
      final deviceProvider = _FakeDeviceProvider();
      registry.register(IDeviceConnectivityProvider, deviceProvider);
      final context = _FakeContext(registry);

      final plugin = DeviceVolumePlugin();
      plugin.attach(context);
      await plugin.storage.initialize();
      await plugin.initialize();
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      await plugin.setVolumeForCurrentDevice(0.4);
      expect(plugin.hasSavedProfileForCurrentDevice, isTrue);

      await plugin.forgetCurrentDeviceProfile();

      expect(plugin.hasSavedProfileForCurrentDevice, isFalse);
      expect(context.volume, 0.4,
          reason: 'forgetting a profile does not itself change the volume');

      deviceProvider.connect(null);
      await Future<void>.delayed(Duration.zero);
      deviceProvider.connect('Car Stereo');
      await Future<void>.delayed(Duration.zero);
      expect(context.volume, 0.4,
          reason: 'reconnecting no longer restores the forgotten profile');
    });
  });
}
