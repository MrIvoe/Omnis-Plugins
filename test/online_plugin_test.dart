import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/online_plugin.dart';

/// Only `services` is stubbed — `OnlinePlugin` itself touches nothing
/// else on [PluginContext] (its `pageBuilder` just hands the whole
/// context through to `OnlinePage`, unopened) — same "stub only what's
/// used" shape `moods_plugin_test.dart`'s own `_FakeContext` already
/// establishes.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

void main() {
  group('homeDestinations', () {
    test('contributes nothing before attachment', () {
      final plugin = OnlinePlugin();
      expect(plugin.homeDestinations(), isEmpty);
    });

    test('contributes exactly one destination with id "online" once '
        'attached', () {
      final plugin = OnlinePlugin();
      plugin.attach(_FakeContext());

      final destinations = plugin.homeDestinations();

      expect(destinations, hasLength(1));
      expect(destinations.single.id, 'online');
      expect(destinations.single.label, 'Online');
      expect(destinations.single.icon, Icons.cloud_queue);
    });
  });

  group('lifecycle', () {
    // OnlinePlugin registers no capability interface of its own (unlike
    // HomeDashboardPlugin/MoodsPlugin) — planning research for this task
    // found no command-palette/GlobalKey reach into the pre-extraction
    // OnlinePage to replace. What matters here is simply that every
    // MusicPlugin lifecycle hook completes cleanly, and that
    // homeDestinations() behaves the same "empty until attached, one
    // destination once attached" way MoodsPlugin/HomeDashboardPlugin's
    // own tests already establish — a plugin's own homeDestinations()
    // isn't gated on its enabled/disabled state at all; that filtering
    // happens one layer up, in the app's own PluginManager.homeDestinations
    // getter (Omnis-app-only, unreachable from this repo's tests).
    test('initialize/enable/disable/dispose all complete without error',
        () async {
      final plugin = OnlinePlugin();
      plugin.attach(_FakeContext());

      await expectLater(plugin.initialize(), completes);
      await expectLater(plugin.enable(), completes);
      await expectLater(plugin.disable(), completes);
      await expectLater(plugin.dispose(), completes);
    });

    test('the lifecycle also completes without error before attachment',
        () async {
      final plugin = OnlinePlugin();

      await expectLater(plugin.initialize(), completes);
      await expectLater(plugin.enable(), completes);
      await expectLater(plugin.disable(), completes);
      await expectLater(plugin.dispose(), completes);
    });
  });
}
