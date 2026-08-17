import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/ampache_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<AmpachePlugin> configuredPlugin({
    required http.Client client,
    String server = 'https://ampache.example.com',
    String username = 'alice',
    String password = 'hunter2',
  }) async {
    final plugin = AmpachePlugin(client: client);
    await plugin.setServerUrl(server);
    await plugin.setUsername(username);
    await plugin.setPassword(password);
    return plugin;
  }

  String handshakeOkBody({String token = 'session-token'}) => jsonEncode({
        'auth': token,
        'session_expire': '2099-01-01T00:00:00+00:00',
        'api': '6.6.1',
        'username': 'alice',
      });

  String errorBody({String code = '4701', String message = 'Session Expired'}) =>
      jsonEncode({
        'error': {
          'errorCode': code,
          'errorAction': 'songs',
          'errorType': 'account',
          'errorMessage': message,
        },
      });

  Map<String, dynamic> song({
    String id = 's1',
    String title = 'Song One',
    String? artist = 'Artist',
    String? album = 'Album',
    List<String>? genres = const ['Rock'],
    Object? track = 3,
    Object? year = 2020,
    Object? time = 210,
    String? url = 'https://ampache.example.com/play/s1?auth=session-token',
    String? art = 'https://ampache.example.com/art/s1',
  }) =>
      {
        'id': id,
        'title': title,
        if (artist != null) 'artist': {'id': 'a1', 'name': artist},
        if (album != null) 'album': {'id': 'al1', 'name': album},
        'genre': genres
            ?.map((g) => {'id': g, 'name': g})
            .toList(),
        'track': track,
        'year': year,
        'time': time,
        'url': url,
        'art': art,
      };

  http.Client routingClient({
    required String handshakeBody,
    int handshakeStatus = 200,
    required Map<String, dynamic> Function(Uri) songsResponse,
    int songsStatus = 200,
  }) =>
      MockClient((req) async {
        final action = req.url.queryParameters['action'];
        if (action == 'handshake') {
          return http.Response(handshakeBody, handshakeStatus);
        }
        if (action == 'songs') {
          return http.Response(jsonEncode(songsResponse(req.url)), songsStatus);
        }
        return http.Response('', 404);
      });

  group('computeHandshakeAuth', () {
    test('is SHA256(timestamp + SHA256(password)), timestamp first', () {
      const password = 'hunter2';
      const timestamp = 1700000000;
      final expectedKey = sha256.convert(utf8.encode(password)).toString();
      final expected =
          sha256.convert(utf8.encode('$timestamp$expectedKey')).toString();

      expect(
        AmpachePlugin.computeHandshakeAuth(password, timestamp),
        expected,
      );
    });

    test('different passwords produce different hashes for the same '
        'timestamp', () {
      expect(
        AmpachePlugin.computeHandshakeAuth('a', 1700000000),
        isNot(AmpachePlugin.computeHandshakeAuth('b', 1700000000)),
      );
    });
  });

  group('isConfigured', () {
    test('false until server/username/password are all set', () async {
      final plugin = AmpachePlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isConfigured, isFalse);

      await plugin.setServerUrl('https://ampache.example.com');
      expect(plugin.isConfigured, isFalse);

      await plugin.setUsername('alice');
      expect(plugin.isConfigured, isFalse);

      await plugin.setPassword('hunter2');
      expect(plugin.isConfigured, isTrue);
    });
  });

  group('testConnection', () {
    test('calls action=handshake with a computed auth param, returns true '
        'on success', () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(handshakeOkBody(), 200);
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isTrue);
      expect(plugin.lastError, isNull);
      expect(capturedUri!.path, '/server/json.server.php');
      expect(capturedUri!.queryParameters['action'], 'handshake');
      expect(capturedUri!.queryParameters['user'], 'alice');
      expect(capturedUri!.queryParameters['auth'], isNotEmpty);
      expect(capturedUri!.queryParameters['timestamp'], isNotEmpty);
    });

    test('returns false with lastError when not configured', () async {
      final plugin = AmpachePlugin(client: MockClient((r) async {
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
          return http.Response(handshakeOkBody(), 200);
        }),
        server: 'not a url',
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('returns false on a non-200 HTTP response', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 500)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('500'));
    });

    test('returns false, reading the Ampache-shaped error body, on an '
        'HTTP-200-with-error-body handshake failure — Ampache\'s API '
        'always returns 200 even on failure', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response(errorBody(), 200)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('Session Expired'));
    });

    test('returns false when the response has no auth token', () async {
      final plugin = await configuredPlugin(
        client: MockClient(
            (req) async => http.Response(jsonEncode({'api': '6.6.1'}), 200)),
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
          return http.Response(handshakeOkBody(), 200);
        }),
      );

      final result = await plugin.search('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('authenticates automatically before the first search, then '
        'parses real results into playable BaseTracks — including the '
        'nested artist/album/genre NamedReference decoding', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'total_count': 1,
            'song': [song()],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'ampache:s1');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.ampache);
      expect(track.artists, ['Artist']);
      expect(track.album, 'Album');
      expect(track.genres, ['Rock']);
      expect(track.duration, 210);
      expect(track.trackNumber, 3);
      expect(track.year, 2020);
      expect(track.streamUrl,
          'https://ampache.example.com/play/s1?auth=session-token');
      expect(track.coverArt, 'https://ampache.example.com/art/s1');
    });

    test('sends the search request with the cached session token, not '
        're-authenticating on a second search', () async {
      var handshakeCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.queryParameters['action'] == 'handshake') {
            handshakeCalls++;
            return http.Response(handshakeOkBody(), 200);
          }
          return http.Response(
            jsonEncode({'total_count': 0, 'song': <dynamic>[]}),
            200,
          );
        }),
      );

      await plugin.search('one');
      await plugin.search('two');

      expect(handshakeCalls, 1);
    });

    test('a song with no artist falls back to "Unknown Artist"; no album '
        'falls back to "Unknown Album"', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'song': [song(artist: null, album: null)],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.artists, ['Unknown Artist']);
      expect(result.single.album, 'Unknown Album');
    });

    test('a song with no art has no coverArt', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'song': [song(art: null)],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.coverArt, isNull);
    });

    test('a song with no id or no title is skipped rather than returning '
        'a broken track', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'song': [
              {'id': '', 'title': 'No id'},
              {'id': 's2', 'title': ''},
              song(id: 'good-1'),
            ],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'ampache:good-1');
    });

    test('a "name" field is read when "title" is absent — Ampache\'s own '
        'docs list both for the same field', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'song': [
              {
                'id': 's1',
                'name': 'Named Song',
                'time': 200,
              },
            ],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.title, 'Named Song');
    });

    test('one malformed entry does not wipe the rest of the search '
        'result', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          handshakeBody: handshakeOkBody(),
          songsResponse: (uri) => {
            'song': [
              {'id': 123, 'title': null}, // garbage entry
              song(id: 'good-1'),
            ],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'ampache:good-1');
    });

    test('re-authenticates exactly once on an Ampache-shaped error body '
        'mid-search (HTTP 200, error in the JSON) and retries, not '
        'looping forever if the server keeps rejecting', () async {
      var handshakeCalls = 0;
      var songsCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.queryParameters['action'] == 'handshake') {
            handshakeCalls++;
            return http.Response(handshakeOkBody(), 200);
          }
          songsCalls++;
          return http.Response(errorBody(), 200); // always rejects
        }),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      // One initial attempt (no cached session) + one retry after the
      // first error body = 2 handshake calls, 2 songs calls, not an
      // infinite loop.
      expect(handshakeCalls, 2);
      expect(songsCalls, 2);
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
    final plugin = AmpachePlugin();
    expect(plugin.id, 'ampache');
    expect(plugin.usesNetwork, isTrue);
  });
}
