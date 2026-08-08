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
///
/// Playback fades out over [fadeSeconds] before pausing rather than
/// stopping dead — a hard cut is jarring if it happens to catch someone
/// mid-doze, and a fade is the behavior every competing sleep-timer
/// implementation offers. The pre-fade volume is always restored once
/// the fade completes or the timer is cancelled mid-fade, so the user's
/// volume setting is never left changed by having used this feature.
class SleepTimerPlugin extends MusicPlugin {
  static const _defaultMinutesKey = 'default_minutes';
  static const _defaultMinutesFallback = 30;
  static const _fadeSecondsKey = 'fade_seconds';
  static const _fadeSecondsFallback = 20;
  static const _fadeStepInterval = Duration(milliseconds: 200);

  /// Overrides the default "pause via the audio engine" behaviour.
  final Future<void> Function()? onPause;

  /// Overrides the default "set volume via the audio engine" behaviour.
  final Future<void> Function(double)? onSetVolume;

  Timer? _timer;
  Timer? _fadeTimer;
  bool _active = false;
  Duration? _duration;
  DateTime? _firesAt;

  /// The volume to restore to once the fade (or an early cancel) ends.
  /// Also doubles as "a fade is currently in progress" ([isFading]).
  double? _preFadeVolume;

  SleepTimerPlugin({this.onPause, this.onSetVolume});

  /// The duration pre-selected when the duration picker opens. Persisted,
  /// so "the timer I always use" doesn't need re-picking every time.
  int get defaultMinutes =>
      storage.getInt(_defaultMinutesKey) ?? _defaultMinutesFallback;

  Future<void> setDefaultMinutes(int minutes) =>
      storage.setInt(_defaultMinutesKey, minutes);

  /// How long, in seconds, playback fades out before pausing. `0` disables
  /// the fade entirely (an immediate hard pause, the original behavior).
  int get fadeSeconds =>
      storage.getInt(_fadeSecondsKey) ?? _fadeSecondsFallback;

  Future<void> setFadeSeconds(int seconds) =>
      storage.setInt(_fadeSecondsKey, seconds.clamp(0, 300));

  /// Whether a timer is currently counting down.
  bool get isActive => _active;

  /// Whether the volume is currently fading out (the tail end of an
  /// active timer).
  bool get isFading => _preFadeVolume != null;

  /// The duration the active timer was started with.
  Duration? get duration => _duration;

  /// How long until playback pauses (fully faded out, if fading is on),
  /// or `null` when inactive.
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

    final fade = Duration(seconds: fadeSeconds);
    final effectiveFade = fade > Duration.zero && fade < duration
        ? fade
        : (fade >= duration ? duration : Duration.zero);
    final delayBeforeFade = duration - effectiveFade;

    _timer = Timer(delayBeforeFade, () {
      if (effectiveFade > Duration.zero) {
        _beginFade(effectiveFade);
      } else {
        // ignore: unawaited_futures
        _finish();
      }
    });
  }

  void _beginFade(Duration fadeDuration) {
    final startVolume = context?.volume ?? 1.0;
    if (startVolume <= 0) {
      // ignore: unawaited_futures
      _finish();
      return;
    }
    _preFadeVolume = startVolume;
    final steps = (fadeDuration.inMilliseconds / _fadeStepInterval.inMilliseconds)
        .ceil()
        .clamp(1, 1 << 20);
    var step = 0;
    _fadeTimer = Timer.periodic(_fadeStepInterval, (timer) {
      step++;
      final t = (step / steps).clamp(0.0, 1.0);
      // ignore: unawaited_futures
      _setVolume(startVolume * (1 - t));
      if (t >= 1.0) {
        timer.cancel();
        _fadeTimer = null;
        // ignore: unawaited_futures
        _finish();
      }
    });
  }

  Future<void> _finish() async {
    _active = false;
    _firesAt = null;
    await _pause();
    final restore = _preFadeVolume;
    _preFadeVolume = null;
    if (restore != null) {
      await _setVolume(restore);
    }
  }

  /// Cancel the sleep timer. Restores the pre-fade volume immediately if
  /// cancelled mid-fade — otherwise the music would come back at whatever
  /// partially-faded level it happened to be cancelled at.
  void stopTimer() {
    _timer?.cancel();
    _timer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _active = false;
    _duration = null;
    _firesAt = null;
    final restore = _preFadeVolume;
    _preFadeVolume = null;
    if (restore != null) {
      // ignore: unawaited_futures
      _setVolume(restore);
    }
  }

  Future<void> _pause() async {
    final override = onPause;
    if (override != null) {
      await override();
      return;
    }
    await context?.pause();
  }

  Future<void> _setVolume(double value) async {
    final override = onSetVolume;
    if (override != null) {
      await override(value);
      return;
    }
    await context?.setVolume(value);
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
/// list. Two real preferences: which duration the picker opens to by
/// default, and how long the fade-out before pausing lasts. Starting/
/// stopping the timer itself is transient state, not a setting, so it
/// stays in Now Playing where the timer is actually used.
class _SleepTimerSettings extends StatefulWidget {
  final SleepTimerPlugin plugin;

  const _SleepTimerSettings({required this.plugin});

  @override
  State<_SleepTimerSettings> createState() => _SleepTimerSettingsState();
}

class _SleepTimerSettingsState extends State<_SleepTimerSettings> {
  static const _durationOptions = [15, 30, 45, 60, 90, 120];
  static const _fadeOptions = [0, 10, 20, 30, 60];

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Default duration'),
          subtitle: const Text(
              'Pre-selected value when you open the sleep timer picker'),
          trailing: DropdownButton<int>(
            value: _durationOptions.contains(plugin.defaultMinutes)
                ? plugin.defaultMinutes
                : _durationOptions.first,
            items: [
              for (final minutes in _durationOptions)
                DropdownMenuItem(value: minutes, child: Text('$minutes min')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => plugin.setDefaultMinutes(value));
            },
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Fade out'),
          subtitle: const Text(
              'Playback fades to silent over this long before pausing, '
              'instead of cutting off abruptly. "Off" pauses immediately.'),
          trailing: DropdownButton<int>(
            value: _fadeOptions.contains(plugin.fadeSeconds)
                ? plugin.fadeSeconds
                : _fadeOptions[2],
            items: [
              for (final seconds in _fadeOptions)
                DropdownMenuItem(
                  value: seconds,
                  child: Text(seconds == 0 ? 'Off' : '${seconds}s'),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => plugin.setFadeSeconds(value));
            },
          ),
        ),
      ],
    );
  }
}
