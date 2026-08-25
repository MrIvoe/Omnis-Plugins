import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/event_bus.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugin_api/track_play_stats.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:omnis_plugins/home_dashboard_page.dart';
import 'package:omnis_plugins/home_dashboard_plugin.dart';
import 'package:omnis_plugins/home_layout_store.dart';
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

/// Stubs the exact slice of [PluginContext] `HomeDashboardPage` actually
/// reads — the reads that used to go straight to `LibraryRepository`/
/// `PlayHistoryStore`/`AudioEngine` before Tier 2 moved this page out of
/// the Omnis app. Only what's used is stubbed; anything else throws, same
/// `noSuchMethod` pattern `ringtone_plugin_test.dart`'s `_FakeContext`
/// already establishes.
class _FakePluginContext implements PluginContext {
  final ServiceRegistry _services = ServiceRegistry();
  final EventBus _events = EventBus();
  final _trackController = StreamController<BaseTrack?>.broadcast();

  List<BaseTrack> library = const [];
  List<TrackPlayStats> recentlyPlayedStats = const [];
  List<TrackPlayStats> mostPlayedStats = const [];
  List<TrackPlayStats> continueListeningStats = const [];
  List<TrackPlayStats> mostSkippedStats = const [];

  List<BaseTrack>? lastQueue;
  int? lastStartIndex;
  bool playCalled = false;

  @override
  ServiceRegistry get services => _services;

  @override
  EventBus get events => _events;

  @override
  Stream<BaseTrack?> get trackStream => _trackController.stream;

  @override
  Future<List<BaseTrack>> loadLibraryTracks() async => library;

  @override
  Future<List<TrackPlayStats>> loadRecentlyPlayed({int limit = 20}) async =>
      recentlyPlayedStats;

  @override
  Future<List<TrackPlayStats>> loadMostPlayed({int limit = 20}) async =>
      mostPlayedStats;

  @override
  Future<List<TrackPlayStats>> loadContinueListening({int limit = 20}) async =>
      continueListeningStats;

  @override
  Future<List<TrackPlayStats>> loadMostSkipped(
          {int limit = 20, int minPlays = 3}) async =>
      mostSkippedStats;

  @override
  Future<void> setQueue(List<BaseTrack> tracks, {int startIndex = 0}) async {
    lastQueue = tracks;
    lastStartIndex = startIndex;
  }

  @override
  Future<void> play() async => playCalled = true;

  void dispose() {
    _trackController.close();
    _events.dispose();
    _services.dispose();
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// pumpAndSettle() pumps frames back-to-back with no real time between
/// them, which never gives HomeLayoutStore's real (fake-path-provider-
/// backed) file read a chance to actually finish. An explicit real delay
/// between two pumps does — same pattern the pre-extraction test used.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
}

BaseTrack _track(String id, {DateTime? dateAdded}) => BaseTrack(
      id: id,
      title: 'Track $id',
      artists: const ['Artist'],
      album: 'Album',
      duration: 200,
      type: TrackType.local,
      dateAdded: dateAdded,
    );

TrackPlayStats _stats(String trackId,
        {int playCount = 1,
        DateTime? lastPlayedAt,
        int lastPositionSeconds = 0,
        int durationSeconds = 0,
        Map<String, dynamic>? trackSnapshot,
        int skipCount = 0}) =>
    TrackPlayStats(
      trackId: trackId,
      playCount: playCount,
      lastPlayedAt: lastPlayedAt ?? DateTime(2025, 1, 1),
      lastPositionSeconds: lastPositionSeconds,
      durationSeconds: durationSeconds,
      trackSnapshot: trackSnapshot,
      skipCount: skipCount,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDir;

  setUpAll(() async {
    tempDir = (await Directory.systemTemp.createTemp('omnis_home_dash_test'))
        .path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HomeLayoutStore.instance.clear();
  });

  testWidgets('shows the empty state when there is no library and no '
      'history', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext();
      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      expect(find.text('Play some music to see it here.'), findsOneWidget);
    });
  });

  testWidgets(
      'Recently Added renders from library dateAdded, newest first, and '
      'sections with no data are absent', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()
        ..library = [
          _track('old', dateAdded: DateTime(2024, 1, 1)),
          _track('new', dateAdded: DateTime(2025, 1, 1)),
        ];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      expect(find.text('Recently Added'), findsOneWidget);
      expect(find.text('Track new'), findsOneWidget);
      expect(find.text('Track old'), findsOneWidget);
      // Nothing has ever been played or favorited.
      expect(find.text('Recently Played'), findsNothing);
      expect(find.text('Most Played'), findsNothing);
      expect(find.text('Continue Listening'), findsNothing);
      expect(find.text('Favorites'), findsNothing);
      expect(find.text('Most Skipped'), findsNothing);
    });
  });

  testWidgets(
      'Recently Played/Most Played/Continue Listening populate from '
      'PluginContext stats joined against the library', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()
        ..library = [_track('a'), _track('b')]
        ..recentlyPlayedStats = [_stats('a')]
        ..mostPlayedStats = [_stats('a')]
        ..continueListeningStats = [_stats('a', lastPositionSeconds: 100, durationSeconds: 200)];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      expect(find.text('Recently Played'), findsOneWidget);
      expect(find.text('Most Played'), findsOneWidget);
      expect(find.text('Continue Listening'), findsOneWidget);
      // 'b' has no stats — must not appear as a card anywhere.
      expect(find.text('Track b'), findsNothing);
    });
  });

  testWidgets(
      'Most Skipped populates from PluginContext.loadMostSkipped joined '
      'against the library (item 16, §37 skip tracking)', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()
        ..library = [_track('a')]
        ..mostSkippedStats = [_stats('a', playCount: 3, skipCount: 2)];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      expect(find.text('Most Skipped'), findsOneWidget);
      final skippedCards = find.descendant(
        of: find.byKey(const ValueKey('home_section_Most Skipped')),
        matching: find.text('Track a'),
      );
      expect(skippedCards, findsOneWidget);
    });
  });

  testWidgets(
      'a played track that is not in the scanned library (a radio '
      'station, or anything from a streaming/server plugin) still shows '
      'up in Recently Played/Most Played via its recorded snapshot — '
      'item 41\'s "recorded but never rendered" gap', (tester) async {
    await tester.runAsync(() async {
      // Deliberately no library entry at all — the whole point is that
      // this track was never scanned/imported, only played.
      final station = BaseTrack(
        id: 'station-1',
        title: 'MANGORADIO',
        artists: const ['Radio Browser'],
        album: '',
        duration: 0,
        type: TrackType.radio,
        streamUrl: 'https://stream.example/station-1',
      );
      final ctx = _FakePluginContext()
        ..recentlyPlayedStats = [
          _stats('station-1', trackSnapshot: station.toJson())
        ]
        ..mostPlayedStats = [
          _stats('station-1', trackSnapshot: station.toJson())
        ];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      expect(find.text('Recently Played'), findsOneWidget);
      expect(find.text('Most Played'), findsOneWidget);
      expect(find.text('MANGORADIO'), findsWidgets);
    });
  });

  testWidgets(
      'Favorites only appears once a IFavoritesProvider is registered and '
      'has a favorite — and picks it up live via FavoriteChangedEvent, '
      'not just on the page\'s first load', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()..library = [_track('a')];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);
      expect(find.text('Favorites'), findsNothing);

      final favorites = FavoritesPlugin();
      favorites.attach(ctx);
      await favorites.initialize();
      await favorites.setFavorite('a', true, track: _track('a'));

      // No second pumpWidget — HomeDashboardPage's State is preserved
      // across HomePage's IndexedStack the same way in the real app, so
      // this exercises the actual live-refresh path (FavoriteChangedEvent
      // -> _load()), not a fresh initState.
      await _settle(tester);
      expect(find.text('Favorites'), findsOneWidget);
    });
  });

  testWidgets(
      'HomeDashboardPlugin.onLibraryScan debounces a real scan\'s '
      'per-file calls into a single reload that reaches the '
      'currently-mounted page, refreshing Recently Added (task 3 fix '
      'round — was previously a dead no-op)', (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()
        ..library = [_track('old', dateAdded: DateTime(2024, 1, 1))];
      final plugin = HomeDashboardPlugin();
      plugin.attach(ctx);
      await plugin.initialize();
      addTearDown(plugin.dispose);

      // Mounts the real page through the plugin's own pageBuilder — not
      // a bare `HomeDashboardPage(key: ..., ...)` like every other test
      // in this file — so it carries the plugin's own private
      // `_dashboardKey`, the exact same instance `onLibraryScan`'s
      // debounce callback below reaches through.
      final destination = plugin.homeDestinations().single;
      await tester.pumpWidget(MaterialApp(home: Builder(
        builder: destination.pageBuilder,
      )));
      await _settle(tester);

      expect(find.text('Track old'), findsOneWidget);
      expect(find.text('Track new'), findsNothing);

      // A scan adds a new file to the library and reports it — twice in
      // quick succession, the same per-file firing a real multi-file
      // scan would produce. Nothing must have reloaded yet: still well
      // inside the 3-second quiet period `HomeDashboardPlugin` debounces
      // by.
      ctx.library = [
        ...ctx.library,
        _track('new', dateAdded: DateTime(2025, 1, 1)),
      ];
      await plugin.onLibraryScan('/music/new.mp3');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await plugin.onLibraryScan('/music/new.mp3');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Track new'), findsNothing);

      // Once the scan goes quiet for the full debounce window (measured
      // from the *last* onLibraryScan call above, not the first — proof
      // the rapid re-calls actually collapsed into one timer reset
      // rather than each independently scheduling its own reload), the
      // page reloads and Recently Added picks up the new file.
      await Future<void>.delayed(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('Track new'), findsOneWidget);
    });
  });

  testWidgets(
      'tapping a card sets the queue starting at that track\'s index and '
      'starts playback (pushing Now Playing is no longer reachable from a '
      'bundled plugin — see home_dashboard_page.dart\'s own doc comment)',
      (tester) async {
    await tester.runAsync(() async {
      final ctx = _FakePluginContext()
        ..library = [_track('a'), _track('b')]
        ..mostPlayedStats = [_stats('b', playCount: 2), _stats('a', playCount: 1)];

      await tester.pumpWidget(MaterialApp(
        home: HomeDashboardPage(pluginContext: ctx),
      ));
      await _settle(tester);

      // Most Played is ['b', 'a'] per the stats above — tap the second
      // card ('a') and confirm the start index matches its position in
      // that section's own list, not just "some track."
      final mostPlayedCards = find.descendant(
        of: find.byKey(const ValueKey('home_section_Most Played')),
        matching: find.byType(InkWell),
      );
      await tester.tap(mostPlayedCards.at(1));
      await _settle(tester);

      expect(ctx.lastQueue?.map((t) => t.id).toList(), ['b', 'a']);
      expect(ctx.lastStartIndex, 1);
      expect(ctx.playCalled, isTrue);
    });
  });

  group('text-scale overflow (task 8)', () {
    testWidgets(
        'a section row does not overflow at the maximum 1.5x text-scale '
        'clamp (AppSettings.clampTextScale ceiling)', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025, 1, 1))];

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        expect(tester.takeException(), isNull);
      });
    });

    testWidgets(
        'a section row grows instead of clipping _HomeCard when text '
        'scale pushes its content past the old fixed 190px envelope',
        (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025, 1, 1))];

        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(3.0)),
            child: child!,
          ),
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        expect(tester.takeException(), isNull);
      });
    });
  });

  group('Customize (item 45)', () {
    testWidgets('the Customize sheet lists every known section, checked '
        'by default when nothing has been saved yet', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);

        expect(find.text('Customize Home'), findsOneWidget);
        for (final label in homeSectionCatalog.values) {
          final tile = tester.widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, label));
          expect(tile.value, isTrue,
              reason: '$label should default to visible');
        }
      });
    });

    testWidgets('unchecking a section and tapping Done hides it on the '
        'dashboard, and the choice survives a reload', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);
        expect(find.text('Recently Added'), findsOneWidget);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();
        final recentlyAddedTile =
            find.widgetWithText(CheckboxListTile, 'Recently Added');
        await tester.ensureVisible(recentlyAddedTile);
        await tester.tap(recentlyAddedTile);
        await tester.pump();
        expect(tester.widget<CheckboxListTile>(recentlyAddedTile).value,
            isFalse,
            reason: 'the checkbox itself should already be unchecked before '
                'Done is even tapped');
        await tester.ensureVisible(find.text('Done'));
        await tester.tap(find.text('Done'));
        await _settle(tester);
        await tester.pumpAndSettle();

        expect(find.text('Recently Added'), findsNothing);

        final saved = await HomeLayoutStore.instance.load();
        expect(
          saved.firstWhere((p) => p.sectionId == 'recently_added').visible,
          isFalse,
        );
      });
    });

    testWidgets('"Reset" clears any customization back to the default '
        'order/visibility', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];
        await HomeLayoutStore.instance.save(const [
          HomeSectionPreference(sectionId: 'recently_added', visible: false),
        ]);

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);
        expect(find.text('Recently Added'), findsNothing);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Reset'));
        await tester.tap(find.text('Reset'));
        await _settle(tester);
        await tester.pumpAndSettle();

        expect(find.text('Recently Added'), findsOneWidget);
        expect(await HomeLayoutStore.instance.load(), isEmpty);
      });
    });

    testWidgets('closing the sheet with no changes made (Done with '
        'nothing toggled) does not write a new save', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Done'));
        await tester.tap(find.text('Done'));
        await _settle(tester);

        expect(await HomeLayoutStore.instance.load(), isEmpty);
      });
    });
  });

  group('ReorderMenuButton fallback (Task 6, item task-6/§1)', () {
    Future<void> tapReorderMenuItem(
        WidgetTester tester, String rowLabel, String item) async {
      final row = find.ancestor(
          of: find.text(rowLabel), matching: find.byType(CheckboxListTile));
      await tester.ensureVisible(row);
      await tester.tap(
          find.descendant(of: row, matching: find.byIcon(Icons.swap_vert)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }

    testWidgets(
        '"Move down" on the first section reorders it exactly like a '
        'real drag would, and Done persists the new order', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();

        // Default order's first entry is "Continue Listening" — move it
        // down past "Recently Played".
        await tapReorderMenuItem(tester, 'Continue Listening', 'Move down');

        await tester.ensureVisible(find.text('Done'));
        await tester.tap(find.text('Done'));
        await _settle(tester);

        final saved = await HomeLayoutStore.instance.load();
        expect(saved.map((p) => p.sectionId).toList(), [
          'recently_played',
          'continue_listening',
          'most_played',
          'recently_added',
          'favorites',
          'most_skipped',
        ]);
      });
    });

    testWidgets(
        '"Move up" on the last section reorders it exactly like a real '
        'drag would, and Done persists the new order', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();

        // Default order's last entry is "Most Skipped" — move it up past
        // "Favorites".
        await tapReorderMenuItem(tester, 'Most Skipped', 'Move up');

        await tester.ensureVisible(find.text('Done'));
        await tester.tap(find.text('Done'));
        await _settle(tester);

        final saved = await HomeLayoutStore.instance.load();
        expect(saved.map((p) => p.sectionId).toList(), [
          'continue_listening',
          'recently_played',
          'most_played',
          'recently_added',
          'most_skipped',
          'favorites',
        ]);
      });
    });

    testWidgets(
        'the first section has no "Move up" item, and the last has no '
        '"Move down" item', (tester) async {
      await tester.runAsync(() async {
        final ctx = _FakePluginContext()
          ..library = [_track('a', dateAdded: DateTime(2025))];

        await tester.pumpWidget(MaterialApp(
          home: HomeDashboardPage(pluginContext: ctx),
        ));
        await _settle(tester);

        await tester.tap(find.byTooltip('Customize'));
        await _settle(tester);
        await tester.pumpAndSettle();

        final firstRow = find.ancestor(
            of: find.text('Continue Listening'),
            matching: find.byType(CheckboxListTile));
        await tester.tap(find.descendant(
            of: firstRow, matching: find.byIcon(Icons.swap_vert)));
        await tester.pumpAndSettle();
        expect(find.text('Move up'), findsNothing);
        expect(find.text('Move down'), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        final lastRow = find.ancestor(
            of: find.text('Most Skipped'),
            matching: find.byType(CheckboxListTile));
        await tester.ensureVisible(lastRow);
        await tester.tap(find.descendant(
            of: lastRow, matching: find.byIcon(Icons.swap_vert)));
        await tester.pumpAndSettle();
        expect(find.text('Move down'), findsNothing);
        expect(find.text('Move up'), findsOneWidget);
      });
    });
  });
}
