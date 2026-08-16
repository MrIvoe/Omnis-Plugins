import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Remembers a separate master-volume level per output device — item
/// 21's "no per-device volume profile" gap, the same idea
/// `EqualizerPlugin` already implements for EQ bands, extended to plain
/// volume: headphones can play quieter than a car Bluetooth speaker,
/// and switching between them restores each one's own remembered level
/// instead of carrying over whatever the other was left at.
///
/// Unlike `EqualizerPlugin`'s bands, there is no safe "flat" default
/// for volume — resetting to some fixed level on every unconfigured
/// device would risk an unpleasant blast at full volume. So a device
/// with no saved profile yet is left alone entirely: only devices the
/// user has explicitly set a volume for while connected to them ever
/// get auto-applied on reconnect.
///
/// Persistence follows `EqualizerPlugin`'s own per-device storage shape
/// (this plugin's own [MusicPlugin.storage], JSON-encoded, keyed by
/// device name) and the same `IDeviceConnectivityProvider` subscription
/// (`BluetoothPlaybackPlugin` today).
class DeviceVolumePlugin extends MusicPlugin {
  static const _storageKey = 'device_volumes';

  Map<String, double> _profiles = {};

  /// The currently connected output device's name, from
  /// [IDeviceConnectivityProvider] — `null` when nothing is connected or
  /// no provider is registered.
  String? _currentDevice;
  StreamSubscription<String?>? _deviceSub;

  String get _defaultKey => '_default';

  String _keyFor(String? device) => device ?? _defaultKey;

  /// The name of the currently connected device, or `null` for "this
  /// device" (nothing reported by [IDeviceConnectivityProvider]).
  String? get currentDevice => _currentDevice;

  /// The saved volume for the currently connected device (or the shared
  /// default slot, when nothing is connected) — `null` when nothing has
  /// been saved for it yet.
  double? get savedVolumeForCurrentDevice => _profiles[_keyFor(_currentDevice)];

  /// Whether the currently connected device has a saved profile.
  bool get hasSavedProfileForCurrentDevice =>
      savedVolumeForCurrentDevice != null;

  Map<String, double> _readProfiles() {
    final raw = storage.getString(_storageKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map(
        (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistProfiles() =>
      storage.setString(_storageKey, jsonEncode(_profiles));

  /// Sets the master volume to [volume] (applied immediately) and saves
  /// it as the profile for whichever device is currently connected (or
  /// the shared default slot, with nothing connected).
  Future<void> setVolumeForCurrentDevice(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    _profiles[_keyFor(_currentDevice)] = clamped;
    await context?.setVolume(clamped);
    await _persistProfiles();
  }

  /// Removes the saved profile for the currently connected device, so a
  /// future reconnect leaves the volume alone instead of restoring it.
  Future<void> forgetCurrentDeviceProfile() async {
    _profiles.remove(_keyFor(_currentDevice));
    await _persistProfiles();
  }

  @override
  String get id => 'device_volume';

  @override
  String get name => 'Per-Device Volume';

  @override
  String get description =>
      'Remembers a separate volume level for each output device.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  // Must initialize after BluetoothPlaybackPlugin, whose initialize()
  // registers IDeviceConnectivityProvider — the same documented
  // ordering dependency EqualizerPlugin already has, for the same
  // reason (see bundled_plugins.dart).
  @override
  bool get requiresSequentialInit => true;

  @override
  Future<void> initialize() async {
    _profiles = _readProfiles();
    final provider = context?.services.get<IDeviceConnectivityProvider>();
    _currentDevice = provider?.connectedDeviceName;
    _deviceSub?.cancel();
    _deviceSub = provider?.deviceChanges.listen(_onDeviceChanged);

    final saved = savedVolumeForCurrentDevice;
    if (saved != null) await context?.setVolume(saved);
  }

  /// A device change applies its saved profile, if one exists — plugging
  /// in a device with no remembered volume leaves playback exactly as
  /// it was, deliberately never resetting to a fixed default the way
  /// EqualizerPlugin's bands safely can.
  Future<void> _onDeviceChanged(String? device) async {
    _currentDevice = device;
    final saved = savedVolumeForCurrentDevice;
    if (saved != null) await context?.setVolume(saved);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _DeviceVolumeSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    await _deviceSub?.cancel();
    _deviceSub = null;
  }
}

/// This plugin's own settings page — a single slider bound to the
/// currently connected device's saved volume (or the shared default
/// slot), plus a "Forget" action. Reached by tapping the plugin in the
/// Plugins list, the same `plugin_settings` slot `EqualizerPlugin` uses.
class _DeviceVolumeSettings extends StatefulWidget {
  final DeviceVolumePlugin plugin;

  const _DeviceVolumeSettings({required this.plugin});

  @override
  State<_DeviceVolumeSettings> createState() => _DeviceVolumeSettingsState();
}

class _DeviceVolumeSettingsState extends State<_DeviceVolumeSettings> {
  late double _sliderValue = widget.plugin.savedVolumeForCurrentDevice ??
      widget.plugin.context?.volume ??
      1.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    final deviceLabel = plugin.currentDevice ?? 'This device';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Per-Device Volume', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Remembers a separate volume level for each output device, '
          'and restores it automatically when that device reconnects.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Text('Volume for: $deviceLabel', style: theme.textTheme.titleSmall),
        Slider(
          value: _sliderValue.clamp(0.0, 1.0),
          onChanged: (v) => setState(() => _sliderValue = v),
          onChangeEnd: (v) => plugin.setVolumeForCurrentDevice(v),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${(_sliderValue * 100).round()}%',
                style: theme.textTheme.bodySmall),
            TextButton(
              onPressed: plugin.hasSavedProfileForCurrentDevice
                  ? () async {
                      await plugin.forgetCurrentDeviceProfile();
                      setState(() {
                        _sliderValue = plugin.context?.volume ?? 1.0;
                      });
                    }
                  : null,
              child: const Text('Forget saved volume'),
            ),
          ],
        ),
      ],
    );
  }
}
