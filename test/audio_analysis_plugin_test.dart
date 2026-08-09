import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/audio_analysis_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real coverage for the Dart HTTP client half of the Essentia analysis
/// pipeline — the plugin's own doc comment previously claimed this was
/// "unit-tested against mocked HTTP responses," but no such test file
/// existed anywhere in this repo. The companion `tools/essentia_service/`
/// (the Python/Essentia server this client talks to) has separately been
/// built, run, and verified end-to-end against a real Docker container —
/// see its README/CHANGELOG for that half.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File audioFile;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir =
        await Directory.systemTemp.createTemp('omnis_audio_analysis_test');
    audioFile = File('${tempDir.path}/song.mp3')
      ..writeAsBytesSync([0xFF, 0xFB, 0x90, 0x00]);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  BaseTrack track({String? localPath}) => BaseTrack(
        id: 't1',
        title: 'Song',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: TrackType.local,
        localPath: localPath,
      );

  test('isAvailable is false until a service URL is configured', () {
    final plugin = AudioAnalysisPlugin();
    expect(plugin.isAvailable, isFalse);
  });

  group('analyzeTrack skips the HTTP call entirely when it cannot succeed',
      () {
    test('no service URL configured', () async {
      var called = false;
      final client =
          MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final plugin = AudioAnalysisPlugin(client: client);

      final result =
          await plugin.analyzeTrack(track(localPath: audioFile.path));

      expect(result.isEmpty, isTrue);
      expect(called, isFalse);
    });

    test('track has no local path', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result = await plugin.analyzeTrack(track(localPath: null));

      expect(result.isEmpty, isTrue);
      expect(called, isFalse);
    });

    test('track has an empty-string local path', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result = await plugin.analyzeTrack(track(localPath: ''));

      expect(result.isEmpty, isTrue);
      expect(called, isFalse);
    });

    test('the local file does not actually exist on disk', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('', 200);
      });
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result = await plugin
          .analyzeTrack(track(localPath: '${tempDir.path}/missing.mp3'));

      expect(result.isEmpty, isTrue);
      expect(called, isFalse);
    });
  });

  test('posts to <serviceUrl>/analyze and parses a full response', () async {
    Uri? capturedUri;
    String? capturedMethod;
    final client = MockClient((req) async {
      capturedUri = req.url;
      capturedMethod = req.method;
      return http.Response(
        jsonEncode({
          'bpm': 128.5,
          'key': 'C',
          'scale': 'major',
          'mood': 'happy',
          'genres': ['pop', 'dance'],
        }),
        200,
      );
    });
    final plugin = AudioAnalysisPlugin(client: client);
    await plugin.setServiceUrl('http://192.168.1.20:8686');

    final result =
        await plugin.analyzeTrack(track(localPath: audioFile.path));

    expect(capturedUri.toString(), 'http://192.168.1.20:8686/analyze');
    expect(capturedMethod, 'POST');
    expect(result.bpm, 128.5);
    expect(result.key, 'C');
    expect(result.scale, 'major');
    expect(result.formattedKey, 'C Major');
    expect(result.mood, 'happy');
    expect(result.genres, ['pop', 'dance']);
    expect(result.isEmpty, isFalse);
  });

  test('a trailing slash on the service URL does not produce a double '
      'slash before /analyze', () async {
    Uri? capturedUri;
    final client = MockClient((req) async {
      capturedUri = req.url;
      return http.Response('{}', 200);
    });
    final plugin = AudioAnalysisPlugin(client: client);
    await plugin.setServiceUrl('http://192.168.1.20:8686/');

    await plugin.analyzeTrack(track(localPath: audioFile.path));

    expect(capturedUri.toString(), 'http://192.168.1.20:8686/analyze');
  });

  test('a minor key formats as "<key> Minor"', () async {
    final client = MockClient((req) async => http.Response(
          jsonEncode({'key': 'A', 'scale': 'minor'}),
          200,
        ));
    final plugin = AudioAnalysisPlugin(client: client);
    await plugin.setServiceUrl('http://localhost:8686');

    final result =
        await plugin.analyzeTrack(track(localPath: audioFile.path));

    expect(result.formattedKey, 'A Minor');
  });

  test('a partial response (bpm only) still parses, with everything else '
      'left null/empty', () async {
    final client =
        MockClient((req) async => http.Response(jsonEncode({'bpm': 90.0}), 200));
    final plugin = AudioAnalysisPlugin(client: client);
    await plugin.setServiceUrl('http://localhost:8686');

    final result =
        await plugin.analyzeTrack(track(localPath: audioFile.path));

    expect(result.bpm, 90.0);
    expect(result.key, isNull);
    expect(result.formattedKey, isNull);
    expect(result.mood, isNull);
    expect(result.genres, isEmpty);
    expect(result.isEmpty, isFalse);
  });

  group('degrades to an empty result instead of throwing', () {
    test('a non-200 response', () async {
      final client = MockClient(
          (req) async => http.Response('Internal Server Error', 500));
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result =
          await plugin.analyzeTrack(track(localPath: audioFile.path));

      expect(result.isEmpty, isTrue);
    });

    test('a malformed (non-JSON) response body', () async {
      final client =
          MockClient((req) async => http.Response('not json', 200));
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result =
          await plugin.analyzeTrack(track(localPath: audioFile.path));

      expect(result.isEmpty, isTrue);
    });

    test('a JSON body that isn\'t an object (e.g. a bare array)', () async {
      final client =
          MockClient((req) async => http.Response(jsonEncode([1, 2, 3]), 200));
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result =
          await plugin.analyzeTrack(track(localPath: audioFile.path));

      expect(result.isEmpty, isTrue);
    });

    test('the service being unreachable (a thrown SocketException)',
        () async {
      final client = MockClient((req) async {
        throw const SocketException('Connection refused');
      });
      final plugin = AudioAnalysisPlugin(client: client);
      await plugin.setServiceUrl('http://localhost:8686');

      final result =
          await plugin.analyzeTrack(track(localPath: audioFile.path));

      expect(result.isEmpty, isTrue);
    });
  });

  test('setServiceUrl trims whitespace and persists across instances',
      () async {
    final plugin = AudioAnalysisPlugin();
    await plugin.setServiceUrl('  http://localhost:8686  ');

    expect(plugin.serviceUrl, 'http://localhost:8686');

    // PluginStorage reads are synchronous but per-instance — a genuinely
    // fresh instance's own PluginStorage hasn't warmed up yet and reads
    // as empty until it does (documented on PluginStorage itself), same
    // as any other bundled plugin's storage. Warming it up explicitly is
    // what actually proves the value round-tripped through
    // SharedPreferences rather than just living in the first instance's
    // memory.
    final second = AudioAnalysisPlugin();
    await second.storage.initialize();
    expect(second.serviceUrl, 'http://localhost:8686');
    expect(second.isAvailable, isTrue);
  });
}
