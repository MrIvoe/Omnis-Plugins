import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/opensubsonic_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fixed-sequence "random" source so tests can predict exactly what
/// salt the plugin generates and independently verify the auth token
/// it computes from it — a real `Random.secure()` would make that
/// impossible to assert against.
class _FixedRandom implements Random {
  int _next = 0;
  @override
  int nextInt(int max) {
    final value = _next % max;
    _next++;
    return value;
  }

  @override
  double nextDouble() => 0.5;
  @override
  bool nextBool() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<OpenSubsonicPlugin> configuredPlugin({
    required http.Client client,
    String server = 'https://music.example.com',
    String username = 'alice',
    String password = 'hunter2',
  }) async {
    final plugin = OpenSubsonicPlugin(client: client, random: _FixedRandom());
    await plugin.setServerUrl(server);
    await plugin.setUsername(username);
    await plugin.setPassword(password);
    return plugin;
  }

  Map<String, dynamic> song({
    String id = 's1',
    String title = 'Song One',
    String? artist = 'Artist',
    String? album = 'Album',
    String? genre = 'Rock',
    Object? duration = 210,
    Object? track = 3,
    Object? year = 2020,
    String? coverArt = 'cover-1',
  }) =>
      {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'genre': genre,
        'duration': duration,
        'track': track,
        'year': year,
        'coverArt': coverArt,
      };

  String okBody(Map<String, dynamic> extra) => jsonEncode({
        'subsonic-response': {'status': 'ok', ...extra},
      });

  String errorBody(String message) => jsonEncode({
        'subsonic-response': {
          'status': 'failed',
          'error': {'code': 40, 'message': message},
        },
      });

  group('isConfigured', () {
    test('false until server/username/password are all set', () async {
      final plugin = OpenSubsonicPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isConfigured, isFalse);

      await plugin.setServerUrl('https://music.example.com');
      expect(plugin.isConfigured, isFalse);

      await plugin.setUsername('alice');
      expect(plugin.isConfigured, isFalse);

      await plugin.setPassword('hunter2');
      expect(plugin.isConfigured, isTrue);
    });
  });

  group('auth token', () {
    test('the token param is exactly md5(password + salt), matching the '
        'salt actually sent in the same request', () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(okBody({}), 200);
        }),
      );

      await plugin.testConnection();

      final salt = capturedUri!.queryParameters['s']!;
      final expectedToken =
          md5.convert(utf8.encode('hunter2$salt')).toString();
      expect(capturedUri!.queryParameters['t'], expectedToken);
      expect(capturedUri!.queryParameters['u'], 'alice');
      expect(capturedUri!.queryParameters['f'], 'json');
    });

    test('never sends the plaintext password as its own query parameter',
        () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(okBody({}), 200);
        }),
      );

      await plugin.testConnection();

      expect(capturedUri!.queryParameters.values, isNot(contains('hunter2')));
    });
  });

  group('testConnection', () {
    test('hits ping.view and returns true on a real ok response', () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(okBody({}), 200);
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isTrue);
      expect(plugin.lastError, isNull);
      expect(capturedUri!.path, '/rest/ping.view');
    });

    test('returns false with lastError set when not configured', () async {
      final plugin = OpenSubsonicPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, isNotNull);
    });

    test('returns false when the server reports a failure status',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(errorBody('Wrong username or password.'), 200)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, 'Wrong username or password.');
    });

    test('returns false on a non-200 response', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 500)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('500'));
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

    test('returns false for a server URL with no scheme, without ever '
        'calling the network', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(okBody({}), 200);
        }),
        server: 'not a url',
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(called, isFalse);
    });
  });

  group('search', () {
    test('returns an empty list without calling the network for a blank '
        'query', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(okBody({}), 200);
        }),
      );

      final result = await plugin.search('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('parses real search results into playable BaseTracks with a '
        'genuine stream.view URL', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path == '/rest/search3.view') {
            return http.Response(
              okBody({
                'searchResult3': {
                  'song': [song()],
                }
              }),
              200,
            );
          }
          return http.Response(okBody({}), 200);
        }),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'subsonic:s1');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.subsonic);
      expect(track.artists, ['Artist']);
      expect(track.album, 'Album');
      expect(track.genres, ['Rock']);
      expect(track.duration, 210);
      expect(track.trackNumber, 3);
      expect(track.year, 2020);
      expect(track.streamUrl, isNotNull);
      expect(Uri.parse(track.streamUrl!).path, '/rest/stream.view');
      expect(Uri.parse(track.streamUrl!).queryParameters['id'], 's1');
      expect(track.coverArt, isNotNull);
      expect(Uri.parse(track.coverArt!).path, '/rest/getCoverArt.view');
    });

    test('a song with a missing/blank artist or album falls back to '
        '"Unknown Artist"/"Unknown Album" rather than an empty string',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path == '/rest/search3.view') {
            return http.Response(
              okBody({
                'searchResult3': {
                  'song': [song(artist: null, album: '')],
                }
              }),
              200,
            );
          }
          return http.Response(okBody({}), 200);
        }),
      );

      final result = await plugin.search('song one');

      expect(result.single.artists, ['Unknown Artist']);
      expect(result.single.album, 'Unknown Album');
    });

    test('a song with no id or no title is skipped rather than returning '
        'a broken track', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path == '/rest/search3.view') {
            return http.Response(
              okBody({
                'searchResult3': {
                  'song': [
                    {'id': '', 'title': 'No id'},
                    {'id': 's2', 'title': ''},
                    song(id: 'good-1'),
                  ],
                }
              }),
              200,
            );
          }
          return http.Response(okBody({}), 200);
        }),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'subsonic:good-1');
    });

    test('one malformed entry does not wipe the rest of the search '
        'result', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path == '/rest/search3.view') {
            return http.Response(
              okBody({
                'searchResult3': {
                  'song': [
                    {'id': 123, 'title': null}, // garbage entry
                    song(id: 'good-1'),
                  ],
                }
              }),
              200,
            );
          }
          return http.Response(okBody({}), 200);
        }),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'subsonic:good-1');
    });

    test('returns an empty list and sets lastError on a server-reported '
        'failure', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(errorBody('Session expired.'), 200)),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      expect(plugin.lastError, 'Session expired.');
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
    final plugin = OpenSubsonicPlugin();
    expect(plugin.id, 'opensubsonic');
    expect(plugin.usesNetwork, isTrue);
  });
}
