import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_destination.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/online_page.dart';

/// Contributes the Online tab (Internet Radio, self-hosted media-server
/// search, embedded YouTube/Spotify playback) as a [PluginDestination] —
/// Tier 2 task 5's extraction of what used to be a hardcoded core tab
/// built inline in the Omnis app's own `lib/ui/home_page.dart`, alongside
/// `online_page.dart` (which now also hosts `RadioBody`, merged in during
/// the same move — see that file's own doc comment for why) and
/// `custom_radio_station_store.dart`.
///
/// Unlike `HomeDashboardPlugin`/`MoodsPlugin`, this plugin registers no
/// capability interface of its own — there is no `GlobalKey`-into-this-
/// page reach from anywhere else in the app to replace (planning research
/// for this task confirmed zero command-palette/`GlobalKey` reaches into
/// the pre-extraction `OnlinePage`). The one real reach the pre-extraction
/// page *did* have — into `YoutubePlaybackPlugin`/`SpotifyPlaybackPlugin`
/// via `PluginManager.byId(...)`/`.uiSlotForPlugin(...)`, both
/// Omnis-app-only — is handled by the new `IEmbeddedPlaybackProvider`
/// capability interface those two plugins now register themselves under
/// (see that interface's own doc comment in `service_interfaces.dart`),
/// not by anything this plugin itself needs to own.
///
/// One cosmetic gap fell out of the move, the same class already
/// documented for `HomeDashboardPlugin`/`MoodsPlugin`: the Online tab's
/// nav icon used to follow the app-wide icon style setting
/// (`OmnisIconCatalog.cloudQueue`, switching between filled/outlined/
/// rounded/sharp) via a catalog under `lib/ui/theme/` that a bundled
/// plugin can't reach. This contributes a fixed `Icons.cloud_queue` (the
/// same glyph the catalog's default "filled" style already resolved to)
/// instead.
class OnlinePlugin extends MusicPlugin {
  @override
  String get id => 'online';

  @override
  String get name => 'Online';

  @override
  String get description =>
      'The Online tab: Internet Radio, self-hosted media-server search '
      '(Ampache/Koel/OpenSubsonic/Jellyfin/Plex/Emby), and embedded '
      'YouTube/Spotify playback.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  /// `true` — this plugin's own [description] names three network-reaching
  /// features it hosts directly (embedded YouTube/Spotify playback, and
  /// self-hosted media-server search), and `online_page.dart` makes a
  /// direct `Image.network(favicon)` call to fetch radio station
  /// favicons. `false` here would silently exempt this plugin from the
  /// Plugins page's "disable every plugin with network access" bulk
  /// privacy control, which is exactly backwards for a tab whose entire
  /// purpose is reaching online sources.
  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {}

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
        id: 'online',
        icon: Icons.cloud_queue,
        label: 'Online',
        pageBuilder: (context) => OnlinePage(pluginContext: ctx),
      ),
    ];
  }

  @override
  Future<void> dispose() async {}
}
