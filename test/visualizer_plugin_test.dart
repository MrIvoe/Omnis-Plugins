import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugins/visualizer_plugin.dart';

/// `activate()`'s real hardware/permission path can't be exercised in
/// `flutter test` (no platform channel for `permission_handler` or
/// `audify` here) — these tests instead pin down the contract that
/// matters most given this plugin used to be a hardcoded-array demo:
/// every failure mode (unsupported platform, permission denial, a
/// native-call failure) degrades to `lastError` rather than throwing or
/// silently continuing to look "active." Same `platformSupportOverride`
/// pattern `RingtonePlugin`'s tests use, for the same reason
/// (`Platform.isAndroid`/`isIOS` are always false on this test host).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform gating (real check — this test host is never Android/iOS)',
      () {
    test('isSupportedOnThisPlatform is false on this test host', () {
      final plugin = VisualizerPlugin();
      expect(plugin.isSupportedOnThisPlatform, isFalse);
    });

    test('activate() reports the platform gate and never touches audify',
        () async {
      final plugin = VisualizerPlugin();

      await plugin.activate();

      expect(plugin.isCapturing, isFalse);
      expect(plugin.lastError,
          'Real spectrum visualization needs Android or iOS.');
    });

    test('a second activate() call while not capturing is still a no-op '
        'past the platform gate, not a crash', () async {
      final plugin = VisualizerPlugin();

      await plugin.activate();
      await plugin.activate();

      expect(plugin.isCapturing, isFalse);
    });
  });

  group(
      'logic reachable via platformSupportOverride (forces past the '
      'platform gate — the real permission_handler/audify calls still '
      'fail in this environment, no platform channel registered, but '
      'must degrade through lastError rather than throw)', () {
    test('activate() degrades gracefully instead of throwing when forced '
        'past the platform gate', () async {
      final plugin = VisualizerPlugin(platformSupportOverride: true);

      await expectLater(plugin.activate(), completes);

      expect(plugin.isCapturing, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('deactivate() with nothing ever activated is a harmless no-op',
        () async {
      final plugin = VisualizerPlugin(platformSupportOverride: true);
      await expectLater(plugin.deactivate(), completes);
      expect(plugin.isCapturing, isFalse);
    });
  });

  test('dispose() is safe even when the visualizer was never activated',
      () async {
    final plugin = VisualizerPlugin();
    await expectLater(plugin.dispose(), completes);
  });

  group('Android SDK-level gating (audify needs API 24+, but the app '
      'keeps minSdkVersion 21 — reachable via androidSdkIntOverride, '
      'which also forces the check to run on this non-Android test host)',
      () {
    test('a device below API 24 is rejected with a specific message '
        'before any permission/audify call', () async {
      final plugin = VisualizerPlugin(
        platformSupportOverride: true,
        androidSdkIntOverride: 23,
      );

      await plugin.activate();

      expect(plugin.isCapturing, isFalse);
      expect(plugin.lastError,
          'The visualizer needs Android 7.0 (API 24) or newer — this '
          'device is on API 23.');
    });

    test('a device on exactly API 24 passes the gate (falls through to '
        'the real audify call, which then degrades in this test '
        'environment same as the other platformSupportOverride cases)',
        () async {
      final plugin = VisualizerPlugin(
        platformSupportOverride: true,
        androidSdkIntOverride: 24,
      );

      await plugin.activate();

      expect(plugin.isCapturing, isFalse);
      // Different message than the SDK-gate one — proves it got past
      // that check and failed later, in the actual audify call.
      expect(plugin.lastError, isNot(contains('Android 7.0')));
    });
  });
}
