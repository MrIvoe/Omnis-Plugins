import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/hardware_eq_band.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// A bundled equalizer plugin with two implementations behind one API:
///
///  - **Hardware mode** (Android only): drives the OS's real per-band
///    equalizer (`android.media.audiofx.Equalizer`) through
///    `PluginContext.hardwareEqBands` — genuine frequency-band shaping,
///    reported and controlled by the device itself.
///  - **Virtual mode** (everywhere else): `just_audio` has no per-band
///    audio processing hook in pure Dart, and no other platform this app
///    targets exposes a built-in one through just_audio either — a real
///    N-band EQ on iOS/macOS/Windows/Linux needs a native platform channel
///    this project doesn't have yet (an `AVAudioUnitEQ` bridge, a WASAPI
///    APO). The fallback is an honest overall loudness trim derived from
///    three virtual bands, applied as an `AudioEngine` gain contribution
///    via [MusicPlugin.context] — moving the sliders has *some* audible
///    effect instead of doing nothing.
///
/// Both models persist their gains via this plugin's own
/// [MusicPlugin.storage] (plugin-private state, not a shared app-settings
/// singleton) so they survive a restart — previously every band reset to
/// flat on every launch.
///
/// Persistence is per-device when a device is known: this plugin listens
/// to `IDeviceConnectivityProvider` (`BluetoothPlaybackPlugin` today) and
/// keys its saved bands by the connected device's name, so headphones and
/// a car stereo can each remember their own EQ instead of sharing one
/// profile. With no device connected (or no provider registered — the
/// common case on a build without Bluetooth support), bands fall back to
/// one shared default profile, matching this plugin's original behavior.
///
/// NOTE: the hardware path has not been exercised against a real Android
/// device while building this — `PluginContext.ensureHardwareEqLoaded`
/// fails closed (falls back to virtual mode) on any platform-channel
/// error, so a wrong assumption there degrades gracefully rather than
/// crashing, but it is unverified.
class EqualizerPlugin extends MusicPlugin {
  /// Key this plugin's virtual-mode gain contribution is registered under.
  static const gainSource = 'equalizer';

  /// The band keys the virtual model exposes, in display order.
  static const virtualBandKeys = ['bass', 'mid', 'treble'];

  static const _virtualBandsStorageKey = 'virtual_bands';
  static const _hardwareBandsStorageKey = 'hardware_bands';

  final Map<String, double> _virtualBands = {
    for (final key in virtualBandKeys) key: 0.0,
  };

  bool _hardwareRestored = false;

  /// The currently connected output device's name, from
  /// [IDeviceConnectivityProvider] — `null` when nothing is connected or
  /// no provider is registered. Bands are persisted per-device (see
  /// [_virtualKeyFor]/[_hardwareKeyFor]) so plugging in headphones vs. a
  /// car stereo can each remember their own EQ, falling back to one
  /// shared default profile when nothing is connected.
  String? _currentDevice;
  StreamSubscription<String?>? _deviceSub;

  String _virtualKeyFor(String? device) => device == null
      ? _virtualBandsStorageKey
      : '${_virtualBandsStorageKey}_device_$device';

  String _hardwareKeyFor(String? device) => device == null
      ? _hardwareBandsStorageKey
      : '${_hardwareBandsStorageKey}_device_$device';

  /// Real hardware bands, if this platform provides them.
  List<HardwareEqBand> get hardwareBands =>
      context?.hardwareEqBands ?? const [];

  /// Whether real per-band hardware control is currently available.
  bool get hasHardwareBands => hardwareBands.isNotEmpty;

  double getBand(String key) => _virtualBands[key] ?? 0.0;

  Map<String, double> _readBandMap(String key) {
    final raw = storage.getString(key);
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

  Future<void> _persistBandMap(String key, Map<String, double> bands) =>
      storage.setString(key, jsonEncode(bands));

  /// Live-update a virtual band. Cheap — safe to call on every slider
  /// drag frame. Call [persistVirtualBands] once dragging ends.
  void setBand(String key, double value) {
    if (!_virtualBands.containsKey(key)) return;
    _virtualBands[key] = value.clamp(-12.0, 12.0);
    // ignore: unawaited_futures
    context?.setGain(gainSource, combinedMultiplier);
  }

  /// Reset every virtual band to flat and persist immediately.
  void reset() {
    for (final key in _virtualBands.keys) {
      _virtualBands[key] = 0.0;
    }
    // ignore: unawaited_futures
    context?.setGain(gainSource, combinedMultiplier);
    // ignore: unawaited_futures
    persistVirtualBands();
  }

  /// Save the current virtual band values so they survive a restart —
  /// under the currently-connected device's own key, if any (see
  /// [_virtualKeyFor]).
  Future<void> persistVirtualBands() =>
      _persistBandMap(_virtualKeyFor(_currentDevice), _virtualBands);

  /// Live-update a real hardware band by its device-reported index. Cheap
  /// enough for drag frames — it's a single platform-channel call, not a
  /// disk write. Call [persistHardwareBands] once dragging ends.
  Future<void> setHardwareBand(int index, double decibels) async {
    HardwareEqBand? band;
    for (final b in hardwareBands) {
      if (b.index == index) {
        band = b;
        break;
      }
    }
    if (band == null) return;
    await band.setGain(decibels);
  }

  /// Reset every real hardware band to flat and persist immediately.
  Future<void> resetHardwareBands() async {
    for (final band in hardwareBands) {
      await band.setGain(0.0);
    }
    await persistHardwareBands();
  }

  /// Save the current hardware band values so they survive a restart —
  /// under the currently-connected device's own key, if any (see
  /// [_hardwareKeyFor]).
  Future<void> persistHardwareBands() => _persistBandMap(
        _hardwareKeyFor(_currentDevice),
        {for (final band in hardwareBands) '${band.index}': band.gain},
      );

  /// Overall loudness trim derived from the three virtual bands, for use
  /// as an `AudioEngine` gain contribution. When real hardware bands are
  /// active, the OS is already shaping the signal, so this contributes
  /// nothing (1.0) rather than double-applying a trim on top of real EQ.
  /// Unlike [applyGain] (a pure function kept for its unit test), this is
  /// not clamped down to 1.0, so a positive boost is actually audible
  /// instead of being clipped away.
  double get combinedMultiplier {
    if (hasHardwareBands) return 1.0;
    final bassBoost = getBand('bass') / 24.0;
    final midBoost = getBand('mid') / 24.0;
    final trebleBoost = getBand('treble') / 24.0;
    final raw = 1.0 + bassBoost * 0.6 + midBoost * 0.4 + trebleBoost * 0.3;
    return raw.clamp(0.4, 1.6);
  }

  @override
  String get id => 'equalizer';

  @override
  String get name => 'Equalizer';

  @override
  String get description => hasHardwareBands
      ? 'Real per-band hardware equalizer.'
      : 'Preset-based audio shaping (no native EQ on this platform).';

  @override
  String get version => '2.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    final provider =
        context?.services.get<IDeviceConnectivityProvider>();
    _currentDevice = provider?.connectedDeviceName;
    _deviceSub?.cancel();
    _deviceSub = provider?.deviceChanges.listen(_onDeviceChanged);

    _loadVirtualBandsFor(_currentDevice);
    await context?.ensureHardwareEqLoaded();
    await _restoreHardwareIfNeeded();
    if (!hasHardwareBands) {
      await context?.setGain(gainSource, combinedMultiplier);
    }
  }

  /// Loads (or resets to flat, if this device has no saved profile yet)
  /// the virtual bands for [device] into [_virtualBands] — does not
  /// itself apply the resulting gain; callers that need the audible
  /// effect to update immediately (see [_onDeviceChanged]) do that
  /// afterward.
  void _loadVirtualBandsFor(String? device) {
    final saved = _readBandMap(_virtualKeyFor(device));
    for (final key in virtualBandKeys) {
      _virtualBands[key] = (saved[key] ?? 0.0).clamp(-12.0, 12.0);
    }
  }

  /// Re-loads whichever profile matches the now-connected device (or the
  /// shared default profile, when [device] is `null`) and applies it
  /// immediately — plugging in a different pair of headphones should
  /// audibly switch EQ right away, the same "just connected, things
  /// happen" spirit `BluetoothPlaybackPlugin`'s quick-play already has.
  Future<void> _onDeviceChanged(String? device) async {
    _currentDevice = device;
    _loadVirtualBandsFor(device);
    if (!hasHardwareBands) {
      await context?.setGain(gainSource, combinedMultiplier);
      return;
    }
    // A device change can also mean the hardware bands themselves
    // changed identity (different device, different EQ hardware) — force
    // a fresh restore against the new device's saved profile rather than
    // trusting whatever _hardwareRestored's prior state was.
    _hardwareRestored = false;
    await _restoreHardwareIfNeeded();
  }

  Future<void> _restoreHardwareIfNeeded() async {
    if (_hardwareRestored || !hasHardwareBands) return;
    _hardwareRestored = true;
    final saved = _readBandMap(_hardwareKeyFor(_currentDevice));
    if (saved.isEmpty) {
      // No saved profile for this device — start flat rather than
      // carrying over whatever the previous device's bands happened to
      // be left at.
      for (final band in hardwareBands) {
        await band.setGain(0.0);
      }
      return;
    }
    for (final band in hardwareBands) {
      final value = saved['${band.index}'];
      if (value != null) await band.setGain(value);
    }
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _EqualizerSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    await context?.ensureHardwareEqLoaded();
    await _restoreHardwareIfNeeded();
    if (!hasHardwareBands) {
      await context?.setGain(gainSource, combinedMultiplier);
    }
  }

  @override
  Future<void> disable() async {
    // Leave no trace on playback while switched off — the bands are kept so
    // re-enabling restores the user's settings.
    await context?.clearGain(gainSource);
  }

  @override
  Future<void> dispose() async {
    await _deviceSub?.cancel();
    _deviceSub = null;
    await context?.clearGain(gainSource);
  }

  /// Pure gain shaping helper, clamped to a 0..1 sample range. Uses only
  /// the virtual bands; kept for its existing unit test.
  double applyGain(double input) {
    final bassBoost = getBand('bass') / 24.0;
    final midBoost = getBand('mid') / 24.0;
    final trebleBoost = getBand('treble') / 24.0;
    return (input *
            (1.0 + bassBoost * 0.6 + midBoost * 0.4 + trebleBoost * 0.3))
        .clamp(0.0, 1.0);
  }
}

/// Modal bottom sheet with real per-band sliders bound to an
/// [EqualizerPlugin] — either the device's actual hardware bands or the
/// virtual bass/mid/treble model, whichever [EqualizerPlugin.hasHardwareBands]
/// says is active. Replaces what used to be two buttons that only applied
/// a single canned preset.
class EqualizerSheet extends StatefulWidget {
  final EqualizerPlugin plugin;

  const EqualizerSheet({super.key, required this.plugin});

  /// Show the equalizer as a modal bottom sheet.
  static Future<void> show(BuildContext context, EqualizerPlugin plugin) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => EqualizerSheet(plugin: plugin),
    );
  }

  @override
  State<EqualizerSheet> createState() => _EqualizerSheetState();
}

class _EqualizerSheetState extends State<EqualizerSheet> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: _EqualizerBandsEditor(plugin: widget.plugin, showTitle: true),
      ),
    );
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. The exact same band editor [EqualizerSheet] shows as a modal
/// from Now Playing, just inline on the settings page instead — so
/// there's one real implementation of "edit the bands," not two.
class _EqualizerSettings extends StatelessWidget {
  final EqualizerPlugin plugin;

  const _EqualizerSettings({required this.plugin});

  @override
  Widget build(BuildContext context) =>
      _EqualizerBandsEditor(plugin: plugin, showTitle: false);
}

/// Shared band-editing body used by both [EqualizerSheet] (a modal from
/// Now Playing) and [_EqualizerSettings] (this plugin's settings page).
class _EqualizerBandsEditor extends StatefulWidget {
  final EqualizerPlugin plugin;
  final bool showTitle;

  const _EqualizerBandsEditor({required this.plugin, required this.showTitle});

  @override
  State<_EqualizerBandsEditor> createState() => _EqualizerBandsEditorState();
}

class _EqualizerBandsEditorState extends State<_EqualizerBandsEditor> {
  static const _virtualLabels = {
    'bass': 'Bass',
    'mid': 'Mid',
    'treble': 'Treble',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    final hardware = plugin.hasHardwareBands;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (widget.showTitle)
              Text('Equalizer', style: theme.textTheme.titleLarge)
            else
              Text('Bands', style: theme.textTheme.titleSmall),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (hardware) {
                  // ignore: unawaited_futures
                  plugin.resetHardwareBands();
                } else {
                  plugin.reset();
                }
              }),
              child: const Text('Reset'),
            ),
          ],
        ),
        Text(
          hardware
              ? 'Real per-band hardware equalizer for this device.'
              : 'Virtual trim — this platform has no native per-band '
                  'equalizer, so bands only shape overall loudness.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 220,
          child: hardware ? _buildHardwareBands(plugin) : _buildVirtualBands(plugin),
        ),
      ],
    );
  }

  Widget _buildHardwareBands(EqualizerPlugin plugin) {
    final bands = plugin.hardwareBands;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: bands.map((band) {
        return _BandSlider(
          label: _formatFrequency(band.centerFrequencyHz),
          value: band.gain,
          min: band.minDecibels,
          max: band.maxDecibels,
          onChanged: (v) => setState(() => plugin.setHardwareBand(band.index, v)),
          onChangeEnd: (_) => plugin.persistHardwareBands(),
        );
      }).toList(),
    );
  }

  Widget _buildVirtualBands(EqualizerPlugin plugin) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: EqualizerPlugin.virtualBandKeys.map((key) {
        return _BandSlider(
          label: _virtualLabels[key] ?? key,
          value: plugin.getBand(key),
          min: -12,
          max: 12,
          onChanged: (v) => setState(() => plugin.setBand(key, v)),
          onChangeEnd: (_) => plugin.persistVirtualBands(),
        );
      }).toList(),
    );
  }

  static String _formatFrequency(double hz) {
    if (hz >= 1000) {
      final khz = hz / 1000;
      return '${khz.toStringAsFixed(khz.truncateToDouble() == khz ? 0 : 1)}k';
    }
    return '${hz.round()}';
  }
}

class _BandSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const _BandSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clamped = value.clamp(min, max);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(clamped.toStringAsFixed(1), style: theme.textTheme.labelSmall),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: clamped,
              min: min,
              max: max,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}
