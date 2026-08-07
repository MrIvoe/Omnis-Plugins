import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Detects driving via GPS speed and automatically switches to the Car
/// Mode Now Playing layout — the oversized-controls, minimal-distraction
/// arrangement `lib/ui/player_layouts/` already ships — and switches back
/// once speed drops again.
///
/// ### What this plugin does NOT do, and why
///
/// The request that inspired this ("turn Bluetooth on and connect to
/// 'x' device" while driving) runs into a real Android platform wall,
/// not a missing feature this plugin chose to skip:
///  - **Silently enabling Bluetooth**: `BluetoothAdapter.enable()` has
///    been a no-op for third-party apps since Android 13 — the OS
///    requires the *user* to grant it via a system dialog every time,
///    there is no "just turn it on" API left for an app to call.
///  - **Auto-connecting to a specific paired device**: initiating an
///    A2DP (audio) connection to an already-paired device from a normal
///    third-party app isn't exposed by the public Android SDK at all —
///    that control is reserved for the system Bluetooth settings UI and
///    OEM-privileged apps. `CompanionDeviceManager` gets close for a
///    narrow set of device-association scenarios, but implementing and
///    verifying that is a much larger, device-specific undertaking than
///    this pass can respons­ibly deliver.
///
/// So this plugin does the part that's actually achievable and useful —
/// automatic Car Mode switching — and, when enabled, reminds the user to
/// connect Bluetooth themselves rather than pretending to do it silently.
///
/// The active-layout read/write and the location permission request go
/// through `PluginContext` (`playerLayoutId`/`requestLocationPermission`)
/// rather than this app's own `AppSettings`/`OmnisPermissions` — this
/// plugin lives in a separate package with no dependency on the Omnis
/// app itself, so context is the only way to reach them. Without an
/// attached context there is nothing useful this plugin can do (it
/// exists entirely to switch the active layout), so every context-backed
/// operation below degrades to a no-op when unattached rather than
/// throwing.
///
/// **Verification status**: implemented against `geolocator`'s
/// documented API; speed-based driving detection has not been exercised
/// against a real device/real movement in this environment. Foreground
/// location only — this does not run as a background service, so
/// detection only happens while Omnis is open.
class DrivingModePlugin extends MusicPlugin {
  static const _enabledKey = 'enabled';
  static const _speedThresholdKmhKey = 'speed_threshold_kmh';
  static const _remindBluetoothKey = 'remind_bluetooth';
  static const _defaultThresholdKmh = 20.0; // ~12 mph

  StreamSubscription<Position>? _positionSub;
  String? _previousLayoutId;
  bool _inDrivingMode = false;
  String? lastError;

  bool get enabled => storage.getBool(_enabledKey) ?? false;

  Future<void> setEnabled(bool value) async {
    await storage.setBool(_enabledKey, value);
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  double get speedThresholdKmh =>
      storage.getDouble(_speedThresholdKmhKey) ?? _defaultThresholdKmh;

  Future<void> setSpeedThresholdKmh(double value) =>
      storage.setDouble(_speedThresholdKmhKey, value);

  bool get remindToConnectBluetooth => storage.getBool(_remindBluetoothKey) ?? true;

  Future<void> setRemindToConnectBluetooth(bool value) =>
      storage.setBool(_remindBluetoothKey, value);

  /// Whether driving is currently detected (Car Mode was auto-switched
  /// in as a result). For the settings page's status display.
  bool get isDrivingDetected => _inDrivingMode;

  Future<void> _start() async {
    final hasPermission = await _ensurePermission();
    if (!hasPermission) {
      lastError = 'Location permission denied — driving detection can\'t run.';
      return;
    }
    lastError = null;
    await _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        // Only re-check every ~50m — GPS speed readings are noisy at
        // small intervals and this is a "driving vs. not," not a
        // turn-by-turn feature.
        distanceFilter: 50,
      ),
    ).listen(_onPosition, onError: (Object e) {
      lastError = 'Location stream error: $e';
    });
  }

  Future<void> _stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    if (_inDrivingMode) {
      _exitDrivingMode();
    }
  }

  Future<bool> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      final granted = await context?.requestLocationPermission() ?? false;
      if (!granted) return false;
      permission = await Geolocator.checkPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  void _onPosition(Position position) {
    // Position.speed is in m/s per geolocator's contract; converted here
    // once so the rest of this plugin (and its settings UI) works in the
    // more familiar km/h.
    final speedKmh = position.speed * 3.6;
    final driving = speedKmh >= speedThresholdKmh;
    if (driving && !_inDrivingMode) {
      _enterDrivingMode();
    } else if (!driving && _inDrivingMode) {
      _exitDrivingMode();
    }
  }

  void _enterDrivingMode() {
    final ctx = context;
    if (ctx == null) return;
    _inDrivingMode = true;
    if (ctx.playerLayoutId != 'car_mode') {
      _previousLayoutId = ctx.playerLayoutId;
      // ignore: unawaited_futures
      ctx.setPlayerLayoutId('car_mode');
    }
  }

  void _exitDrivingMode() {
    final ctx = context;
    _inDrivingMode = false;
    final previous = _previousLayoutId;
    _previousLayoutId = null;
    if (ctx != null && previous != null && ctx.playerLayoutId == 'car_mode') {
      // ignore: unawaited_futures
      ctx.setPlayerLayoutId(previous);
    }
  }

  @override
  String get id => 'driving_mode';

  @override
  String get name => 'Driving Mode';

  @override
  String get description => enabled
      ? (_inDrivingMode
          ? 'Driving detected — Car Mode is active.'
          : 'Watching for driving speed via GPS.')
      : 'Automatically switches to Car Mode when driving speed is detected.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    if (enabled) await _start();
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  Future<void> disable() async => _stop();

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _DrivingModeSettings(plugin: this) : null;

  @override
  Future<void> dispose() async => _stop();
}

class _DrivingModeSettings extends StatefulWidget {
  final DrivingModePlugin plugin;

  const _DrivingModeSettings({required this.plugin});

  @override
  State<_DrivingModeSettings> createState() => _DrivingModeSettingsState();
}

class _DrivingModeSettingsState extends State<_DrivingModeSettings> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    final threshold = plugin.speedThresholdKmh;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Uses GPS speed (only while Omnis is open in the foreground — '
          'this does not run as a background service) to switch to Car '
          'Mode automatically. Cannot enable Bluetooth or connect to a '
          'device automatically — Android does not allow a normal app to '
          'do either silently; see this plugin\'s own doc comment for why.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable driving detection'),
          subtitle: Text(plugin.enabled
              ? (plugin.isDrivingDetected
                  ? 'Driving detected — Car Mode is active'
                  : 'Watching for driving speed')
              : 'Off'),
          value: plugin.enabled,
          onChanged: (value) async {
            await plugin.setEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Speed threshold'),
          subtitle: Slider(
            value: threshold,
            min: 5,
            max: 60,
            divisions: 55,
            label: '${threshold.round()} km/h',
            onChanged: (value) async {
              await plugin.setSpeedThresholdKmh(value);
              if (mounted) setState(() {});
            },
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Remind me to connect Bluetooth'),
          subtitle: const Text(
              'Shows a reminder when driving starts — Omnis can\'t connect '
              'a Bluetooth device for you'),
          value: plugin.remindToConnectBluetooth,
          onChanged: (value) async {
            await plugin.setRemindToConnectBluetooth(value);
            if (mounted) setState(() {});
          },
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}
