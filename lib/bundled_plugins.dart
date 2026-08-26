import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/ai_playlist_plugin.dart';
import 'package:omnis_plugins/ampache_plugin.dart';
import 'package:omnis_plugins/artist_image_plugin.dart';
import 'package:omnis_plugins/audio_analysis_plugin.dart';
import 'package:omnis_plugins/bluetooth_playback_plugin.dart';
import 'package:omnis_plugins/device_volume_plugin.dart';
import 'package:omnis_plugins/dlna_plugin.dart';
import 'package:omnis_plugins/driving_mode_plugin.dart';
import 'package:omnis_plugins/emby_plugin.dart';
import 'package:omnis_plugins/equalizer_plugin.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:omnis_plugins/home_dashboard_plugin.dart';
import 'package:omnis_plugins/jellyfin_plugin.dart';
import 'package:omnis_plugins/koel_plugin.dart';
import 'package:omnis_plugins/lyrics_plugin.dart';
import 'package:omnis_plugins/metadata_enrichment_plugin.dart';
import 'package:omnis_plugins/moods_plugin.dart';
import 'package:omnis_plugins/online_plugin.dart';
import 'package:omnis_plugins/opensubsonic_plugin.dart';
import 'package:omnis_plugins/plex_plugin.dart';
import 'package:omnis_plugins/queue_preset_plugin.dart';
import 'package:omnis_plugins/radio_plugin.dart';
import 'package:omnis_plugins/ratings_plugin.dart';
import 'package:omnis_plugins/replay_gain_plugin.dart';
import 'package:omnis_plugins/ringtone_plugin.dart';
import 'package:omnis_plugins/scrobble_plugin.dart';
import 'package:omnis_plugins/shuffle_repeat_plugin.dart';
import 'package:omnis_plugins/sleep_timer_plugin.dart';
import 'package:omnis_plugins/smart_playlist_plugin.dart';
import 'package:omnis_plugins/spotify_import_plugin.dart';
import 'package:omnis_plugins/spotify_playback_plugin.dart';
import 'package:omnis_plugins/tag_editor_plugin.dart';
import 'package:omnis_plugins/visualizer_plugin.dart';
import 'package:omnis_plugins/youtube_music_import_plugin.dart';
import 'package:omnis_plugins/youtube_playback_plugin.dart';

/// The registry of plugins compiled into the app.
///
/// **This is the only file to edit when adding or removing a bundled
/// plugin.** `lib/core/` never imports a concrete plugin: `MainCore` calls
/// [createBundledPlugins], hands each one a `PluginContext`, and registers
/// it. A plugin reaches playback through that context, and the UI binds to
/// the shared instance via `PluginManager.bundled<T>()`.
///
/// Previously every one of these was a file inside `lib/core/`, imported by
/// name in `main_core.dart`, with two of them (ReplayGain, Equalizer)
/// needing bespoke callbacks wired up by the kernel — so touching the
/// plugin set meant touching the Core.
///
/// To add a plugin:
///  1. create `lib/plugins/my_plugin.dart` with a class extending
///     `MusicPlugin`;
///  2. add it to the list below.
///
/// Order matters for hook dispatch order (the order of this list), and
/// also for any `ServiceRegistry` interface more than one plugin
/// registers under — today, `IQueueBuilder`: `SmartPlaylistPlugin` must
/// come before `QueuePresetPlugin` so its curated mood-tag match gets
/// tried before that plugin's always-non-empty objective fallback (see
/// `IQueueBuilder`'s doc in `service_interfaces.dart`).
///
/// Three plugins have a *documented initialization-order dependency*
/// rather than just a dispatch-order preference: `QueuePresetPlugin`
/// (must come after `SmartPlaylistPlugin`, for the `IQueueBuilder`
/// reason above), `EqualizerPlugin`, and `DeviceVolumePlugin` (the
/// latter two must come after `BluetoothPlaybackPlugin`, whose
/// `initialize()` registers `IDeviceConnectivityProvider`, which both
/// read). All three override `MusicPlugin.requiresSequentialInit` to
/// `true` so Omnis's `PluginManager.initializeAll()` — which otherwise
/// initializes every bundled plugin concurrently — holds them back to a
/// second round that only starts once every other plugin has finished.
/// This list's own ordering no longer has to get that right on its own
/// as a result, but
/// is still written correctly below for readability.
///
/// Each entry is a factory, constructed one at a time inside a `try`/
/// `catch` below rather than as one list-literal expression — a single
/// constructor throwing must not take the other 19 plugins down with
/// it. (Omnis's own `PluginManager.registerAll` adds a second, coarser
/// layer of the same guarantee around the call to this function as a
/// whole, for the rare case a future version of this list changes shape
/// and reintroduces an unguarded throw — but skipping only the broken
/// entry, not the whole registry, is what actually happens here today.)
List<MusicPlugin> createBundledPlugins() {
  final factories = <MusicPlugin Function()>[
    () => SleepTimerPlugin(),
    () => ShuffleRepeatPlugin(),
    () => ReplayGainPlugin(),
    () => LyricsPlugin(),
    () => FavoritesPlugin(),
    () => RatingsPlugin(),
    () => HomeDashboardPlugin(),
    () => VisualizerPlugin(),
    () => SmartPlaylistPlugin(),
    () => QueuePresetPlugin(),
    () => MoodsPlugin(),
    () => RadioPlugin(),
    () => OnlinePlugin(),
    () => ScrobblePlugin(),
    () => MetadataEnrichmentPlugin(),
    () => AIPlaylistPlugin(),
    () => OpenSubsonicPlugin(),
    () => JellyfinPlugin(),
    () => EmbyPlugin(),
    () => AmpachePlugin(),
    () => KoelPlugin(),
    () => PlexPlugin(),
    () => DlnaPlugin(),
    () => ArtistImagePlugin(),
    () => AudioAnalysisPlugin(),
    () => TagEditorPlugin(),
    () => SpotifyImportPlugin(),
    () => SpotifyPlaybackPlugin(),
    () => YoutubeMusicImportPlugin(),
    () => YoutubePlaybackPlugin(),
    () => BluetoothPlaybackPlugin(),
    () => EqualizerPlugin(),
    () => DeviceVolumePlugin(),
    () => RingtonePlugin(),
    () => DrivingModePlugin(),
  ];
  final plugins = <MusicPlugin>[];
  for (final factory in factories) {
    try {
      plugins.add(factory());
    } catch (_) {
      // Skip only this entry — the rest of the registry still loads.
      // Omnis-side registration/initialization already logs failures to
      // the Plugin Health dashboard; a constructor that throws before a
      // plugin even has an id can't be attributed there, so this stays a
      // silent skip rather than duplicating that logging here (this
      // package has no dependency on Omnis's health-record types).
    }
  }
  return plugins;
}
