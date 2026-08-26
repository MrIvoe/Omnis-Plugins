import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/event_bus.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/ampache_plugin.dart';
import 'package:omnis_plugins/custom_radio_station_store.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:omnis_plugins/online_page.dart';
import 'package:omnis_plugins/radio_plugin.dart';
import 'package:omnis_plugins/spotify_playback_plugin.dart';
import 'package:omnis_plugins/youtube_playback_plugin.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;
}

/// Only `services`/`events`/`currentTrack`/`setQueue`/`play` are stubbed —
/// the only [PluginContext] members [OnlinePage]/`RadioBody` and the
/// plugins registered against it in these tests actually touch, the same
/// "stub only what's used" shape `moods_plugin_test.dart`'s own
/// `_FakeContext` already establishes. `events` needs a real [EventBus] —
/// unlike every other unused member here, `FavoritesPlugin.setFavorite`
/// (exercised by the favoriting tests below) unconditionally emits
/// through it, so `noSuchMethod`'s "not stubbed" throw isn't an option for
/// this one member. `_current` is a private field, not a real setter, so
/// a test pre-seeds it the same `.._current = ...` cascade
/// `radio_page_test.dart`/`online_page_test.dart`'s pre-move `_FakeEngine`
/// used — same-library access, since this class lives in this test file.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();
  final EventBus eventBus = EventBus();
  List<BaseTrack>? lastQueue;
  int? lastStartIndex;
  bool playCalled = false;
  BaseTrack? _current;

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  EventBus get events => eventBus;

  @override
  BaseTrack? get currentTrack => _current;

  @override
  Future<void> setQueue(List<BaseTrack> tracks, {int startIndex = 0}) async {
    lastQueue = tracks;
    lastStartIndex = startIndex;
    _current = tracks.isNotEmpty ? tracks[startIndex] : null;
  }

  @override
  Future<void> play() async => playCalled = true;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// Same reasoning as this session's other page tests: `CustomRadioStationStore`
/// reads/writes a real (fake-path-provider-backed) file — real dart:io —
/// so a plain `pump()` inside the fake-async test zone never gives that a
/// chance to actually finish, even inside `tester.runAsync()`. An explicit
/// real delay between two pumps does.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
}

/// `attach`es [plugin] to [ctx] and runs its real `initialize()` — the
/// only way a plugin registers itself under a `ServiceRegistry` interface
/// (`IRadioProvider`/`IFavoritesProvider`/`IOnlineSearchProvider`/
/// `IEmbeddedPlaybackProvider`), now that there's no `PluginManager`
/// available to a bundled-plugin-only test (that type is Omnis-app-only).
Future<void> _register(_FakeContext ctx, MusicPlugin plugin) async {
  plugin.attach(ctx);
  await plugin.initialize();
}

Map<String, dynamic> _station(String uuid, String name) => {
      'stationuuid': uuid,
      'name': name,
      'url_resolved': 'https://stream.example.com/$uuid.mp3',
      'url': null,
      'country': 'Testland',
      'tags': 'test',
      'codec': 'mp3',
      'bitrate': 128,
      'favicon': null,
    };

/// A minimal Ampache mock server: any `action=handshake` succeeds with a
/// fixed session token; any `action=songs` returns exactly one song
/// matching the request's `filter`.
http.Client _ampacheClient() => MockClient((req) async {
      final action = req.url.queryParameters['action'];
      if (action == 'handshake') {
        return http.Response(
          jsonEncode({
            'auth': 'session-token',
            'session_expire': '2099-01-01T00:00:00+00:00',
            'api': '6.6.1',
            'username': 'alice',
          }),
          200,
        );
      }
      if (action == 'songs') {
        return http.Response(
          jsonEncode({
            'song': [
              {
                'id': 's1',
                'title': 'Found Song',
                'artist': {'id': 'a1', 'name': 'Found Artist'},
                'album': {'id': 'al1', 'name': 'Album'},
                'genre': [],
                'track': 1,
                'time': 200,
                'url':
                    'https://ampache.example.com/play/s1?auth=session-token',
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 404);
    });

Future<AmpachePlugin> _configuredAmpache(http.Client client) async {
  final plugin = AmpachePlugin(client: client);
  await plugin.setServerUrl('https://ampache.example.com');
  await plugin.setUsername('alice');
  await plugin.setPassword('hunter2');
  return plugin;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Backs `SpotifyAuth.warmUp()` (called from `SpotifyPlaybackPlugin
    // .initialize()`) — without this, secure-storage reads hit a real
    // platform channel with no implementation registered in the test
    // process. Same setup `spotify_plugins_test.dart` (Omnis app repo)
    // already establishes for the identical `SpotifyAuth` dependency.
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    final tempDir =
        (await Directory.systemTemp.createTemp('omnis_online_page_test'))
            .path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    await CustomRadioStationStore.instance.save([]);
  });

  group('Radio section (RadioBody, merged into this page — Tier 2 task 5)',
      () {
    testWidgets('shows a disabled message when no Radio plugin is '
        'registered', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: OnlinePage(pluginContext: _FakeContext()),
      ));
      await tester.pump();

      expect(
        find.text('The Internet Radio plugin is disabled in Settings.'),
        findsOneWidget,
      );
    });

    testWidgets('loads top stations on open and renders them', (tester) async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([_station('a', 'Alpha FM'), _station('b', 'Beta FM')]),
          200,
        );
      });
      final ctx = _FakeContext();
      await _register(ctx, RadioPlugin(client: client));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();
      await tester.pump();

      expect(find.text('Top stations'), findsOneWidget);
      expect(find.text('Alpha FM'), findsOneWidget);
      expect(find.text('Beta FM'), findsOneWidget);
    });

    testWidgets(
        'Task 10 Step 1: the "now playing" marker on a top-station tile uses '
        'the app theme\'s primary color, not a hardcoded purple',
        (tester) async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([_station('a', 'Alpha FM'), _station('b', 'Beta FM')]),
          200,
        );
      });
      final ctx = _FakeContext();
      await _register(ctx, RadioPlugin(client: client));
      // RadioPlugin.search/topStations prefixes each result's `stationuuid`
      // ('a', per `_station` above) with 'radio:' when building its
      // BaseTrack — pre-seeding this id as already-current means the first
      // build after stations load renders the "Alpha FM" tile as playing.
      ctx._current = BaseTrack(
        id: 'radio:a',
        title: 'Alpha FM',
        artists: const [],
        album: '',
        duration: 0,
        type: TrackType.radio,
      );
      const themePrimary = Color(0xFF00A876);

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: themePrimary)
              .copyWith(primary: themePrimary),
        ),
        home: OnlinePage(pluginContext: ctx),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('Alpha FM'), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.graphic_eq));
      expect(icon.color, themePrimary);
      expect(icon.color, isNot(Colors.deepPurple));
    });

    testWidgets('an empty top-stations result shows the empty state, not a '
        'blank screen', (tester) async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode([]), 200);
      });
      final ctx = _FakeContext();
      await _register(ctx, RadioPlugin(client: client));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();
      await tester.pump();

      expect(find.text('No stations available right now.'), findsOneWidget);
    });

    testWidgets('searching replaces the list with results and switches the '
        'section label', (tester) async {
      Uri? lastUri;
      final client = MockClient((req) async {
        lastUri = req.url;
        if (req.url.path.contains('search')) {
          return http.Response(jsonEncode([_station('j1', 'Jazz Station')]), 200);
        }
        return http.Response(jsonEncode([_station('t1', 'Top Station')]), 200);
      });
      final ctx = _FakeContext();
      await _register(ctx, RadioPlugin(client: client));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();
      await tester.pump();
      expect(find.text('Top Station'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'jazz');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();

      expect(lastUri!.queryParameters['name'], 'jazz');
      expect(find.text('Search results'), findsOneWidget);
      expect(find.text('Jazz Station'), findsOneWidget);
      expect(find.text('Top Station'), findsNothing);
    });

    testWidgets('tapping a station sets it as the queue start index and '
        'plays', (tester) async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([_station('a', 'Alpha FM'), _station('b', 'Beta FM')]),
          200,
        );
      });
      final ctx = _FakeContext();
      await _register(ctx, RadioPlugin(client: client));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Beta FM'));
      await tester.pump();

      expect(ctx.lastStartIndex, 1);
      expect(ctx.lastQueue?[1].title, 'Beta FM');
      expect(ctx.lastQueue?[1].type, TrackType.radio);
      expect(ctx.playCalled, isTrue);
    });

    group('favoriting a station (item 41)', () {
      testWidgets(
          'tapping the favorite icon marks a station favorited and fills '
          'the heart', (tester) async {
        final client = MockClient((req) async {
          return http.Response(
            jsonEncode([_station('a', 'Alpha FM'), _station('b', 'Beta FM')]),
            200,
          );
        });
        final ctx = _FakeContext();
        await _register(ctx, RadioPlugin(client: client));
        final favorites = FavoritesPlugin();
        await _register(ctx, favorites);

        await tester
            .pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await tester.pump();
        await tester.pump();

        expect(find.byIcon(Icons.favorite_border), findsNWidgets(2));
        expect(find.byIcon(Icons.favorite), findsNothing);

        await tester.tap(find.byIcon(Icons.favorite_border).first);
        await tester.pump();

        expect(find.byIcon(Icons.favorite), findsOneWidget);
        expect(find.byIcon(Icons.favorite_border), findsOneWidget);
        expect(favorites.isFavorite('radio:a'), isTrue);
      });

      testWidgets('tapping the favorite icon again un-favorites the station',
          (tester) async {
        final client = MockClient((req) async {
          return http.Response(jsonEncode([_station('a', 'Alpha FM')]), 200);
        });
        final ctx = _FakeContext();
        await _register(ctx, RadioPlugin(client: client));
        final favorites = FavoritesPlugin();
        await _register(ctx, favorites);

        await tester
            .pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byIcon(Icons.favorite_border));
        await tester.pump();
        expect(favorites.isFavorite('radio:a'), isTrue);

        await tester.tap(find.byIcon(Icons.favorite));
        await tester.pump();

        expect(find.byIcon(Icons.favorite), findsNothing);
        expect(favorites.isFavorite('radio:a'), isFalse);
      });

      testWidgets(
          'tapping the favorite icon with the Favorites plugin disabled '
          'shows a message instead of crashing', (tester) async {
        final client = MockClient((req) async {
          return http.Response(jsonEncode([_station('a', 'Alpha FM')]), 200);
        });
        final ctx = _FakeContext();
        await _register(ctx, RadioPlugin(client: client));
        // Favorites deliberately not registered — same shape as it being
        // disabled in Settings, since `services.get<IFavoritesProvider>()`
        // only ever sees a registered-and-initialized plugin.

        await tester
            .pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byIcon(Icons.favorite_border));
        await tester.pump();

        expect(find.text('No favorites provider is installed/enabled.'),
            findsOneWidget);
      });
    });

    group('Custom radio stations (item 41)', () {
      Future<void> pumpNoStations(WidgetTester tester, _FakeContext ctx) async {
        final client = MockClient((req) async => http.Response(jsonEncode([]), 200));
        await _register(ctx, RadioPlugin(client: client));
        await _register(ctx, FavoritesPlugin());
        await tester
            .pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await _settle(tester);
      }

      testWidgets('a previously-saved custom station appears under "My '
          'stations" on open', (tester) async {
        await tester.runAsync(() async {
          await CustomRadioStationStore.instance
              .add('My Jazz Station', 'https://stream.example.com/jazz');

          await pumpNoStations(tester, _FakeContext());

          expect(find.text('My stations'), findsOneWidget);
          expect(find.text('My Jazz Station'), findsOneWidget);
        });
      });

      testWidgets(
          'adding a station via the dialog persists it and shows it in '
          'the list', (tester) async {
        await tester.runAsync(() async {
          await pumpNoStations(tester, _FakeContext());
          expect(find.text('My stations'), findsNothing);

          await tester.tap(find.byTooltip('Add station'));
          await _settle(tester);
          await tester.enterText(
              find.widgetWithText(TextField, 'Station name'), 'Deep House FM');
          await tester.enterText(find.widgetWithText(TextField, 'Stream URL'),
              'https://stream.example.com/deephouse');
          await tester.tap(find.text('Add'));
          await _settle(tester);

          expect(find.text('Deep House FM'), findsOneWidget);
          final saved = await CustomRadioStationStore.instance.load();
          expect(saved.single.name, 'Deep House FM');
        });
      });

      testWidgets(
          'adding a station with an invalid URL shows a message and does '
          'not persist anything', (tester) async {
        await tester.runAsync(() async {
          await pumpNoStations(tester, _FakeContext());

          await tester.tap(find.byTooltip('Add station'));
          await _settle(tester);
          await tester.enterText(
              find.widgetWithText(TextField, 'Station name'), 'Bad Station');
          await tester.enterText(
              find.widgetWithText(TextField, 'Stream URL'), 'not a url');
          await tester.tap(find.text('Add'));
          await _settle(tester);

          expect(
            find.textContaining('Enter a station name and a valid'),
            findsOneWidget,
          );
          expect(await CustomRadioStationStore.instance.load(), isEmpty);
        });
      });

      testWidgets('tapping a custom station queues just that station and '
          'plays it', (tester) async {
        await tester.runAsync(() async {
          await CustomRadioStationStore.instance
              .add('My Jazz Station', 'https://stream.example.com/jazz');
          final ctx = _FakeContext();

          await pumpNoStations(tester, ctx);

          await tester.tap(find.text('My Jazz Station'));
          await _settle(tester);

          expect(ctx.lastQueue, hasLength(1));
          expect(ctx.lastQueue!.single.title, 'My Jazz Station');
          expect(ctx.lastQueue!.single.streamUrl,
              'https://stream.example.com/jazz');
          expect(ctx.playCalled, isTrue);
        });
      });

      testWidgets(
          'Task 10 Step 1: the "now playing" marker on a custom-station tile '
          'uses the app theme\'s primary color, not a hardcoded purple',
          (tester) async {
        await tester.runAsync(() async {
          final saved = await CustomRadioStationStore.instance
              .add('My Jazz Station', 'https://stream.example.com/jazz');
          final ctx = _FakeContext();
          // Pre-seed the fake context's currentTrack with the *actual*
          // persisted station's own BaseTrack (its id is a
          // timestamp-derived value assigned by `.add`, not something this
          // test can predict — reading it back off the store instead of
          // hardcoding a guess) so the tile renders as playing on first
          // build, no tap-driven rebuild required.
          ctx._current = saved.single.toTrack();
          const themePrimary = Color(0xFF00A876);

          final client =
              MockClient((req) async => http.Response(jsonEncode([]), 200));
          await _register(ctx, RadioPlugin(client: client));
          await _register(ctx, FavoritesPlugin());

          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: themePrimary)
                  .copyWith(primary: themePrimary),
            ),
            home: OnlinePage(pluginContext: ctx),
          ));
          await _settle(tester);

          expect(find.text('My Jazz Station'), findsOneWidget);
          final icon = tester.widget<Icon>(find.byIcon(Icons.graphic_eq));
          expect(icon.color, themePrimary);
          expect(icon.color, isNot(Colors.deepPurple));
        });
      });

      testWidgets('deleting a custom station removes it from the list and '
          'from persistence', (tester) async {
        await tester.runAsync(() async {
          await CustomRadioStationStore.instance
              .add('My Jazz Station', 'https://stream.example.com/jazz');

          await pumpNoStations(tester, _FakeContext());
          expect(find.text('My Jazz Station'), findsOneWidget);

          await tester.tap(find.byTooltip('Remove station'));
          await _settle(tester);

          expect(find.text('My Jazz Station'), findsNothing);
          expect(await CustomRadioStationStore.instance.load(), isEmpty);
        });
      });
    });
  });

  group('Online tab: sections/chips', () {
    testWidgets('with nothing else registered, only the Radio chip is shown',
        (tester) async {
      final ctx = _FakeContext();

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();

      expect(find.widgetWithText(ChoiceChip, 'Radio'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsOneWidget);
      expect(find.byTooltip('Add station'), findsOneWidget);
    });

    testWidgets(
        'the "Add station" action only shows while the Radio chip is '
        'selected', (tester) async {
      final ctx = _FakeContext();
      await _register(ctx, await _configuredAmpache(_ampacheClient()));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();

      expect(find.byTooltip('Add station'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Ampache'));
      await tester.pump();

      expect(find.byTooltip('Add station'), findsNothing);
    });

    testWidgets(
        'a configured search-provider plugin appears as its own chip, '
        'searching shows results, and tapping one plays it', (tester) async {
      final ctx = _FakeContext();
      await _register(ctx, await _configuredAmpache(_ampacheClient()));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();

      expect(find.widgetWithText(ChoiceChip, 'Ampache'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Ampache'));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'found');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();

      expect(find.text('Found Song'), findsOneWidget);

      await tester.tap(find.text('Found Song'));
      await tester.pump();

      expect(ctx.lastQueue?.single.title, 'Found Song');
      expect(ctx.playCalled, isTrue);
    });

    testWidgets(
        'an unconfigured search-provider plugin does not get a chip at all',
        (tester) async {
      final ctx = _FakeContext();
      await _register(ctx, AmpachePlugin(client: _ampacheClient()));

      await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
      await tester.pump();

      expect(find.widgetWithText(ChoiceChip, 'Ampache'), findsNothing);
      expect(find.byType(ChoiceChip), findsOneWidget);
    });

    testWidgets(
        'an enabled YoutubePlaybackPlugin adds a YouTube chip whose content '
        'is the real embedded-player widget', (tester) async {
      // `_settle`'s real `Future.delayed` needs the real (non-fake-async)
      // zone `runAsync` provides.
      await tester.runAsync(() async {
        final ctx = _FakeContext();
        await _register(ctx, YoutubePlaybackPlugin());

        await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await _settle(tester);

        expect(find.widgetWithText(ChoiceChip, 'YouTube'), findsOneWidget);

        await tester.tap(find.widgetWithText(ChoiceChip, 'YouTube'));
        await _settle(tester);

        // The embedded player needs a WebView, which Flutter only supports
        // on Android/iOS/web — this suite runs on Windows (this project's
        // CI/dev platform), so the widget's own honest "not available on
        // this platform" branch is what actually renders here. Whichever
        // branch fires, either message proves the real
        // YoutubePlaybackPlugin.uiSlot('plugin_settings') widget rendered
        // as this tab's content, not a blank/crashed page.
        expect(
          YoutubePlaybackPlugin.isSupportedOnThisPlatform
              ? find.textContaining('Paste a YouTube video URL or id')
              : find.textContaining('needs a WebView'),
          findsOneWidget,
        );
      });
    });

    testWidgets(
        'an enabled SpotifyPlaybackPlugin adds a Spotify chip whose content '
        'is the real Connect remote-control widget', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakeContext();
        await _register(ctx, SpotifyPlaybackPlugin());

        await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await _settle(tester);

        expect(find.widgetWithText(ChoiceChip, 'Spotify'), findsOneWidget);

        await tester.tap(find.widgetWithText(ChoiceChip, 'Spotify'));
        await _settle(tester);

        // Not connected yet — the plugin's own settings widget should show
        // some form of connect prompt rather than a blank/crashed page.
        expect(find.byType(ChoiceChip), findsNWidgets(2));
      });
    });

    testWidgets(
        'a disabled YoutubePlaybackPlugin does not add a YouTube chip',
        (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakeContext();
        final youtube = YoutubePlaybackPlugin();
        await _register(ctx, youtube);
        // "Disabled" is simulated the same way `PluginManager.disablePlugin`
        // drives it in the real app: call the plugin's own `disable()` hook,
        // which unregisters it from `IEmbeddedPlaybackProvider` — the "ask
        // the registry, not a plugin's own enabled flag" pattern this whole
        // page is built on.
        await youtube.disable();

        await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await _settle(tester);

        // Only the Radio chip should be present, no YouTube chip
        expect(find.widgetWithText(ChoiceChip, 'YouTube'), findsNothing);
        expect(find.widgetWithText(ChoiceChip, 'Radio'), findsOneWidget);
        expect(find.byType(ChoiceChip), findsOneWidget);
      });
    });

    testWidgets(
        'a disabled SpotifyPlaybackPlugin does not add a Spotify chip',
        (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakeContext();
        final spotify = SpotifyPlaybackPlugin();
        await _register(ctx, spotify);
        await spotify.disable();

        await tester.pumpWidget(MaterialApp(home: OnlinePage(pluginContext: ctx)));
        await _settle(tester);

        // Only the Radio chip should be present, no Spotify chip
        expect(find.widgetWithText(ChoiceChip, 'Spotify'), findsNothing);
        expect(find.widgetWithText(ChoiceChip, 'Radio'), findsOneWidget);
        expect(find.byType(ChoiceChip), findsOneWidget);
      });
    });
  });
}
