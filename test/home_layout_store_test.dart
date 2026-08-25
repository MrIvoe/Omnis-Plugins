import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugins/home_layout_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;
}

class _Section {
  final String id;
  const _Section(this.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDir;

  // HomeLayoutStore.instance caches its resolved file path for the
  // whole process (same as LibraryStore/PlayHistoryStore — see
  // play_history_store_test.dart's setUp for the full reasoning): a
  // fresh temp dir per test only matters for the very first test to
  // touch the singleton, so this resolves it once for the whole file
  // and relies on clear() for a clean slate between tests — which also
  // means direct File(...) writes below (for the corrupt/malformed-
  // JSON cases) must target this same stable tempDir, not a fresh one
  // per test, to actually land where the store itself reads from.
  setUpAll(() async {
    tempDir =
        (await Directory.systemTemp.createTemp('omnis_home_layout_test'))
            .path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  setUp(() async {
    await HomeLayoutStore.instance.clear();
  });

  group('HomeLayoutStore', () {
    test('load returns an empty list when nothing has ever been saved',
        () async {
      expect(await HomeLayoutStore.instance.load(), isEmpty);
    });

    test('save then load round-trips order and visibility', () async {
      final prefs = [
        const HomeSectionPreference(sectionId: 'b', visible: false),
        const HomeSectionPreference(sectionId: 'a', visible: true),
      ];
      await HomeLayoutStore.instance.save(prefs);

      final loaded = await HomeLayoutStore.instance.load();

      expect(loaded.map((p) => p.sectionId).toList(), ['b', 'a']);
      expect(loaded[0].visible, isFalse);
      expect(loaded[1].visible, isTrue);
    });

    test('tolerates corrupt JSON', () async {
      final f = File('$tempDir/omnis_home_layout.json');
      await f.writeAsString('not valid json {{{');

      expect(await HomeLayoutStore.instance.load(), isEmpty);
    });

    test('a single malformed record among many valid ones is skipped, '
        'not fatal to the rest', () async {
      final f = File('$tempDir/omnis_home_layout.json');
      await f.writeAsString(jsonEncode({
        'schemaVersion': 1,
        'data': [
          {'sectionId': 'a', 'visible': true},
          <String, dynamic>{}, // missing required sectionId
          {'sectionId': 'b', 'visible': false},
        ],
      }));

      final loaded = await HomeLayoutStore.instance.load();

      expect(loaded.map((p) => p.sectionId).toList(), ['a', 'b']);
    });

    test('clear() removes the persisted file', () async {
      await HomeLayoutStore.instance.save(const [
        HomeSectionPreference(sectionId: 'a', visible: true),
      ]);
      expect(await HomeLayoutStore.instance.load(), isNotEmpty);

      await HomeLayoutStore.instance.clear();

      expect(await HomeLayoutStore.instance.load(), isEmpty);
    });
  });

  group('applyHomeLayout', () {
    const a = _Section('a');
    const b = _Section('b');
    const c = _Section('c');
    String idOf(_Section s) => s.id;

    test('an empty saved layout returns the default sections unchanged', () {
      final result = applyHomeLayout([a, b, c], const [], idOf);
      expect(result, [a, b, c]);
    });

    test('reorders sections to match the saved order', () {
      final saved = [
        const HomeSectionPreference(sectionId: 'c', visible: true),
        const HomeSectionPreference(sectionId: 'a', visible: true),
        const HomeSectionPreference(sectionId: 'b', visible: true),
      ];
      final result = applyHomeLayout([a, b, c], saved, idOf);
      expect(result, [c, a, b]);
    });

    test('a section marked invisible in the saved layout is dropped', () {
      final saved = [
        const HomeSectionPreference(sectionId: 'a', visible: true),
        const HomeSectionPreference(sectionId: 'b', visible: false),
        const HomeSectionPreference(sectionId: 'c', visible: true),
      ];
      final result = applyHomeLayout([a, b, c], saved, idOf);
      expect(result, [a, c]);
    });

    test('a saved section with no current data is silently skipped, not '
        'a crash', () {
      final saved = [
        const HomeSectionPreference(sectionId: 'missing', visible: true),
        const HomeSectionPreference(sectionId: 'a', visible: true),
      ];
      final result = applyHomeLayout([a], saved, idOf);
      expect(result, [a]);
    });

    test('a default section never mentioned in the saved layout is '
        'appended at the end, visible by default', () {
      final saved = [
        const HomeSectionPreference(sectionId: 'b', visible: true),
      ];
      // 'a' and 'c' are real default sections the saved layout predates.
      final result = applyHomeLayout([a, b, c], saved, idOf);
      expect(result, [b, a, c]);
    });

    test('an empty default section list returns empty regardless of '
        'what was saved', () {
      final saved = [
        const HomeSectionPreference(sectionId: 'a', visible: true),
      ];
      expect(applyHomeLayout(const <_Section>[], saved, idOf), isEmpty);
    });
  });
}
