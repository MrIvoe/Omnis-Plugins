import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugins/forgotten_music_page.dart';

/// Stubs only the slice of [PluginContext] `ForgottenMusicPage` actually
/// reads — the reads that used to go straight to `LibraryRepository`/
/// `PlayHistoryStore`/`AudioEngine` before Tier 2 moved this page out of
/// the Omnis app. Everything else throws, the same `noSuchMethod` shape
/// `home_dashboard_page_test.dart`'s own fake uses.
class _FakePluginContext implements PluginContext {
  List<BaseTrack> library = const [];
  Map<String, DateTime> lastPlayed = const {};

  List<BaseTrack>? lastQueue;
  int? lastStartIndex;
  bool playCalled = false;

  @override
  Future<List<BaseTrack>> loadLibraryTracks() async => library;

  @override
  Future<Map<String, DateTime>> loadLastPlayedByTrackId() async => lastPlayed;

  @override
  Future<void> setQueue(List<BaseTrack> tracks, {int startIndex = 0}) async {
    lastQueue = tracks;
    lastStartIndex = startIndex;
  }

  @override
  Future<void> play() async => playCalled = true;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// The page's `initState` load resolves on already-completed futures here
/// (the fake context returns synchronously-available values), so plain
/// pumps are enough — no real-I/O nudge like the app-repo version needed.
/// The trailing `pumpAndSettle` finishes a still-animating popup-menu
/// open/close; without it a tap immediately following one can land on the
/// barrier behind a not-yet-fully-open menu instead of the item itself.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}

BaseTrack _track(String id) => BaseTrack(
      id: id,
      title: 'Track $id',
      artists: const ['Artist'],
      album: 'Album',
      duration: 200,
      type: TrackType.local,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime(2026, 8, 15);

  late _FakePluginContext context;

  setUp(() {
    context = _FakePluginContext();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ForgottenMusicPage(pluginContext: context),
    ));
    await _settle(tester);
  }

  testWidgets('a never-played track shows up with the default 6-month '
      'threshold', (tester) async {
    context.library = [_track('a')];

    await pumpPage(tester);

    expect(find.text('1 track you haven\'t heard in 6 months+'), findsOneWidget);
    expect(find.text('Track a'), findsOneWidget);
    expect(find.textContaining('never played'), findsOneWidget);
  });

  testWidgets('a track played recently is excluded', (tester) async {
    context.library = [_track('a')];
    context.lastPlayed = {'a': DateTime.now()};

    await pumpPage(tester);

    expect(find.textContaining('Nothing forgotten'), findsOneWidget);
    expect(find.text('Track a'), findsNothing);
  });

  testWidgets('tapping a track plays the forgotten list starting at that '
      'track', (tester) async {
    context.library = [_track('a'), _track('b')];

    await pumpPage(tester);
    await tester.tap(find.text('Track b'));
    await _settle(tester);

    expect(context.lastQueue?.map((t) => t.id), ['a', 'b']);
    expect(context.lastStartIndex, 1);
    expect(context.playCalled, isTrue);
  });

  testWidgets('"Play all" plays every forgotten track from the top',
      (tester) async {
    context.library = [_track('a'), _track('b')];

    await pumpPage(tester);
    await tester.tap(find.byTooltip('Play all'));
    await _settle(tester);

    expect(context.lastQueue?.map((t) => t.id), ['a', 'b']);
    expect(context.lastStartIndex, 0);
    expect(context.playCalled, isTrue);
  });

  testWidgets('changing the threshold to 1 month re-filters the list',
      (tester) async {
    // Played 60 days ago: outside a 1-month threshold, inside the default
    // 6-month one — so switching the menu genuinely changes what renders,
    // which the app-repo version of this test could only assert
    // indirectly (it recorded a play "moments ago", excluded under both
    // thresholds).
    context.library = [_track('a')];
    context.lastPlayed = {'a': DateTime.now().subtract(const Duration(days: 60))};

    await pumpPage(tester);
    expect(find.text('Track a'), findsNothing,
        reason: 'played 60 days ago, well within the default 6 months');

    await tester.tap(find.byTooltip('Not heard in…'));
    await _settle(tester);
    await tester.tap(find.text('1 month').last);
    await _settle(tester);

    expect(find.text('Track a'), findsOneWidget);
    expect(find.textContaining('haven\'t heard in 1 month+'), findsOneWidget);
  });

  testWidgets('an empty library shows the empty state, not a crash',
      (tester) async {
    await pumpPage(tester);

    expect(find.textContaining('Nothing forgotten'), findsOneWidget);
  });

  testWidgets('never-played tracks sort ahead of stale-but-played ones, '
      'matching findForgottenTracks\' own ordering', (tester) async {
    context.library = [_track('stale'), _track('never')];
    context.lastPlayed = {'stale': now.subtract(const Duration(days: 400))};

    await pumpPage(tester);
    await tester.tap(find.byTooltip('Play all'));
    await _settle(tester);

    expect(context.lastQueue?.map((t) => t.id), ['never', 'stale']);
  });
}
