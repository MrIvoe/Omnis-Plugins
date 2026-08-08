import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugins/driving_mode_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The GPS-detection half genuinely can't be unit tested — it needs real
/// device movement (see this plugin's own "Verification status" doc
/// comment). What's tested here is the storage/toggle half: persistence,
/// defaults, and that setEnabled/disable degrade gracefully rather than
/// throwing when geolocator's platform channel isn't available (as in
/// this test environment, or on a real device if geolocator itself ever
/// fails) — the actual gap this file used to have, since _start() didn't
/// wrap its Geolocator calls in a try/catch until now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('disabled and at the default threshold until configured', () {
    final plugin = DrivingModePlugin();
    expect(plugin.enabled, isFalse);
    expect(plugin.speedThresholdKmh, 20.0);
    expect(plugin.remindToConnectBluetooth, isTrue);
    expect(plugin.isDrivingDetected, isFalse);
  });

  test(
      'setEnabled(true) never throws even though the real platform is '
      'unavailable, and persists across a fresh instance', () async {
    final plugin = DrivingModePlugin();

    await expectLater(plugin.setEnabled(true), completes);
    expect(plugin.enabled, isTrue);
    // Degrades to a visible error instead of the geolocator platform
    // exception propagating uncaught into the settings page's onChanged.
    expect(plugin.lastError, isNotNull);

    final fresh = DrivingModePlugin();
    await fresh.storage.initialize();
    expect(fresh.enabled, isTrue);
  });

  test('setEnabled(false) after being enabled stops cleanly', () async {
    final plugin = DrivingModePlugin();
    await plugin.setEnabled(true);

    await expectLater(plugin.setEnabled(false), completes);
    expect(plugin.enabled, isFalse);
    expect(plugin.isDrivingDetected, isFalse);
  });

  test('disable() is safe to call even when never enabled', () async {
    final plugin = DrivingModePlugin();
    await expectLater(plugin.disable(), completes);
  });

  test('speedThresholdKmh persists across a fresh instance', () async {
    final plugin = DrivingModePlugin();
    await plugin.setSpeedThresholdKmh(45.0);

    final fresh = DrivingModePlugin();
    await fresh.storage.initialize();
    expect(fresh.speedThresholdKmh, 45.0);
  });

  test('remindToConnectBluetooth persists across a fresh instance',
      () async {
    final plugin = DrivingModePlugin();
    await plugin.setRemindToConnectBluetooth(false);

    final fresh = DrivingModePlugin();
    await fresh.storage.initialize();
    expect(fresh.remindToConnectBluetooth, isFalse);
  });
}
