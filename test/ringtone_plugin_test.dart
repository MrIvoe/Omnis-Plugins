import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/ringtone_plugin.dart';

BaseTrack _track({String? localPath = '/music/song.mp3', String title = 'Song'}) =>
    BaseTrack(
      id: 't1',
      title: title,
      artists: const ['Artist'],
      album: 'Album',
      duration: 180,
      type: TrackType.local,
      localPath: localPath,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform gating (real check — this test host is never Android)',
      () {
    test('isSupportedOnThisPlatform is false on this test host', () {
      final plugin = RingtonePlugin();
      expect(plugin.isSupportedOnThisPlatform, isFalse);
    });

    test('setAsRingtone reports "Android only" and never touches the '
        'native API on an unsupported platform', () async {
      final plugin = RingtonePlugin();

      final ok = await plugin.setAsRingtone(_track());

      expect(ok, isFalse);
      expect(plugin.lastError, 'Only supported on Android.');
    });

    test('setAsNotificationSound and setAsAlarmSound report the same '
        'platform gate', () async {
      final plugin = RingtonePlugin();

      expect(await plugin.setAsNotificationSound(_track()), isFalse);
      expect(plugin.lastError, 'Only supported on Android.');

      expect(await plugin.setAsAlarmSound(_track()), isFalse);
      expect(plugin.lastError, 'Only supported on Android.');
    });

    test('description reflects "Android only" when unsupported', () {
      final plugin = RingtonePlugin();
      expect(plugin.description, 'Android only.');
    });
  });

  group('logic reachable via platformSupportOverride (forces past the '
      'platform gate, exercising branches Platform.isAndroid always '
      'false in CI/dev would otherwise hide)', () {
    test('a track with no local file is rejected before any native call',
        () async {
      final plugin = RingtonePlugin(platformSupportOverride: true);

      final ok = await plugin.setAsRingtone(_track(localPath: null));

      expect(ok, isFalse);
      expect(plugin.lastError, contains('has no local file'));
      expect(plugin.lastError, contains('Song'));
    });

    test('a track with an empty local file path is also rejected',
        () async {
      final plugin = RingtonePlugin(platformSupportOverride: true);

      final ok = await plugin.setAsRingtone(_track(localPath: ''));

      expect(ok, isFalse);
      expect(plugin.lastError, contains('has no local file'));
    });

    test(
        'a real local file path reaches the native call, which fails in '
        'this environment (no Android platform channel) and is reported '
        'through lastError rather than throwing out of setAsRingtone',
        () async {
      final plugin = RingtonePlugin(platformSupportOverride: true);

      final ok = await plugin.setAsRingtone(_track());

      expect(ok, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('description reflects the supported-platform text when forced on',
        () {
      final plugin = RingtonePlugin(platformSupportOverride: true);
      expect(plugin.description,
          'Set a track as your ringtone, notification, or alarm sound.');
    });
  });
}
