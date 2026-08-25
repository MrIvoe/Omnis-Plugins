import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/custom_mood_store.dart';
import 'package:omnis_plugins/moods_plugin.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Only `services` is stubbed — the only context member `MoodsPlugin`'s
/// lifecycle touches, same "stub only what's used" shape
/// `home_dashboard_plugin_test.dart`'s `_FakeContext` already
/// establishes. `homeDestinations()` also reads `context` itself (to hand
/// the whole `PluginContext` to the page it builds), which is why this
/// fake needs to be a real, if minimal, `PluginContext` implementation
/// rather than just a `ServiceRegistry` wrapper.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// [_FakeContext] plus the library/playback slice `MoodsPage` itself
/// reads — needed by the delegation group at the bottom of this file,
/// which mounts the real page through the plugin's own `pageBuilder`
/// rather than only exercising the plugin object in isolation.
class _MountableContext extends _FakeContext {
  List<BaseTrack> library = const [];
  List<BaseTrack>? lastQueue;
  bool playCalled = false;

  @override
  Future<List<BaseTrack>> loadLibraryTracks() async => library;

  @override
  Future<void> setQueue(List<BaseTrack> tracks, {int startIndex = 0}) async {
    lastQueue = tracks;
  }

  @override
  Future<void> play() async => playCalled = true;
}

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;
}

/// A deterministic `IQueueBuilder` standing in for the real bundled ones
/// (`SmartPlaylistPlugin`/`QueuePresetPlugin`, each with its own tests) —
/// what's under test here is that `IMoodPlayer.playMood` reaches the
/// mounted page's real builder-fallback logic at all, not which tracks a
/// particular matcher picks.
class _StubQueueBuilder implements IQueueBuilder {
  final List<BaseTrack> result;
  _StubQueueBuilder(this.result);

  @override
  List<String> get supportedQueries => const ['Chill'];

  @override
  List<BaseTrack> buildQueueFor(List<BaseTrack> tracks, String query) =>
      query == 'Chill' ? result : const [];
}

BaseTrack _track(String id, {List<String> genres = const []}) => BaseTrack(
      id: id,
      title: 'Track $id',
      artists: const ['Artist'],
      album: 'Album',
      duration: 200,
      type: TrackType.local,
      genres: genres,
    );

/// pumpAndSettle() pumps frames back-to-back with no real time between
/// them, which never gives `CustomMoodStore`'s real (fake-path-provider-
/// backed) file read a chance to actually finish. An explicit real delay
/// between two pumps does — same pattern `home_dashboard_page_test.dart`
/// uses for `HomeLayoutStore`. Only real inside `tester.runAsync`, which
/// is why every widget test below wraps its whole body in one.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MoodsPlugin satisfies IMoodPlayer', () {
    final plugin = MoodsPlugin();
    expect(plugin, isA<IMoodPlayer>());
  });

  group('IMoodPlayer registration lifecycle', () {
    test('initialize registers IMoodPlayer; dispose unregisters it',
        () async {
      final plugin = MoodsPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isTrue);
      expect(ctx.servicesRegistry.get<IMoodPlayer>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = MoodsPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IMoodPlayer>(), isTrue);
    });
  });

  group('homeDestinations', () {
    test('contributes nothing before attachment', () {
      final plugin = MoodsPlugin();
      expect(plugin.homeDestinations(), isEmpty);
    });

    test('contributes exactly one destination with id "moods" once '
        'attached', () {
      final plugin = MoodsPlugin();
      plugin.attach(_FakeContext());

      final destinations = plugin.homeDestinations();

      expect(destinations, hasLength(1));
      expect(destinations.single.id, 'moods');
      expect(destinations.single.label, 'Moods');
      expect(destinations.single.icon, Icons.mood);
    });
  });

  group('IMoodPlayer degrades to a no-op when the page is not mounted '
      '(matches the old GlobalKey?.currentState?. null-safe behavior)', () {
    test('playMood does not throw', () {
      final plugin = MoodsPlugin();
      plugin.attach(_FakeContext());
      plugin.homeDestinations(); // builds the destination, not the page

      expect(() => plugin.playMood('Chill'), returnsNormally);
    });

    test('playCustomMood does not throw', () {
      final plugin = MoodsPlugin();
      plugin.attach(_FakeContext());
      plugin.homeDestinations();

      expect(
        () => plugin.playCustomMood(
            const CustomMood(id: 'm1', name: 'Late Night Drive')),
        returnsNormally,
      );
    });

    test('customMoods is an empty list, not null and not a throw', () {
      final plugin = MoodsPlugin();
      plugin.attach(_FakeContext());
      plugin.homeDestinations();

      expect(plugin.customMoods, isEmpty);
    });
  });

  group('IMoodPlayer reaches the real mounted page through the plugin\'s '
      'own GlobalKey', () {
    late _MountableContext ctx;
    late MoodsPlugin plugin;

    setUp(() async {
      final tempDir =
          (await Directory.systemTemp.createTemp('omnis_moods_plugin_test'))
              .path;
      PathProviderPlatform.instance = _FakePathProvider(tempDir);
      CustomMoodStore.instance.resetForTesting();
      ctx = _MountableContext();
      plugin = MoodsPlugin()..attach(ctx);
      await plugin.initialize();
    });

    /// Mounts the page exactly the way `home_page.dart`'s `IndexedStack`
    /// does — through the `PluginDestination.pageBuilder` this plugin
    /// contributes — so the `GlobalKey` under test is wired up the same
    /// way it is in the real app.
    Future<void> pumpDestination(WidgetTester tester) async {
      final destination = plugin.homeDestinations().single;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: destination.pageBuilder),
      ));
      await _settle(tester);
    }

    testWidgets('customMoods serves the mounted page\'s loaded list',
        (tester) async {
      await tester.runAsync(() async {
        await CustomMoodStore.instance.save(
            const [CustomMood(id: 'm1', name: 'Late Night Drive')]);

        await pumpDestination(tester);

        expect(plugin.customMoods.map((m) => m.name), ['Late Night Drive']);
      });
    });

    testWidgets('playMood builds a queue through the page\'s registered '
        'IQueueBuilders and starts playback', (tester) async {
      await tester.runAsync(() async {
        final chillTrack = _track('chill');
        ctx.library = [chillTrack, _track('other')];
        ctx.servicesRegistry
            .register(IQueueBuilder, _StubQueueBuilder([chillTrack]));

        await pumpDestination(tester);
        plugin.playMood('Chill');
        await _settle(tester);

        expect(ctx.lastQueue?.map((t) => t.id), ['chill']);
        expect(ctx.playCalled, isTrue);
      });
    });

    testWidgets('playCustomMood builds a queue by filtering the library '
        'through CustomMood.matches', (tester) async {
      await tester.runAsync(() async {
        ctx.library = [
          _track('rock', genres: const ['Rock']),
          _track('jazz', genres: const ['Jazz']),
        ];

        await pumpDestination(tester);
        plugin.playCustomMood(const CustomMood(
            id: 'm1', name: 'Rock only', genres: ['Rock']));
        await _settle(tester);

        expect(ctx.lastQueue?.map((t) => t.id), ['rock']);
        expect(ctx.playCalled, isTrue);
      });
    });
  });
}
