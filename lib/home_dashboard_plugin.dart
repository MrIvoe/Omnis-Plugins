import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_destination.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/home_dashboard_page.dart';

/// Contributes the Home tab (Recently Played / Most Played / Recently
/// Added / Continue Listening / Favorites / Most Skipped) as a
/// [PluginDestination] — Tier 2 task 3's extraction of what used to be
/// `home_page.dart`'s hardcoded first tab, built directly from
/// `HomeDashboardPage` (`lib/ui/home_dashboard_page.dart`) and
/// `HomeLayoutStore` (`lib/core/home_layout_store.dart`) inside the Omnis
/// app itself.
///
/// Two real capability gaps fell out of the move and are deliberately
/// not worked around — see `home_dashboard_page.dart`'s own doc comment
/// for the reasoning:
///  - no live "library changed" signal reaches a bundled plugin, so a
///    scan/tag-edit/delete made elsewhere while this tab is already
///    mounted doesn't refresh Recently Added until some other event
///    (playback, favoriting, Customize) fires the page's own reload;
///  - tapping a card starts playback but no longer pushes Now Playing
///    afterward, since that page lives in the Omnis app and isn't
///    reachable from here. The always-visible mini-player is still one
///    tap away.
///
/// A third, purely cosmetic gap: the Home tab's nav icon used to follow
/// the app-wide icon style setting (`OmnisIconCatalog.home`, switching
/// between filled/outlined/rounded/sharp) via a catalog that lives in
/// `lib/ui/theme/` and isn't reachable from a bundled plugin. This
/// contributes a fixed `Icons.home` (the same glyph the catalog's
/// default "filled" style already resolved to) instead — every other
/// destination still follows the style setting; only this one tab's icon
/// is now static.
class HomeDashboardPlugin extends MusicPlugin implements IHomeCustomizer {
  /// Owned by the plugin itself, not by `home_page.dart` — `pageBuilder`
  /// constructs a fresh `HomeDashboardPage` on every `IndexedStack`
  /// rebuild, so the plugin needs its own stable way to reach whichever
  /// instance is currently mounted. See `IHomeCustomizer`'s doc comment
  /// for why this replaced the `GlobalKey` `home_page.dart` used to own
  /// directly.
  final _dashboardKey = GlobalKey<HomeDashboardPageState>();

  @override
  String get id => 'home_dashboard';

  @override
  String get name => 'Home Dashboard';

  @override
  String get description =>
      'The Home tab: recently played, most played, recently added, '
      'continue listening, favorites, and most skipped, with a '
      'customizable section order.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => false;

  @override
  Future<void> initialize() async {
    context?.services.register(IHomeCustomizer, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(IHomeCustomizer, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IHomeCustomizer, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IHomeCustomizer, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  List<PluginDestination> homeDestinations() {
    final ctx = context;
    if (ctx == null) return const [];
    return [
      PluginDestination(
        id: 'home',
        icon: Icons.home,
        label: 'Home',
        pageBuilder: (context) => HomeDashboardPage(
          key: _dashboardKey,
          pluginContext: ctx,
        ),
      ),
    ];
  }

  @override
  void openCustomizeSheet() {
    _dashboardKey.currentState?.openCustomizeSheet();
  }
}
