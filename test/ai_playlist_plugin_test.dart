import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/ai_playlist_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id, {String title = 'Song', String artist = 'Artist'}) =>
      BaseTrack(
        id: id,
        title: title,
        artists: [artist],
        album: 'Album',
        duration: 200,
        type: TrackType.local,
        genres: const ['Rock'],
        mood: 'Energetic',
        bpm: 140,
      );

  Future<AIPlaylistPlugin> configuredPlugin({
    required http.Client client,
    String apiKey = 'sk-ant-test-key',
  }) async {
    final plugin = AIPlaylistPlugin(client: client);
    await plugin.setApiKey(apiKey);
    return plugin;
  }

  String anthropicOkBody(String text) => jsonEncode({
        'id': 'msg_1',
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text}
        ],
      });

  group('isAvailable', () {
    test('false until an API key is set', () async {
      final plugin = AIPlaylistPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isAvailable, isFalse);

      await plugin.setApiKey('sk-ant-test-key');
      expect(plugin.isAvailable, isTrue);
    });
  });

  group('buildPlaylistFromPrompt', () {
    test('returns an empty list without calling the network for a blank '
        'prompt', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          '   ', [track('t1')]);

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('returns an empty list with lastError when no API key is '
        'configured, without calling the network', () async {
      var called = false;
      final plugin = AIPlaylistPlugin(client: MockClient((req) async {
        called = true;
        return http.Response(anthropicOkBody('[]'), 200);
      }));

      final result =
          await plugin.buildPlaylistFromPrompt('workout playlist', [track('t1')]);

      expect(result, isEmpty);
      expect(called, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('returns an empty list with lastError for an empty library, '
        'without calling the network', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );

      final result =
          await plugin.buildPlaylistFromPrompt('workout playlist', const []);

      expect(result, isEmpty);
      expect(called, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('sends the real Anthropic Messages API request shape: correct '
        'URL, x-api-key header, model, and the prompt/catalog in the '
        'user message', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      Map<String, dynamic>? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          capturedHeaders = req.headers;
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(anthropicOkBody('["t1"]'), 200);
        }),
      );

      await plugin.buildPlaylistFromPrompt(
        'a two-hour workout playlist',
        [track('t1', title: 'Pump It')],
      );

      expect(capturedUri!.host, 'api.anthropic.com');
      expect(capturedUri!.path, '/v1/messages');
      expect(capturedHeaders!['x-api-key'], 'sk-ant-test-key');
      expect(capturedHeaders!['anthropic-version'], '2023-06-01');
      expect(capturedBody!['model'], 'claude-3-5-haiku-20241022');
      final userContent = (capturedBody!['messages'] as List).first['content'];
      expect(userContent, contains('a two-hour workout playlist'));
      expect(userContent, contains('Pump It'));
      expect(userContent, contains('t1'));
    });

    test('uses a configured custom model instead of the default', () async {
      Map<String, dynamic>? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );
      await plugin.setModel('claude-3-opus-20240229');

      await plugin.buildPlaylistFromPrompt('workout', [track('t1')]);

      expect(capturedBody!['model'], 'claude-3-opus-20240229');
    });

    test('maps returned ids back to real BaseTracks, in the order the '
        'model returned them', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(anthropicOkBody('["t2", "t1"]'), 200)),
      );
      final library = [
        track('t1', title: 'First'),
        track('t2', title: 'Second'),
      ];

      final result = await plugin.buildPlaylistFromPrompt('mix', library);

      expect(result.map((t) => t.id).toList(), ['t2', 't1']);
    });

    test('never invents a track: an id the model returned that is not in '
        'the library is silently dropped', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(anthropicOkBody('["t1", "made-up-id"]'), 200)),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          'mix', [track('t1')]);

      expect(result, hasLength(1));
      expect(result.single.id, 't1');
    });

    test('strips a markdown code fence the model wrapped its JSON '
        'response in, despite being told not to', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response(
            anthropicOkBody('```json\n["t1"]\n```'), 200)),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          'mix', [track('t1')]);

      expect(result, hasLength(1));
      expect(result.single.id, 't1');
    });

    test('returns an empty list and sets lastError when the reply text '
        'is not valid JSON at all', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(anthropicOkBody('Sure! Here is your playlist.'), 200)),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          'mix', [track('t1')]);

      expect(result, isEmpty);
      expect(plugin.lastError, isNotNull);
    });

    test('returns an empty list and surfaces the API\'s own error '
        'message on a non-200 response', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response(
            jsonEncode({
              'type': 'error',
              'error': {
                'type': 'authentication_error',
                'message': 'invalid x-api-key',
              },
            }),
            401)),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          'mix', [track('t1')]);

      expect(result, isEmpty);
      expect(plugin.lastError, 'invalid x-api-key');
    });

    test('returns an empty list, never throws, when the http call itself '
        'throws', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          throw Exception('network unreachable');
        }),
      );

      final result = await plugin.buildPlaylistFromPrompt(
          'mix', [track('t1')]);

      expect(result, isEmpty);
      expect(plugin.lastError, contains('Network error'));
    });

    test('caps the library sample sent to the model rather than sending '
        'an unbounded library', () async {
      Map<String, dynamic>? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );
      final hugeLibrary = [
        for (var i = 0; i < 500; i++) track('t$i'),
      ];

      await plugin.buildPlaylistFromPrompt('mix', hugeLibrary);

      final userContent = (capturedBody!['messages'] as List).first['content']
          as String;
      // t499 is outside the 300-track cap and must never appear.
      expect(userContent, isNot(contains('"t499"')));
      expect(userContent, contains('"t299"'));
    });
  });

  group('searchLibrary (item 43, natural language search)', () {
    test('returns an empty list without calling the network for a blank '
        'query', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );

      final result = await plugin.searchLibrary('   ', [track('t1')]);

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('returns an empty list with lastError when no API key is '
        'configured, without calling the network', () async {
      var called = false;
      final plugin = AIPlaylistPlugin(client: MockClient((req) async {
        called = true;
        return http.Response(anthropicOkBody('[]'), 200);
      }));

      final result =
          await plugin.searchLibrary('upbeat 90s songs', [track('t1')]);

      expect(result, isEmpty);
      expect(called, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('returns an empty list with lastError for an empty library, '
        'without calling the network', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(anthropicOkBody('[]'), 200);
        }),
      );

      final result =
          await plugin.searchLibrary('upbeat 90s songs', const []);

      expect(result, isEmpty);
      expect(called, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('sends the search query (not a playlist-building instruction) '
        'in the request, reusing the same real Anthropic Messages API '
        'shape', () async {
      Uri? capturedUri;
      Map<String, dynamic>? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(anthropicOkBody('["t1"]'), 200);
        }),
      );

      await plugin.searchLibrary(
        'upbeat 90s songs I haven\'t played in a while',
        [track('t1', title: 'Groove')],
      );

      expect(capturedUri!.host, 'api.anthropic.com');
      expect(capturedUri!.path, '/v1/messages');
      final userContent = (capturedBody!['messages'] as List).first['content'];
      expect(userContent,
          contains('upbeat 90s songs I haven\'t played in a while'));
      expect(userContent, contains('Groove'));
      // The system prompt is search-specific, not the playlist-building
      // one — proves searchLibrary isn't accidentally reusing
      // buildPlaylistFromPrompt's own instruction text verbatim.
      expect(capturedBody!['system'], contains('search'));
      expect(capturedBody!['system'], isNot(contains('listening order')));
    });

    test('maps returned ids back to real BaseTracks and never invents '
        'one not in the library', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(anthropicOkBody('["t1", "made-up-id"]'), 200)),
      );

      final result =
          await plugin.searchLibrary('rock songs', [track('t1')]);

      expect(result, hasLength(1));
      expect(result.single.id, 't1');
    });

    test('an empty match array is a valid, successful result — no error, '
        'just nothing found', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(anthropicOkBody('[]'), 200)),
      );

      final result =
          await plugin.searchLibrary('polka accordion solos', [track('t1')]);

      expect(result, isEmpty);
      expect(plugin.lastError, isNull);
    });
  });

  test('plugin metadata is well-formed', () {
    final plugin = AIPlaylistPlugin();
    expect(plugin.id, 'ai_playlist');
    expect(plugin.usesNetwork, isTrue);
  });
}
