import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// A bundled Namida-inspired plugin that pauses playback after a delay.
///
/// The registered instance used to be constructed with no `onPause`
/// callback, so when its timer fired it called nothing and playback carried
/// on. It now pauses through [MusicPlugin.context] by default; [onPause]
/// remains as an injection point for tests.
class SleepTimerPlugin extends MusicPlugin {
  static const _defaultMinutesKey = 'default_minutes';
  static const _defaultMinutesFallback = 30;

  /// Overrides the default "pause via the audio engine" behaviour.
  final Future<void> Function()? onPause;

  Timer? _timer;
  bool _active = false;
  Duration? _duration;
  DateTime? _firesAt;

  SleepTimerPlugin({this.onPause});

  /// The duration pre-selected when the duration picker opens. Persisted,
  /// so "the timer I always use" doesn't need re-picking every time.
  int get defaultMinutes =>
      storage.getInt(_defaultMinutesKey) ?? _defaultMinutesFallback;

  Future<void> setDefaultMinutes(int minutes) =>
      storage.setInt(_defaultMinutesKey, minutes);

  /// Whether a timer is currently counting down.
  bool get isActive => _active;

  /// The duration the active timer was started with.
  Duration? get duration => _duration;

  /// How long until playback pauses, or `null` when inactive.
  Duration? get remaining {
    final firesAt = _firesAt;
    if (!_active || firesAt == null) return null;
    final left = firesAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Start (or restart) the sleep timer.
  void startTimer(Duration duration) {
    stopTimer();
    _active = true;
    _duration = duration;
    _firesAt = DateTime.now().add(duration);
    _timer = Timer(duration, () async {
      _active = false;
      _firesAt = null;
      await _pause();
    });
  }

  /// Cancel the sleep timer.
  void stopTimer() {
    _timer?.cancel();
    _timer = null;
    _active = false;
    _duration = null;
    _firesAt = null;
  }

  Future<void> _pause() async {
    final override = onPause;
    if (override != null) {
      await override();
      return;
    }
    await context?.pause();
  }

  @override
  String get id => 'sleep_timer';

  @override
  String get name => 'Sleep Timer';

  @override
  String get description => 'Pause playback after a chosen duration.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _SleepTimerSettings(plugin: this) : null;

  @override
  Future<void> disable() async {
    // A disabled plugin must not pause the user's music later on.
    stopTimer();
  }

  @override
  Future<void> dispose() async {
    stopTimer();
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. The only real preference here: which duration the picker opens
/// to by default. Starting/stopping the timer itself is transient state,
/// not a setting, so it stays in Now Playing where the timer is actually
/// used.
class _SleepTimerSettings extends StatelessWidget {
  final SleepTimerPlugin plugin;

  const _SleepTimerSettings({required this.plugin});

  static const _options = [15, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Default duration'),
      subtitle: const Text(
          'Pre-selected value when you open the sleep timer picker'),
      trailing: DropdownButton<int>(
        value: _options.contains(plugin.defaultMinutes)
            ? plugin.defaultMinutes
            : _options.first,
        items: [
          for (final minutes in _options)
            DropdownMenuItem(value: minutes, child: Text('$minutes min')),
        ],
        onChanged: (value) {
          if (value != null) plugin.setDefaultMinutes(value);
        },
      ),
    );
  }
}
