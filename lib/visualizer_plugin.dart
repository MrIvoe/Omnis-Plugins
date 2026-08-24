import 'dart:async';
import 'dart:io';

import 'package:audify/audify.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Real spectrum visualizer, backed by the `audify` package's native
/// Android `Visualizer`/iOS `AVAudioEngine` capture.
///
/// `just_audio` exposes no PCM/FFT tap of its own — this plugin used to
/// be a pass-through container fed a single hardcoded demo array once
/// per button tap, never tied to actual playback (see git history).
/// `audify` targets the system output mix (`audioSessionId: 0`) rather
/// than `AudioEngine`'s specific playback session: precise per-session
/// targeting would mean adding a new capability to the shared, versioned
/// `PluginContext` contract (a cross-repo change) for a benefit that's
/// moot in practice for a dedicated music player — whatever else is
/// making sound on the device is the rare case, not the common one.
///
/// The Android `Visualizer` API — and `audify`'s iOS `AVAudioEngine` tap
/// — both require the `RECORD_AUDIO`/microphone permission even though
/// neither actually records anything; that's an OS-level requirement,
/// not a choice this plugin makes. [activate] requests it lazily, only
/// when the visualizer is actually opened, never at app startup.
///
/// Implements [IVisualizerProvider] and registers itself under that
/// interface — [VisualizerBars] reads through the interface, so a future
/// alternative spectrum source could replace this plugin without the
/// widget changing.
class VisualizerPlugin extends MusicPlugin implements IVisualizerProvider {
  final StreamController<List<double>> _levelsController =
      StreamController.broadcast();

  /// Matches `FrequencyData.bands`' length (sub-bass through brilliance).
  static const barCount = 7;

  List<double> _latest = List.filled(barCount, 0.0);

  AudifyController? _audify;
  StreamSubscription<FrequencyData>? _audifySub;
  bool _capturing = false;
  String? _lastError;

  /// Overrides platform detection in tests, where `Platform.isAndroid`/
  /// `isIOS` can't be made to return a chosen value. `null` (the default)
  /// means "use the real platform." Same pattern `RingtonePlugin` uses
  /// for the same reason.
  @visibleForTesting
  final bool? platformSupportOverride;

  /// Overrides the detected Android SDK level in tests. `null` (the
  /// default) means "ask `device_info_plus` for the real value."
  @visibleForTesting
  final int? androidSdkIntOverride;

  VisualizerPlugin({this.platformSupportOverride, this.androidSdkIntOverride});

  /// The most recently emitted levels, so a widget that subscribes late
  /// still renders something rather than flat bars.
  @override
  List<double> get latest => List.unmodifiable(_latest);

  @override
  Stream<List<double>> get levels => _levelsController.stream;

  void emitLevels(List<double> levels) {
    if (_levelsController.isClosed) return;
    _latest = List<double>.from(levels);
    _levelsController.add(_latest);
  }

  /// Whether `audify`'s native capture is available on this platform —
  /// Android/iOS only, no Windows/Linux/web/macOS support.
  bool get isSupportedOnThisPlatform =>
      platformSupportOverride ??
      (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  bool get isCapturing => _capturing;

  /// Why the last [activate] call didn't result in real capture, or
  /// `null`. Cleared on a successful [activate].
  String? get lastError => _lastError;

  /// Starts real spectrum capture. Degrades to setting [lastError]
  /// instead of throwing on an unsupported platform, a denied
  /// permission, or any capture failure — [latest]/[levels] simply stay
  /// at their flat starting value in every one of those cases, which is
  /// an honest "nothing real is happening" rather than the old
  /// misleading fake animation.
  Future<void> activate() async {
    if (_capturing) return;
    if (!isSupportedOnThisPlatform) {
      _lastError = 'Real spectrum visualization needs Android or iOS.';
      return;
    }
    // audify requires Android API 24+ natively; the app itself still
    // targets minSdkVersion 21 (android/app/src/main/AndroidManifest.xml
    // force-merges audify's higher requirement via tools:overrideLibrary
    // so the app still *installs* everywhere) — so this plugin has to
    // check the real device's SDK level itself rather than assume.
    if (Platform.isAndroid || androidSdkIntOverride != null) {
      final sdkInt = await _androidSdkInt();
      if (sdkInt != null && sdkInt < 24) {
        _lastError = 'The visualizer needs Android 7.0 (API 24) or newer '
            '— this device is on API $sdkInt.';
        return;
      }
    }
    try {
      final granted = await context?.requestMicrophonePermission() ?? false;
      if (!granted) {
        _lastError =
            'Microphone permission is required for the visualizer.';
        return;
      }
      final controller = AudifyController();
      await controller.initialize();
      await controller.startCapture();
      _audify = controller;
      _audifySub = controller.frequencyDataStream.listen((data) {
        emitLevels(data.bands);
      });
      _capturing = true;
      _lastError = null;
    } catch (e) {
      _lastError = 'Could not start the visualizer: $e';
      await _teardownAudify();
    }
  }

  /// The real Android SDK level, or `null` if it couldn't be determined
  /// (in which case [activate] falls through and lets the actual audify
  /// call succeed or fail on its own — a `device_info_plus` failure
  /// shouldn't itself block activation on a device that might be fine).
  Future<int?> _androidSdkInt() async {
    if (androidSdkIntOverride != null) return androidSdkIntOverride;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt;
    } catch (_) {
      return null;
    }
  }

  Future<void> deactivate() => _teardownAudify();

  Future<void> _teardownAudify() async {
    await _audifySub?.cancel();
    _audifySub = null;
    final controller = _audify;
    _audify = null;
    _capturing = false;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {
        // Best-effort teardown — a failure here shouldn't surface as a
        // user-facing error for what's already an inactive visualizer.
      }
    }
  }

  @override
  String get id => 'visualizer';

  @override
  String get name => 'Visualizer';

  @override
  String get description =>
      'Real-time spectrum visualization for the current track (Android/iOS).';

  @override
  String get version => '2.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IVisualizerProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> enable() async {
    context?.services.register(IVisualizerProvider, this);
  }

  @override
  Future<void> disable() async {
    await _teardownAudify();
    context?.services.unregister(IVisualizerProvider, this);
  }

  @override
  Future<void> dispose() async {
    await _teardownAudify();
    context?.services.unregister(IVisualizerProvider, this);
    await _levelsController.close();
  }
}

/// Animated bar display driven by an [IVisualizerProvider].
class VisualizerBars extends StatefulWidget {
  final IVisualizerProvider plugin;

  const VisualizerBars({super.key, required this.plugin});

  @override
  State<VisualizerBars> createState() => _VisualizerBarsState();
}

class _VisualizerBarsState extends State<VisualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final StreamSubscription<List<double>> _sub;
  late List<double> _levels;

  @override
  void initState() {
    super.initState();
    _levels = widget.plugin.latest;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _sub = widget.plugin.levels.listen((levels) {
      if (mounted) setState(() => _levels = levels);
    });
  }

  @override
  void dispose() {
    // Cancel the subscription before disposing the controller so a level
    // event in flight can't call setState on a half-disposed State.
    _sub.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_levels.length, (index) {
            final base = _levels[index].clamp(0.0, 1.0);
            final height = 18.0 +
                base * 70.0 +
                (progress * 10.0 * ((index % 2) == 0 ? 1 : -1));
            return Container(
              width: 8,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }
}
