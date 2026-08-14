import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/plex_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<PlexPlugin> configuredPlugin({
    required http.Client client,
    String server = 'https://plex.example.com:32400',
    String token = 'plex-token-123',
  }) async {
    final plugin = PlexPlugin(client: client);
    await plugin.setServerUrl(server);
    await plugin.setToken(token);
    return plugin;
  }

  String sectionsOkBody() => jsonEncode({
        'MediaContainer': {'size': 1, 'Directory': []},
      });

  Map<String, dynamic> trackMetadata({
    String ratingKey = 't1',
    String title = 'Song One',
    String? grandparentTitle = 'Artist',
    String? parentTitle = 'Album',
    Object? duration = 210000, // milliseconds
    Object? index = 3,
    Object? year = 2020,
    String? thumb = '/library/metadata/t1/thumb/167',
    String? partKey = '/library/parts/98765/167/file.mp3',
  }) =>
      {
        'ratingKey': ratingKey,
        'title': title,
        'type': 'track',
        'grandparentTitle': grandparentTitle,
        'parentTitle': parentTitle,
        'duration': duration,
        'index': index,
        'year': year,
        'thumb': thumb,
        'Media': partKey == null
            ? const []
            : [
                {
                  'Part': [
                    {'key': partKey},
                  ],
                }
              ],
      };

  String searchBody(List<Map<String, dynamic>> metadata) => jsonEncode({
        'MediaContainer': {'size': metadata.length, 'Metadata': metadata},
      });

  http.Client routingClient({
    required Map<String, dynamic> Function(Uri) searchResponse,
  }) =>
      MockClient((req) async {
        if (req.url.path == '/search') {
          return http.Response(jsonEncode(searchResponse(req.url)), 200);
        }
        return http.Response('', 404);
      });

  group('isConfigured', () {
    test('false until server and token are both set', () async {
      final plugin = PlexPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isConfigured, isFalse);

      await plugin.setServerUrl('https://plex.example.com:32400');
      expect(plugin.isConfigured, isFalse);

      await plugin.setToken('plex-token-123');
      expect(plugin.isConfigured, isTrue);
    });
  });

  group('testConnection', () {
    test('hits /library/sections with the X-Plex-Token header and '
        'Accept: application/json, returns true on success', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          capturedHeaders = req.headers;
          return http.Response(sectionsOkBody(), 200);
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isTrue);
      expect(plugin.lastError, isNull);
      expect(capturedUri!.path, '/library/sections');
      expect(capturedHeaders!['X-Plex-Token'], 'plex-token-123');
      expect(capturedHeaders!['Accept'], 'application/json');
    });

    test('returns false with lastError when not configured', () async {
      final plugin = PlexPlugin(client: MockClient((r) async {
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
          return http.Response(sectionsOkBody(), 200);
        }),
        server: 'not a url',
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('returns false with a specific message on a 401 (bad token)',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 401)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('token'));
    });

    test('returns false on any other non-200 response', () async {
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
  });

  group('search', () {
    test('returns an empty list without calling the network for a blank '
        'query', () async {
      var called = false;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          called = true;
          return http.Response(searchBody(const []), 200);
        }),
      );

      final result = await plugin.search('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('parses a real track result into a playable BaseTrack, using '
        'the nested Media[0].Part[0].key for streamUrl', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [trackMetadata()],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'plex:t1');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.plex);
      expect(track.artists, ['Artist']); // from grandparentTitle
      expect(track.album, 'Album'); // from parentTitle
      expect(track.duration, 210); // 210000ms -> 210s
      expect(track.trackNumber, 3);
      expect(track.year, 2020);
      final streamUri = Uri.parse(track.streamUrl!);
      expect(streamUri.path, '/library/parts/98765/167/file.mp3');
      expect(streamUri.queryParameters['X-Plex-Token'], 'plex-token-123');
      final coverUri = Uri.parse(track.coverArt!);
      expect(coverUri.path, '/library/metadata/t1/thumb/167');
      expect(coverUri.queryParameters['X-Plex-Token'], 'plex-token-123');
    });

    test('filters out non-track results (albums, artists, movies, ...) '
        'from the mixed /search response', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': 'a1', 'title': 'Some Album', 'type': 'album'},
                {'ratingKey': 'ar1', 'title': 'Some Artist', 'type': 'artist'},
                {'ratingKey': 'm1', 'title': 'Some Movie', 'type': 'movie'},
                trackMetadata(ratingKey: 'good-1'),
              ],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'plex:good-1');
    });

    test('a track with no artist/album falls back to "Unknown Artist"/'
        '"Unknown Album"', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [
                trackMetadata(grandparentTitle: null, parentTitle: ''),
              ],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.artists, ['Unknown Artist']);
      expect(result.single.album, 'Unknown Album');
    });

    test('a track with no thumb has no coverArt', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [trackMetadata(thumb: null)],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.coverArt, isNull);
    });

    test('a "track" entry with no Media/Part (no playable file) is '
        'skipped rather than returning a broken track', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [
                trackMetadata(ratingKey: 'no-file', partKey: null),
                trackMetadata(ratingKey: 'good-1'),
              ],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'plex:good-1');
    });

    test('one malformed entry does not wipe the rest of the search '
        'result', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [
                {'ratingKey': 123, 'title': null, 'type': 'track'},
                trackMetadata(ratingKey: 'good-1'),
              ],
            },
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'plex:good-1');
    });

    test('respects the limit parameter', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          searchResponse: (uri) => {
            'MediaContainer': {
              'Metadata': [
                for (var i = 0; i < 5; i++) trackMetadata(ratingKey: 't$i'),
              ],
            },
          },
        ),
      );

      final result = await plugin.search('song', limit: 2);

      expect(result, hasLength(2));
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

    test('returns an empty list on a non-200 response', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 500)),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      expect(plugin.lastError, contains('500'));
    });
  });

  test('plugin metadata is well-formed', () {
    final plugin = PlexPlugin();
    expect(plugin.id, 'plex');
    expect(plugin.usesNetwork, isTrue);
  });
}
