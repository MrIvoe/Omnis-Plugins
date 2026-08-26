import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugin_api/plugin_destination.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/custom_mood_store.dart';
import 'package:omnis_plugins/moods_page.dart';

/// Contributes the Moods tab (preset mood tiles from every registered
/// [IQueueBuilder], plus the user's own rule-based custom moods, plus the
/// Forgotten Music page reached from its app bar) as a
/// [PluginDestination] — Tier 2 task 4's extraction of what used to be a
/// hardcoded core tab built inline in the Omnis app's own
/// `lib/ui/home_page.dart`, alongside `mood_builder_dialog.dart`,
/// `custom_mood.dart`, `forgotten_music_page.dart` and
/// `forgotten_tracks.dart`.
///
/// Registers [IMoodPlayer] so the two app-side call sites that used to
/// reach `MoodsPageState` through a `GlobalKey` — the §37 "search
/// everywhere" command palette's mood results (`home_page.dart`) and the
/// pop-out sidebar's "MY MOODS" section (`global_sidebar_drawer.dart`) —
/// keep working through a capability interface instead, exactly the way
/// `HomeDashboardPlugin` handles [IHomeCustomizer]. All three members
/// degrade to a null-safe no-op (or an empty list) when the page isn't
/// mounted, matching the old `GlobalKey?.currentState?.` behavior exactly.
///
/// Two gaps fell out of the move and are deliberately not worked around:
///
///  - Starting playback from a mood tile no longer pushes the Now Playing
///    screen afterward — `NowPlayingPage` lives in the Omnis app and
///    isn't reachable from a bundled plugin. The always-visible
///    mini-player is still one tap away. Identical to the gap
///    `HomeDashboardPlugin` documents for the same reason.
///  - The Moods tab's nav icon used to follow the app-wide icon style
///    setting (`OmnisIconCatalog.mood`, switching between filled/
///    outlined/rounded/sharp) via a catalog under `lib/ui/theme/` that a
///    bundled plugin can't reach. This contributes a fixed `Icons.mood`
///    (the same glyph the catalog's default "filled" style already
///    resolved to) instead — again the same tradeoff Task 3 already made
///    for the Home tab.
class MoodsPlugin extends MusicPlugin implements IMoodPlayer {
  /// Owned by the plugin itself, not by `home_page.dart` — `pageBuilder`
  /// constructs a fresh `MoodsPage` on every `IndexedStack` rebuild, so
  /// the plugin needs its own stable way to reach whichever instance is
  /// currently mounted. See [IMoodPlayer]'s doc comment for why this
  /// replaced the `GlobalKey`s `home_page.dart` and
  /// `global_sidebar_drawer.dart` used to hold directly.
  final _moodsKey = GlobalKey<MoodsPageState>();

  @override
  String get id => 'moods';

  @override
  String get name => 'Moods';

  @override
  String get description =>
      'The Moods tab: preset mood queues, user-created rule-based moods, '
      'and a browsable Forgotten Music list.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => false;

  @override
  Future<void> initialize() async {
    context?.services.register(IMoodPlayer, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(IMoodPlayer, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IMoodPlayer, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IMoodPlayer, this);
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
        id: 'moods',
        icon: Icons.mood,
        label: 'Moods',
        pageBuilder: (context) => MoodsPage(
          key: _moodsKey,
          pluginContext: ctx,
        ),
      ),
    ];
  }

  @override
  void playMood(String mood) {
    _moodsKey.currentState?.playMood(mood);
  }

  @override
  void playCustomMood(CustomMood custom) {
    _moodsKey.currentState?.playCustomMood(custom);
  }

  /// Reads straight from [CustomMoodStore] rather than through
  /// [_moodsKey]'s mounted `State` — matches `RadioPlugin
  /// .customStationSummaries`'s exact pattern (see
  /// [ICustomRadioStationProvider.customStationSummaries]'s own doc for
  /// why), fixed for the identical problem shape: a synchronous read off
  /// the mounted page's `State` could race that page's own async initial
  /// load, silently returning an empty list at app startup and reading
  /// every pinned custom mood as a stale/deleted reference. Going to the
  /// store directly sidesteps that race — this store is in the same
  /// package as this plugin, so there's no cross-package boundary being
  /// crossed the way there would be for the app to read it directly.
  @override
  Future<List<CustomMood>> customMoods() => CustomMoodStore.instance.load();
}
