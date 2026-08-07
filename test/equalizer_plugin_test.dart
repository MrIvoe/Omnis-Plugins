import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugins/equalizer_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}
