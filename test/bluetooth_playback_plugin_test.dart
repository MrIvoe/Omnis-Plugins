import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugins/bluetooth_playback_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Bluetooth-detection half genuinely can't be unit tested — it needs
/// a real device connecting/disconnecting (see this plugin's own
/// "Verification status" doc comment). What's tested here is the
/// storage/toggle half: persistence, defaults, and that setEnabled/
/// disable degrade gracefully (via this plugin's existing try/catch
/// around AudioSession.instance) rather than throwing when the real
/// platform is unavailable, as in this test environment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('disabled with nothing connected until configured', () {
    final plugin = BluetoothPlaybackPlugin();
    expect(plugin.enabled, isFalse);
    expect(plugin.connectedDeviceName, isNull);
    expect(plugin.lastError, isNull);
  });

  test(
      'setEnabled(true) never throws even though the real platform is '
      'unavailable, and persists across a fresh instance', () async {
    final plugin = BluetoothPlaybackPlugin();

    await expectLater(plugin.setEnabled(true), completes);
    expect(plugin.enabled, isTrue);

    final fresh = BluetoothPlaybackPlugin();
    await fresh.storage.initialize();
    expect(fresh.enabled, isTrue);
  });

  test('setEnabled(false) after being enabled stops cleanly and clears the '
      'connected device', () async {
    final plugin = BluetoothPlaybackPlugin();
    await plugin.setEnabled(true);

    await expectLater(plugin.setEnabled(false), completes);
    expect(plugin.enabled, isFalse);
    expect(plugin.connectedDeviceName, isNull);
  });

  test('disable() is safe to call even when never enabled', () async {
    final plugin = BluetoothPlaybackPlugin();
    await expectLater(plugin.disable(), completes);
  });

  test('dispose() is safe to call even when never enabled', () async {
    final plugin = BluetoothPlaybackPlugin();
    await expectLater(plugin.dispose(), completes);
  });

  test('deviceChanges is a broadcast stream that can be listened to more '
      'than once', () async {
    final plugin = BluetoothPlaybackPlugin();
    final sub1 = plugin.deviceChanges.listen((_) {});
    final sub2 = plugin.deviceChanges.listen((_) {});
    await sub1.cancel();
    await sub2.cancel();
  });

  test('availableMoods is empty without any registered IQueueBuilder',
      () {
    final plugin = BluetoothPlaybackPlugin();
    expect(plugin.availableMoods, isEmpty);
  });

  test('availablePlaylists is empty without an attached context', () async {
    final plugin = BluetoothPlaybackPlugin();
    expect(await plugin.availablePlaylists(), isEmpty);
  });
}
