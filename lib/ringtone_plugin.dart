import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:set_ringtone/set_ringtone.dart';

/// Sets a local track as the device's ringtone, notification sound, or
/// alarm sound (Android only).
///
/// Uses `set_ringtone`, a thin wrapper around Android's own
/// `RingtoneManager`/`MediaStore` APIs (confirmed by reading its native
/// source — it copies the file into `MediaStore.Audio.Media` with
/// `IS_RINGTONE`/`IS_NOTIFICATION`/`IS_ALARM` set, then calls
/// `RingtoneManager.setActualDefaultRingtoneUri`, the same real mechanism
/// a system Settings app uses, not a workaround). It also requests
/// `WRITE_SETTINGS` itself (routing to Android's "Modify system
/// settings" screen, the same special-permission pattern the Omnis app's
/// `OmnisPermissions.requestStorageWrite` uses for `TagEditorPlugin`) —
/// no separate permission call is needed from this plugin.
///
/// Sets the **whole file** as the ringtone; there is no trim/clip step.
/// Android will play it from the start when a call/notification/alarm
/// fires, the same as manually setting any music file as a ringtone
/// through the system Settings app — genuinely useful for a short track,
/// less so for a full song, but building a waveform trimmer is a
/// separate, much larger feature this pass doesn't attempt.
///
/// **Verification status**: implemented against `set_ringtone`'s
/// documented API and its own native source (read directly, not assumed
/// from the README, which is an unedited boilerplate stub); not
/// exercised against a real Android device in this environment.
class RingtonePlugin extends MusicPlugin {
  String? lastError;

  bool get isSupportedOnThisPlatform => !kIsWeb && Platform.isAndroid;

  Future<bool> setAsRingtone(BaseTrack track) =>
      _set(track, Ringtone.setRingtoneFromFile);
  Future<bool> setAsNotificationSound(BaseTrack track) =>
      _set(track, Ringtone.setNotificationFromFile);
  Future<bool> setAsAlarmSound(BaseTrack track) =>
      _set(track, Ringtone.setAlarmFromFile);

  Future<bool> _set(
    BaseTrack track,
    Future<bool> Function(File file) action,
  ) async {
    if (!isSupportedOnThisPlatform) {
      lastError = 'Only supported on Android.';
      return false;
    }
    final path = track.localPath;
    if (path == null || path.isEmpty) {
      lastError = '"${track.title}" has no local file.';
      return false;
    }
    try {
      final ok = await action(File(path));
      lastError = ok ? null : 'Could not set "${track.title}".';
      return ok;
    } catch (e) {
      lastError = 'Could not set "${track.title}": $e';
      return false;
    }
  }

  @override
  String get id => 'ringtone';

  @override
  String get name => 'Ringtone';

  @override
  String get description => isSupportedOnThisPlatform
      ? 'Set a track as your ringtone, notification, or alarm sound.'
      : 'Android only.';

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
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> dispose() async {}
}
