import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/custom_mood_store.dart';
import 'package:omnis_plugins/moods_page.dart';
import 'package:omnis_plugins/queue_preset_plugin.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;
}

/// Stubs only the slice of [PluginContext] `MoodsPage` actually reads —
/// the reads that used to go straight to `LibraryRepository`/
/// `AudioEngine` before Tier 2 moved this page out of the Omnis app.
/// Same "stub only what's used, everything else throws" `noSuchMethod`
/// shape `home_dashboard_page_test.dart`'s own fake uses.
class _FakePluginContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  Future<List<BaseTrack>> loadLibraryTracks() async => const [];

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// Finds the Moods grid's `SliverGridDelegateWithFixedCrossAxisCount` and
/// returns its `crossAxisCount` — the value under test throughout this
/// file. There is exactly one `GridView` on this page.
int _crossAxisCount(WidgetTester tester) {
  final gridView = tester.widget<GridView>(find.byType(GridView));
  final delegate =
      gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

double _childAspectRatio(WidgetTester tester) {
  final gridView = tester.widget<GridView>(find.byType(GridView));
  final delegate =
      gridView.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.childAspectRatio;
}

Future<void> _pumpMoodsPageAt(
    WidgetTester tester, PluginContext pluginContext, double width,
    {double height = 800}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: MoodsPage(pluginContext: pluginContext),
  ));
  // The Moods grid's crossAxisCount is computed synchronously in build()
  // from LayoutBuilder's constraints — it does not depend on the async
  // `_loadCustomMoods()` future initState kicks off, so a single pump
  // (rather than pumpAndSettle, which some Material widgets elsewhere in
  // this app never settle under) is enough to observe it.
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePluginContext pluginContext;

  setUp(() async {
    final tempDir =
        (await Directory.systemTemp.createTemp('omnis_moods_grid_test')).path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
    CustomMoodStore.instance.resetForTesting();
    pluginContext = _FakePluginContext();
    // Real bundled plugin — gives the grid 11 real preset tiles, including
    // "Forgotten Favorites" (a two-word name that wraps to a second title
    // line), so the overflow assertions below exercise real content
    // instead of an empty grid.
    final presets = QueuePresetPlugin()..attach(pluginContext);
    await presets.initialize();
  });

  group('Moods grid column count is width-aware', () {
    testWidgets(
        'a phone-width viewport uses the 2-column minimum', (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 360);
      expect(_crossAxisCount(tester), 2);
    });

    testWidgets('a tablet-width viewport uses more columns than a phone',
        (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 700);
      expect(_crossAxisCount(tester), 3);
    });

    testWidgets(
        'a wide desktop viewport uses more columns than a tablet, but is '
        'capped rather than growing without bound', (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 1400);
      expect(_crossAxisCount(tester), 5);
    });

    testWidgets(
        'an extremely wide viewport stays capped at the 5-column ceiling',
        (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 3000);
      expect(_crossAxisCount(tester), 5);
    });

    testWidgets(
        'column count strictly increases from phone to tablet to desktop, '
        'and never drops below 2', (tester) async {
      final widths = [320.0, 600.0, 900.0, 1200.0, 1800.0];
      int? previous;
      for (final width in widths) {
        await _pumpMoodsPageAt(tester, pluginContext, width);
        final count = _crossAxisCount(tester);
        expect(count, greaterThanOrEqualTo(2));
        if (previous != null) {
          expect(count, greaterThanOrEqualTo(previous),
              reason: 'crossAxisCount must never shrink as width grows '
                  '(width=$width)');
        }
        previous = count;
      }
      // The 320 -> 1800 span crosses several 200dp steps, so the count
      // must have actually moved at least once, not stayed pinned at the
      // old hardcoded 2 for every width the way the pre-fix grid did.
      await _pumpMoodsPageAt(tester, pluginContext, 320);
      final atPhone = _crossAxisCount(tester);
      await _pumpMoodsPageAt(tester, pluginContext, 1800);
      final atDesktop = _crossAxisCount(tester);
      expect(atDesktop, greaterThan(atPhone));
    });
  });

  group('Moods grid tiles render without overflow at every width', () {
    testWidgets('no overflow at a narrow phone width, including the '
        'two-word "Forgotten Favorites" preset that wraps to a second '
        'title line', (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 320);
      expect(find.text('Forgotten Favorites'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at a wide desktop width', (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 1800);
      expect(find.text('Forgotten Favorites'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'childAspectRatio is preserved at 0.95 regardless of column count '
        '(each tile keeps its target width/height shape; only the number '
        'of columns changes with available width)', (tester) async {
      await _pumpMoodsPageAt(tester, pluginContext, 320);
      expect(_childAspectRatio(tester), 0.95);
      await _pumpMoodsPageAt(tester, pluginContext, 1800);
      expect(_childAspectRatio(tester), 0.95);
    });
  });
}
