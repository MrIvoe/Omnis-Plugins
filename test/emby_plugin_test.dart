import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/emby_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal `PluginContext` stand-in so a lifecycle test can inspect
/// `IOnlineSearchProvider` registration without the real
/// `OmnisPluginContext` — same pattern `queue_preset_plugin_test.dart`
/// already established for `IQueueBuilder`.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<EmbyPlugin> configuredPlugin({
    required http.Client client,
    String server = 'https://emby.example.com',
    String username = 'alice',
    String password = 'hunter2',
  }) async {
    final plugin = EmbyPlugin(client: client);
    await plugin.setServerUrl(server);
    await plugin.setUsername(username);
    await plugin.setPassword(password);
    return plugin;
  }

  String authOkBody({String token = 'session-token', String userId = 'user-1'}) =>
      jsonEncode({
        'User': {'Id': userId, 'Name': 'alice'},
        'AccessToken': token,
        'ServerId': 'server-1',
      });

  Map<String, dynamic> item({
    String id = 'i1',
    String name = 'Song One',
    List<String>? artists = const ['Artist'],
    String? album = 'Album',
    List<String>? genres = const ['Rock'],
    Object? runTimeTicks = 2100000000, // 210 seconds
    Object? indexNumber = 3,
    Object? productionYear = 2020,
    bool withImage = true,
  }) =>
      {
        'Id': id,
        'Name': name,
        'Artists': artists,
        'Album': album,
        'Genres': genres,
        'RunTimeTicks': runTimeTicks,
        'IndexNumber': indexNumber,
        'ProductionYear': productionYear,
        if (withImage) 'ImageTags': {'Primary': 'tag-1'},
      };

  http.Client routingClient({
    required String authBody,
    int authStatus = 200,
    required Map<String, dynamic> Function(Uri) itemsResponse,
    int itemsStatus = 200,
  }) =>
      MockClient((req) async {
        if (req.url.path.endsWith('/Users/AuthenticateByName')) {
          return http.Response(authBody, authStatus);
        }
        if (req.url.path.endsWith('/Items')) {
          return http.Response(jsonEncode(itemsResponse(req.url)), itemsStatus);
        }
        return http.Response('', 404);
      });

  group('isConfigured', () {
    test('false until server/username/password are all set', () async {
      final plugin = EmbyPlugin(client: MockClient((r) async {
        throw UnimplementedError('should not be called');
      }));
      expect(plugin.isConfigured, isFalse);

      await plugin.setServerUrl('https://emby.example.com');
      expect(plugin.isConfigured, isFalse);

      await plugin.setUsername('alice');
      expect(plugin.isConfigured, isFalse);

      await plugin.setPassword('hunter2');
      expect(plugin.isConfigured, isTrue);
    });
  });

  group('testConnection', () {
    test('posts to AuthenticateByName with the MediaBrowser auth header '
        'and JSON credentials, returns true on success', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      String? capturedBody;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          capturedHeaders = req.headers;
          capturedBody = req.body;
          return http.Response(authOkBody(), 200);
        }),
      );

      final ok = await plugin.testConnection();

      expect(ok, isTrue);
      expect(plugin.lastError, isNull);
      expect(capturedUri!.path, '/Users/AuthenticateByName');
      expect(capturedHeaders!['X-Emby-Authorization'], contains('Client="Omnis"'));
      expect(jsonDecode(capturedBody!),
          {'Username': 'alice', 'Pw': 'hunter2'});
    });

    test('returns false with lastError when not configured', () async {
      final plugin = EmbyPlugin(client: MockClient((r) async {
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
          return http.Response(authOkBody(), 200);
        }),
        server: 'not a url',
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(called, isFalse);
    });

    test('returns false on a non-200 auth response (wrong credentials)',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 401)),
      );

      final ok = await plugin.testConnection();

      expect(ok, isFalse);
      expect(plugin.lastError, contains('401'));
    });

    test('returns false when the response has no AccessToken', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async =>
            http.Response(jsonEncode({'User': null}), 200)),
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
          return http.Response(authOkBody(), 200);
        }),
      );

      final result = await plugin.search('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('authenticates automatically before the first search, then '
        'parses real results into playable BaseTracks', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          authBody: authOkBody(),
          itemsResponse: (uri) => {
            'Items': [item()],
            'TotalRecordCount': 1,
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'emby:i1');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.emby);
      expect(track.artists, ['Artist']);
      expect(track.album, 'Album');
      expect(track.genres, ['Rock']);
      expect(track.duration, 210); // RunTimeTicks / 10,000,000
      expect(track.trackNumber, 3);
      expect(track.year, 2020);
      expect(track.streamUrl, isNotNull);
      final streamUri = Uri.parse(track.streamUrl!);
      expect(streamUri.path, '/Audio/i1/stream');
      expect(streamUri.queryParameters['api_key'], 'session-token');
      expect(track.coverArt, isNotNull);
      expect(Uri.parse(track.coverArt!).path, '/Items/i1/Images/Primary');
    });

    test('sends the search request with the cached session UserId/token, '
        'not re-authenticating on a second search', () async {
      var authCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/Users/AuthenticateByName')) {
            authCalls++;
            return http.Response(authOkBody(), 200);
          }
          return http.Response(
            jsonEncode({'Items': <dynamic>[], 'TotalRecordCount': 0}),
            200,
          );
        }),
      );

      await plugin.search('one');
      await plugin.search('two');

      expect(authCalls, 1);
    });

    test('a track with no artists falls back to "Unknown Artist"; no '
        'album falls back to "Unknown Album"', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          authBody: authOkBody(),
          itemsResponse: (uri) => {
            'Items': [item(artists: const [], album: null)],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.artists, ['Unknown Artist']);
      expect(result.single.album, 'Unknown Album');
    });

    test('a track with no ImageTags.Primary has no coverArt', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          authBody: authOkBody(),
          itemsResponse: (uri) => {
            'Items': [item(withImage: false)],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result.single.coverArt, isNull);
    });

    test('an item with no Id or no Name is skipped rather than returning '
        'a broken track', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          authBody: authOkBody(),
          itemsResponse: (uri) => {
            'Items': [
              {'Id': '', 'Name': 'No id'},
              {'Id': 'i2', 'Name': ''},
              item(id: 'good-1'),
            ],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'emby:good-1');
    });

    test('one malformed entry does not wipe the rest of the search '
        'result', () async {
      final plugin = await configuredPlugin(
        client: routingClient(
          authBody: authOkBody(),
          itemsResponse: (uri) => {
            'Items': [
              {'Id': 123, 'Name': null}, // garbage entry
              item(id: 'good-1'),
            ],
          },
        ),
      );

      final result = await plugin.search('song one');

      expect(result, hasLength(1));
      expect(result.single.id, 'emby:good-1');
    });

    test('re-authenticates exactly once on a 401 mid-search and retries, '
        'not looping forever if the server keeps rejecting', () async {
      var authCalls = 0;
      var itemsCalls = 0;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/Users/AuthenticateByName')) {
            authCalls++;
            return http.Response(authOkBody(), 200);
          }
          itemsCalls++;
          return http.Response('', 401); // always rejects
        }),
      );

      final result = await plugin.search('song one');

      expect(result, isEmpty);
      // One initial attempt (no cached session) + one retry after the
      // first 401 = 2 auth calls, 2 items calls, not an infinite loop.
      expect(authCalls, 2);
      expect(itemsCalls, 2);
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
    final plugin = EmbyPlugin();
    expect(plugin.id, 'emby');
    expect(plugin.usesNetwork, isTrue);
  });

  group('IOnlineSearchProvider lifecycle', () {
    test('providerName matches name', () {
      final plugin = EmbyPlugin();
      expect(plugin.providerName, plugin.name);
    });

    test('initialize registers IOnlineSearchProvider; dispose unregisters '
        'it', () async {
      final plugin = EmbyPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isTrue);
      expect(ctx.servicesRegistry.get<IOnlineSearchProvider>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = EmbyPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IOnlineSearchProvider>(), isTrue);
    });
  });
}
