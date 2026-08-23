import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/tag_editor_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only `services` is stubbed — the only context member
/// `TagEditorPlugin`'s `initialize`/`enable`/`disable`/`dispose`
/// lifecycle touches, same "stub only what's used" shape
/// `ringtone_plugin_test.dart`'s `_FakeContext` already establishes.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// Pure-function and storage-only surfaces of `TagEditorPlugin` — the
/// artist-splitting logic and auto-tag tracking, neither of which touch
/// a real file or a `PluginContext`. The file-round-trip behavior
/// (`readTags`/`writeTags` against a real ID3 file) stays covered in
/// Omnis's own test suite, where a real temp-file fixture already
/// exists; duplicating that here wouldn't add coverage.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track({
    String id = 't1',
    String title = 'Song',
    List<String> artists = const ['Artist'],
  }) =>
      BaseTrack(
        id: id,
        title: title,
        artists: artists,
        album: 'Album',
        duration: 180,
        type: TrackType.local,
      );

  group('smart re-tag tracking', () {
    test('a track is not auto-tagged until explicitly marked', () {
      final plugin = TagEditorPlugin();
      expect(plugin.wasAutoTagged('t1'), isFalse);
    });

    test('marking persists across a fresh plugin instance', () async {
      final plugin = TagEditorPlugin();
      await plugin.markAutoTagged('t1');

      final freshInstance = TagEditorPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.wasAutoTagged('t1'), isTrue);
    });

    test('clearAutoTagged is the redo-anyway escape hatch', () async {
      final plugin = TagEditorPlugin();
      await plugin.markAutoTagged('t1');
      expect(plugin.wasAutoTagged('t1'), isTrue);

      await plugin.clearAutoTagged('t1');
      expect(plugin.wasAutoTagged('t1'), isFalse);
    });
  });

  group('artist separator splitting', () {
    test('splits on a default separator like "feat."', () {
      final plugin = TagEditorPlugin();
      expect(plugin.splitArtists('Artist1 feat. Artist2'),
          ['Artist1', 'Artist2']);
    });

    test('is case-insensitive and configurable', () async {
      final plugin = TagEditorPlugin();
      await plugin.setArtistSeparators(['x']);
      expect(plugin.splitArtists('Artist1 X Artist2'), ['Artist1', 'Artist2']);
    });

    test('leaves a plain artist name untouched when nothing matches', () {
      final plugin = TagEditorPlugin();
      expect(plugin.splitArtists('Solo Artist'), ['Solo Artist']);
      expect(plugin.splitArtists('SoloArtist'), ['SoloArtist']);
    });

    test('extracts a featured artist wrongly baked into the title', () {
      final plugin = TagEditorPlugin();
      final result =
          plugin.extractFeaturedArtistFromTitle('Song Title (feat. Artist2)');
      expect(result.title, 'Song Title');
      expect(result.featuredArtist, 'Artist2');
    });

    test('leaves a title with no featured-artist marker unchanged', () {
      final plugin = TagEditorPlugin();
      final result = plugin.extractFeaturedArtistFromTitle('Plain Title');
      expect(result.title, 'Plain Title');
      expect(result.featuredArtist, isNull);
    });

    test('cleanArtistFields moves a featured artist out of the title', () {
      final plugin = TagEditorPlugin();
      final t = track(title: 'Song (ft. Guest)', artists: ['Main']);

      final cleaned = plugin.cleanArtistFields(t);

      expect(cleaned, isNotNull);
      expect(cleaned!.title, 'Song');
      expect(cleaned.artists, containsAll(['Main', 'Guest']));
    });

    test('cleanArtistFields returns null when nothing needs to change', () {
      final plugin = TagEditorPlugin();
      final t = track(title: 'Plain Song', artists: ['Solo Artist']);
      expect(plugin.cleanArtistFields(t), isNull);
    });
  });

  test('TagEditorPlugin satisfies ITagWriter', () {
    final plugin = TagEditorPlugin();
    expect(plugin, isA<ITagWriter>());
  });

  test('TagEditorPlugin satisfies IFileTagWriter', () {
    final plugin = TagEditorPlugin();
    expect(plugin, isA<IFileTagWriter>());
  });

  group('IFileTagWriter', () {
    test('initialize registers IFileTagWriter; dispose unregisters it',
        () async {
      final plugin = TagEditorPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isTrue);
      expect(ctx.servicesRegistry.get<IFileTagWriter>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = TagEditorPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IFileTagWriter>(), isTrue);
    });
  });

  group('ITagWriter', () {
    test('initialize registers ITagWriter; dispose unregisters it',
        () async {
      final plugin = TagEditorPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<ITagWriter>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<ITagWriter>(), isTrue);
      expect(ctx.servicesRegistry.get<ITagWriter>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<ITagWriter>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = TagEditorPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<ITagWriter>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<ITagWriter>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<ITagWriter>(), isTrue);
    });

    test('initialize registers both IFileTagWriter and ITagWriter on the '
        'same instance', () async {
      final plugin = TagEditorPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.initialize();

      expect(ctx.servicesRegistry.get<IFileTagWriter>(), same(plugin));
      expect(ctx.servicesRegistry.get<ITagWriter>(), same(plugin));
    });
  });
}
