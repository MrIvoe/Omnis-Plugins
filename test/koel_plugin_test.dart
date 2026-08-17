import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/koel_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<KoelPlugin> configuredPlugin({
    required http.Client client,
    String server = 'https://koel.example.com',
    String email = 'alice@example.com',
    String password = 'hunter2',
  }) async {
    final plugin = KoelPlugin(client: client);
    await plugin.setServerUrl(server);
    await plugin.setEmail(email);
    await plugin.setPassword(password);
    return plugin;
  }

  String loginOkBody({String token = 'session-token'}) =>
      jsonEncode({'token': token});

  Map<String, dynamic> song({
    String id = 'abc123md5',
    String title = 'Song One',
    String? artist = 'Artist',
    String? album = 'Album',
    Object? track = 3,
    Object? length = 210.5,
  }) =>
      {
        'id': id,
        'title': title,
        if (artist != null) 'artist': {'id': 1, 'name': artist},
        if (album != null) 'album': {'id': 1, 'artist_id': 1, 'name': album},
        'track': track,
        'disc': 1,
        'length': length,
      };

  http.Client routingClient({
    required String loginBody,
    int loginStatus = 200,
    required dynamic Function(Uri) searchResponse,
    int searchStatus = 200,
  }) =>
      MockClient((req) async {
        if (req.url.path.endsWith('/api/me')) {
          return http.Response(loginBody, loginStatus);
        }
        if (req.url.path.endsWith('/api/search/songs')) {
          return http.Response(jsonEncode(searchResponse(req.url)), searchStatus);
        }
        return http.Response('', 404);
      });

  group('isConfigured', () {
    test('false until server/email/password are all set', () async {
      final plugin = KoelPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isConfigured, isFalse);

      await plugin.setServerUrl('https://koel.example.com');
      expect(plugin.isConfigured, isFalse);

      await plugin.setEmail('alice@example.com');
      expect(plugin.isConfigured, isFalse);

      await plugin.setPassword('hunter2');
      expect(plugin.isConfigured, isTrue);
    });
  });

  group('testConnection', () {
    test('posts to /api/me with an email/password JSON body, returns '
        'true on success', () async {
      Uri? capturedUri;
      String? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          capturedBody = req.body;
          return http.Response(loginOkBody(), 200);
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isTrue);
      expect(plugin.lastError, isNull);
      expect(capturedUri!.path, '/api/me');
      expect(jsonDecode(capturedBody!),
          {'email': 'alice@example.com', 'password': 'hunter2'});
    });

    test('returns false with lastError when not configured', () async {
      final plugin = KoelPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('returns false for a server URL with no scheme, without calling '
        'the network', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(loginOkBody(), 200);
        }),
        server: 'not a url',
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('returns false on a non-200 login response (wrong credentials)',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 401)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('401'));
    });

    test('returns false when the response has no token', () async {
      final plugin = await configuredPlugin(
        client: MockClient(
            (req) async => http.Response(jsonEncode({'user': {}}), 200)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
    });

    test('returns false, never throws, when the http call itself throws',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          throw Exception('network unreachable');
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('Network error'));
    });
  });

  group('search', () {
    test('returns an empty list without calling the network for a blank '
        'query', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(loginOkBody(), 200);
        }),
      );

      final result = await plugin.search('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('authenticates automatically before the first search, then '
        'parses a bare JSON array of enriched songs into playable '
        'BaseTracks', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          loginBody: loginOkBody(),
          searchResponse: (uri) => [song()],
        ),
      );

      expect(await plugin.testConnection(), isTrue);
      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'koel:abc123md5');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.koel);
      expect(track.artists, ['Artist']);
      expect(track.album, 'Album');
      expect(track.duration, 211); // 210.5 rounded
      expect(track.trackNumber, 3);
      expect(track.streamUrl, isNotNull);
      final streamUri = Uri.parse(track.streamUrl!);
      expect(streamUri.path, '/play/abc123md5/false/0');
      expect(streamUri.queryParameters['api-token'], 'session-token');
      expect(track.coverArt, isNull,
          reason: 'Koel thumbnails need a separate authenticated round '
              'trip, not attempted in this pass');
    });

    test('also parses a {"songs": [...]} wrapper — the spec\'s own '
        'response schema for this endpoint is genuinely underspecified, '
        'so both shapes must work', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          loginBody: loginOkBody(),
          searchResponse: (uri) => {
            'songs': [song(id: 'wrapped-1')],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'koel:wrapped-1');
    });

    test('sends the search request with the cached bearer token, not '
        're-authenticating on a second search', () async {
      var loginCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/api/me')) {
            loginCalls++;
            return http.Response(loginOkBody(), 200);
          }
          return http.Response(jsonEncode(<dynamic>[]), 200);
        }),
      );

      await plugin.search('one');
      await plugin.search('two');

      expect(loginCalls, 1);
    });

    test('the plain Song shape (no embedded artist/album) falls back to '
        'Unknown Artist/Unknown Album', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          loginBody: loginOkBody(),
          searchResponse: (uri) => [
            {'id': 'plain-1', 'title': 'Plain Song', 'artist_id': 1, 'album_id': 1},
          ],
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.artists, ['Unknown Artist']);
      expect(result.single.album, 'Unknown Album');
    });

    test('an entry with no id or no title is skipped rather than '
        'returning a broken track', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          loginBody: loginOkBody(),
          searchResponse: (uri) => [
            {'id': '', 'title': 'No id'},
            {'id': 's2', 'title': ''},
            song(id: 'good-1'),
          ],
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'koel:good-1');
    });

    test('one malformed entry does not wipe the rest of the search '
        'result', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          loginBody: loginOkBody(),
          searchResponse: (uri) => [
            {'id': 123, 'title': null}, // garbage entry
            song(id: 'good-1'),
          ],
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'koel:good-1');
    });

    test('re-authenticates exactly once on a 401 mid-search and retries, '
        'not looping forever if the server keeps rejecting', () async {
      var loginCalls = 0;
      var searchCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/api/me')) {
            loginCalls++;
            return http.Response(loginOkBody(), 200);
          }
          searchCalls++;
          return http.Response('', 401); // always rejects
        }),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      expect(loginCalls, 2);
      expect(searchCalls, 2);
    });

    test('returns an empty list, never throws, when the http call itself '
        'throws', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          throw Exception('network unreachable');
        }),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      expect(plugin.lastError, contains('Network error'));
    });
  });

  test('plugin metadata is well-formed', () {
    final plugin = KoelPlugin();
    expect(plugin.id, 'koel');
    expect(plugin.usesNetwork, isTrue);
  });
}
