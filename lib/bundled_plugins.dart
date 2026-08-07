import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/audio_analysis_plugin.dart';
import 'package:omnis_plugins/bluetooth_playback_plugin.dart';
import 'package:omnis_plugins/driving_mode_plugin.dart';
import 'package:omnis_plugins/equalizer_plugin.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:omnis_plugins/lyrics_plugin.dart';
import 'package:omnis_plugins/metadata_enrichment_plugin.dart';
import 'package:omnis_plugins/queue_preset_plugin.dart';
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
List<MusicPlugin> createBundledPlugins() => <MusicPlugin>[
      SleepTimerPlugin(),
      ShuffleRepeatPlugin(),
      ReplayGainPlugin(),
      LyricsPlugin(),
      EqualizerPlugin(),
      FavoritesPlugin(),
      VisualizerPlugin(),
      SmartPlaylistPlugin(),
      QueuePresetPlugin(),
      ScrobblePlugin(),
      MetadataEnrichmentPlugin(),
      AudioAnalysisPlugin(),
      TagEditorPlugin(),
      SpotifyImportPlugin(),
      SpotifyPlaybackPlugin(),
      YoutubeMusicImportPlugin(),
      YoutubePlaybackPlugin(),
      BluetoothPlaybackPlugin(),
      RingtonePlugin(),
      DrivingModePlugin(),
    ];
