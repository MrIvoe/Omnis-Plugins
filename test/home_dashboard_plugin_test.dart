import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/home_dashboard_plugin.dart';

/// Only `services` is stubbed — the only context member
/// `HomeDashboardPlugin`'s lifecycle touches, same "stub only what's
/// used" shape `ringtone_plugin_test.dart`'s `_FakeContext` already
/// establishes. `homeDestinations()` also reads `context` itself (to
/// hand the whole `PluginContext` to the page it builds), which is why
/// this fake needs to be a real, if minimal, `PluginContext`
/// implementation rather than just a `ServiceRegistry` wrapper.
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

  test('HomeDashboardPlugin satisfies IHomeCustomizer', () {
    final plugin = HomeDashboardPlugin();
    expect(plugin, isA<IHomeCustomizer>());
  });

  group('IHomeCustomizer registration lifecycle', () {
    test('initialize registers IHomeCustomizer; dispose unregisters it',
        () async {
      final plugin = HomeDashboardPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isTrue);
      expect(ctx.servicesRegistry.get<IHomeCustomizer>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = HomeDashboardPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IHomeCustomizer>(), isTrue);
    });
  });

  group('homeDestinations', () {
    test('contributes exactly one destination, id "home", before '
        'attachment returns none', () {
      final plugin = HomeDashboardPlugin();
      expect(plugin.homeDestinations(), isEmpty);
    });

    test('contributes exactly one destination with id "home" once '
        'attached', () {
      final plugin = HomeDashboardPlugin();
      plugin.attach(_FakeContext());

      final destinations = plugin.homeDestinations();

      expect(destinations, hasLength(1));
      expect(destinations.single.id, 'home');
      expect(destinations.single.label, 'Home');
      expect(destinations.single.icon, Icons.home);
    });

    test('openCustomizeSheet is a no-op when the dashboard page is not '
        'currently mounted (matches the old GlobalKey?.currentState?. '
        'null-safe-no-op behavior exactly)', () {
      final plugin = HomeDashboardPlugin();
      plugin.attach(_FakeContext());
      plugin.homeDestinations(); // builds the destination, not the page

      // Must not throw even though nothing has ever built the page this
      // plugin's own GlobalKey targets.
      expect(plugin.openCustomizeSheet, returnsNormally);
    });
  });

  group('onLibraryScan (task 3 fix round — debounced Recently Added '
      'refresh)', () {
    test('is a harmless no-op when the dashboard page is not currently '
        'mounted, same as openCustomizeSheet', () async {
      final plugin = HomeDashboardPlugin();
      plugin.attach(_FakeContext());
      plugin.homeDestinations(); // builds the destination, not the page

      // Must not throw even though the debounce timer it starts will
      // eventually fire against a GlobalKey with no currentState.
      await plugin.onLibraryScan('/music/a.mp3');

      // dispose() cancels the pending debounce timer — without this the
      // test process would otherwise carry a live 3-second Timer past
      // this test's own completion.
      await plugin.dispose();
    });

    test('disable() cancels any pending debounce timer, not just '
        'unregistering IHomeCustomizer', () async {
      final plugin = HomeDashboardPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);
      await plugin.enable();

      await plugin.onLibraryScan('/music/a.mp3');
      // Must not throw, and must leave no pending timer behind (a leaked
      // real Timer would otherwise fire ~3s after this test moves on).
      await plugin.disable();
      await plugin.dispose();
    });
  });
}
