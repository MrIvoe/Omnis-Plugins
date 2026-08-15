import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/lyrics_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A no-op stand-in for PluginContext with a real ServiceRegistry — only
/// `services`/`currentTrack` are stubbed, since those are all
/// `LyricsPlugin` ever touches on a context, the same minimal-surface
/// shape `equalizer_plugin_test.dart`'s own `_FakeContext` establishes.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();
  BaseTrack? currentTrackOverride;

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  BaseTrack? get currentTrack => currentTrackOverride;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

class _FakeTagWriter implements IFileTagWriter {
  final List<(String, String)> writeCalls = [];
  bool succeed = true;

  @override
  Future<bool> writeLyrics(String filePath, String lyrics) async {
    writeCalls.add((filePath, lyrics));
    return succeed;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id,
          {String title = 'Title',
          String artist = 'Artist',
          String? localPath}) =>
      BaseTrack(
        id: id,
        title: title,
        artists: [artist],
        album: 'Album',
        duration: 200,
        type: TrackType.local,
        localPath: localPath,
      );

  group('parseLrc', () {
    test('parses a single-timestamp line with a fractional second', () {
      final lines = parseLrc('[00:12.50]Hello there');

      expect(lines, hasLength(1));
      expect(lines.single.timestamp, const Duration(seconds: 12, milliseconds: 500));
      expect(lines.single.text, 'Hello there');
    });

    test('a timestamp with no fractional part defaults to 0 milliseconds',
        () {
      final lines = parseLrc('[01:05]No fraction here');

      expect(lines.single.timestamp, const Duration(minutes: 1, seconds: 5));
    });

    test('fractional precision is normalized regardless of digit count '
        '(.5, .50, .500 all mean 500ms)', () {
      final half = parseLrc('[00:00.5]a').single.timestamp;
      final fifty = parseLrc('[00:00.50]a').single.timestamp;
      final fiveHundred = parseLrc('[00:00.500]a').single.timestamp;

      expect(half, const Duration(milliseconds: 500));
      expect(fifty, const Duration(milliseconds: 500));
      expect(fiveHundred, const Duration(milliseconds: 500));
    });

    test('a metadata line ([ar:...], [ti:...]) is silently skipped, not '
        'misparsed as a timestamp', () {
      final lines = parseLrc('[ar:Some Artist]\n[ti:Some Title]\n'
          '[00:10.00]Real lyric line');

      expect(lines, hasLength(1));
      expect(lines.single.text, 'Real lyric line');
    });

    test('a line with a timestamp but no text after it is skipped', () {
      final lines = parseLrc('[00:10.00]   \n[00:20.00]Real line');

      expect(lines, hasLength(1));
      expect(lines.single.text, 'Real line');
    });

    test('a plain text line with no timestamp at all is skipped', () {
      final lines = parseLrc('just some plain text\n[00:10.00]Real line');

      expect(lines, hasLength(1));
    });

    test('multiple timestamps on one line each get their own entry, '
        'sharing the same text — a repeated chorus line', () {
      final lines = parseLrc('[00:10.00][00:40.00][01:10.00]La la la');

      expect(lines, hasLength(3));
      expect(lines.every((l) => l.text == 'La la la'), isTrue);
      expect(lines[0].timestamp, const Duration(seconds: 10));
      expect(lines[1].timestamp, const Duration(seconds: 40));
      expect(lines[2].timestamp, const Duration(minutes: 1, seconds: 10));
    });

    test('the result is sorted by timestamp regardless of input line '
        'order', () {
      final lines = parseLrc(
          '[00:30.00]Second\n[00:10.00]First\n[00:50.00]Third');

      expect(lines.map((l) => l.text), ['First', 'Second', 'Third']);
    });

    test('an empty string produces an empty list', () {
      expect(parseLrc(''), isEmpty);
    });
  });

  group('currentLyricFor', () {
    test(
        'a position before the first synced line\'s own timestamp shows '
        'nothing yet, not the first line early', () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setTimedLyric(t.id, [
        const LyricLine(timestamp: Duration(seconds: 10), text: 'First line'),
        const LyricLine(timestamp: Duration(seconds: 20), text: 'Second line'),
      ]);

      final result = plugin.currentLyricFor(t, const Duration(seconds: 5));

      expect(result, isEmpty);
    });

    test('a position exactly at a line\'s timestamp shows that line', () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setTimedLyric(t.id, [
        const LyricLine(timestamp: Duration(seconds: 10), text: 'First line'),
        const LyricLine(timestamp: Duration(seconds: 20), text: 'Second line'),
      ]);

      final result = plugin.currentLyricFor(t, const Duration(seconds: 20));

      expect(result, 'Second line');
    });

    test('a position between two lines shows the earlier (most recent) '
        'one', () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setTimedLyric(t.id, [
        const LyricLine(timestamp: Duration(seconds: 10), text: 'First line'),
        const LyricLine(timestamp: Duration(seconds: 20), text: 'Second line'),
      ]);

      final result = plugin.currentLyricFor(t, const Duration(seconds: 15));

      expect(result, 'First line');
    });

    test('a position after the last line shows the last line', () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setTimedLyric(t.id, [
        const LyricLine(timestamp: Duration(seconds: 10), text: 'First line'),
        const LyricLine(timestamp: Duration(seconds: 20), text: 'Second line'),
      ]);

      final result = plugin.currentLyricFor(t, const Duration(minutes: 5));

      expect(result, 'Second line');
    });

    test('timed lyrics take priority over plain lyrics when both exist',
        () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setLyric(t.id, 'Plain lyric text');
      plugin.setTimedLyric(
          t.id, [const LyricLine(timestamp: Duration.zero, text: 'Synced')]);

      expect(plugin.currentLyricFor(t, Duration.zero), 'Synced');
    });

    test('falls back to the plain lyric when there are no timed lines',
        () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setLyric(t.id, 'Plain lyric text');

      expect(
          plugin.currentLyricFor(t, const Duration(seconds: 30)), 'Plain lyric text');
    });

    test('shows a "not stored yet" message when there is nothing at all',
        () {
      final plugin = LyricsPlugin();
      final t = track('t1');

      expect(plugin.currentLyricFor(t, Duration.zero),
          'No lyrics added for this track yet.');
    });
  });

  group('setLyric / hasLyrics / persistence', () {
    test('setLyric with an empty/whitespace string clears any stored '
        'lyric instead of storing blank text', () {
      final plugin = LyricsPlugin();
      final t = track('t1');
      plugin.setLyric(t.id, 'Real lyric');
      plugin.setLyric(t.id, '   ');

      expect(plugin.lyricFor(t), isNull);
    });

    test('hasLyrics is true for either a plain or a timed lyric', () {
      final plugin = LyricsPlugin();
      expect(plugin.hasLyrics(track('a')), isFalse);

      plugin.setLyric('a', 'Plain');
      expect(plugin.hasLyrics(track('a')), isTrue);

      plugin.setTimedLyric(
          'b', [const LyricLine(timestamp: Duration.zero, text: 'x')]);
      expect(plugin.hasLyrics(track('b')), isTrue);
    });

    test('a plain lyric persists across a fresh plugin instance', () async {
      final plugin = LyricsPlugin();
      plugin.setLyric('t1', 'Persisted lyric');
      // setLyric's storage write is fire-and-forget; give it a tick.
      await Future<void>.delayed(Duration.zero);

      // A fresh PluginStorage starts cold until something awaits it —
      // warm it explicitly first, the same as ratings_plugin_test.dart's
      // own "persists across a fresh instance" check.
      final fresh = LyricsPlugin();
      await fresh.storage.initialize();
      await fresh.initialize();

      expect(fresh.lyricFor(track('t1')), 'Persisted lyric');
    });
  });

  group('fetchLyrics (lrclib)', () {
    test('an exact match with synced lyrics stores both plain and timed '
        'lyrics, and sets a real status message', () async {
      final client = MockClient((req) async {
        expect(req.url.path, '/api/get');
        return http.Response(
          jsonEncode({
            'plainLyrics': 'Hello world',
            'syncedLyrics': '[00:01.00]Hello world',
            'instrumental': false,
          }),
          200,
        );
      });
      final plugin = LyricsPlugin(client: client);
      final t = track('t1');

      final result = await plugin.fetchLyrics(t);

      expect(result.plainLyrics, 'Hello world');
      expect(result.syncedLyrics, hasLength(1));
      expect(plugin.lyricFor(t), 'Hello world');
      expect(plugin.timedLyricFor(t), hasLength(1));
      expect(plugin.lastFetchStatus, contains('Fetched lyrics from'));
    });

    test('a response marked instrumental stores nothing and reports a '
        'specific status', () async {
      final client = MockClient((req) async => http.Response(
          jsonEncode({'instrumental': true}), 200));
      final plugin = LyricsPlugin(client: client);
      final t = track('t1');

      final result = await plugin.fetchLyrics(t);

      expect(result.instrumental, isTrue);
      expect(plugin.hasLyrics(t), isFalse);
      expect(plugin.lastFetchStatus, contains('instrumental'));
    });

    test('an exact-match 404 falls back to search and takes its first '
        'result', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/get') {
          return http.Response('', 404);
        }
        expect(req.url.path, '/api/search');
        return http.Response(
          jsonEncode([
            {'plainLyrics': 'From search', 'syncedLyrics': null, 'instrumental': false},
          ]),
          200,
        );
      });
      final plugin = LyricsPlugin(client: client);

      final result = await plugin.fetchLyrics(track('t1'));

      expect(result.plainLyrics, 'From search');
    });

    test('both endpoints failing yields an empty result and a "not '
        'found" status on a manual fetch, but stays quiet on an '
        'automatic one', () async {
      final client = MockClient((req) async => http.Response('', 500));
      final plugin = LyricsPlugin(client: client);
      final t = track('t1');

      final manual = await plugin.fetchLyrics(t);
      expect(manual.isEmpty, isTrue);
      expect(plugin.lastFetchStatus, 'No lyrics found for this track.');

      final auto = await plugin.fetchLyrics(t, auto: true);
      expect(auto.isEmpty, isTrue);
      expect(plugin.lastFetchStatus, isNull);
    });

    test('a track with no artist or title never makes a network call at '
        'all', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final plugin = LyricsPlugin(client: client);

      await plugin.fetchLyrics(
          track('t1', title: '', artist: 'Someone'));

      expect(called, isFalse);
    });

    test('a network exception degrades to an empty result rather than '
        'throwing', () async {
      final client = MockClient((req) async => throw Exception('offline'));
      final plugin = LyricsPlugin(client: client);

      final result = await plugin.fetchLyrics(track('t1'));

      expect(result.isEmpty, isTrue);
    });

    test('when writeToMetadataEnabled is on and a tag writer is '
        'registered, fetched plain lyrics are written into the file, '
        'and the status reflects success', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/get') {
          return http.Response(
              jsonEncode({'plainLyrics': 'Write me', 'instrumental': false}),
              200);
        }
        return http.Response('', 500);
      });
      final plugin = LyricsPlugin(client: client);
      final ctx = _FakeContext();
      final writer = _FakeTagWriter();
      ctx.servicesRegistry.register(IFileTagWriter, writer);
      plugin.attach(ctx);
      await plugin.setWriteToMetadataEnabled(true);

      final t = track('t1', localPath: '/music/t1.mp3');
      await plugin.fetchLyrics(t);

      expect(writer.writeCalls, hasLength(1));
      expect(writer.writeCalls.single.$1, '/music/t1.mp3');
      expect(writer.writeCalls.single.$2, 'Write me');
      expect(plugin.lastFetchStatus, contains('Written into the file'));
    });

    test('a failed write to the file tags still keeps the in-app lyric '
        'and reports the failure distinctly', () async {
      final client = MockClient((req) async {
        if (req.url.path == '/api/get') {
          return http.Response(
              jsonEncode({'plainLyrics': 'Write me', 'instrumental': false}),
              200);
        }
        return http.Response('', 500);
      });
      final plugin = LyricsPlugin(client: client);
      final ctx = _FakeContext();
      final writer = _FakeTagWriter()..succeed = false;
      ctx.servicesRegistry.register(IFileTagWriter, writer);
      plugin.attach(ctx);
      await plugin.setWriteToMetadataEnabled(true);

      final t = track('t1', localPath: '/music/t1.mp3');
      await plugin.fetchLyrics(t);

      expect(plugin.lyricFor(t), 'Write me');
      expect(plugin.lastFetchStatus, contains('Could not write'));
    });
  });

  group('onTrackStart auto-fetch gating', () {
    test('does nothing when autoFetchEnabled is off', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 500);
      });
      final plugin = LyricsPlugin(client: client);

      await plugin.onTrackStart(track('t1'));

      expect(called, isFalse);
    });

    test('does nothing when the track already has lyrics stored', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 500);
      });
      final plugin = LyricsPlugin(client: client);
      await plugin.setAutoFetchEnabled(true);
      final t = track('t1');
      plugin.setLyric(t.id, 'Already have this');

      await plugin.onTrackStart(t);

      expect(called, isFalse);
    });

    test('fetches when auto-fetch is on and nothing is stored yet',
        () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response(
            jsonEncode({'plainLyrics': 'Fetched', 'instrumental': false}),
            200);
      });
      final plugin = LyricsPlugin(client: client);
      await plugin.setAutoFetchEnabled(true);

      await plugin.onTrackStart(track('t1'));

      expect(called, isTrue);
    });
  });
}
