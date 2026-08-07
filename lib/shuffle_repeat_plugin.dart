import 'package:omnis_plugin_api/repeat_mode.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Shuffle and repeat mode — the Core Philosophy doc lists "Shuffle
/// Algorithms" explicitly under Layer 3 (Plugin Ecosystem), not Layer 2
/// (Player Runtime): the *toggle itself* stays a thin call into
/// [PluginContext] (`setShuffleEnabled`/`setRepeatMode` just forward to
/// just_audio's own shuffle/loop mode, which is where it has to live to
/// stay consistent with just_audio's gapless auto-advance — see
/// `AudioEngine`'s doc), but everything *around* the toggle — remembering
/// it across restarts and the toggle/cycle behavior the UI drives — is
/// orchestration a plugin can own just as well as the Core.
///
/// Before this existed, that orchestration was split across two places
/// that had nothing to do with each other: `main_core.dart` restored
/// `AppSettings.shuffleEnabled`/`repeatMode` onto the engine at startup,
/// and `now_playing_page.dart` inlined the repeat-cycle switch and wrote
/// straight back to `AppSettings` on every tap. Persisting UI toggle state
/// is not a Core concern (nothing in `lib/core/` reads these values), so
/// it comes from this plugin's own [storage] instead of a dedicated
/// `AppSettings` key pair — the same move [FavoritesPlugin] and
/// [TagEditorPlugin] already made for their own state.
class ShuffleRepeatPlugin extends MusicPlugin {
  static const _shuffleKey = 'shuffle_enabled';
  static const _repeatKey = 'repeat_mode';

  /// Whether shuffle is currently on. Reads live from the engine — the
  /// engine, not this plugin, is the source of truth once running.
  bool get shuffleEnabled => context?.shuffleEnabled ?? false;

  /// The current repeat mode. Reads live from the engine.
  RepeatMode get repeatMode => context?.repeatMode ?? RepeatMode.off;

  /// Flips shuffle and persists the new state.
  Future<void> toggleShuffle() async {
    final next = !shuffleEnabled;
    await context?.setShuffleEnabled(next);
    await storage.setBool(_shuffleKey, next);
  }

  /// Cycles repeat mode off -> all -> one -> off and persists the result.
  Future<void> cycleRepeat() async {
    final next = switch (repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    await context?.setRepeatMode(next);
    await storage.setString(_repeatKey, _encodeRepeat(next));
  }

  String _encodeRepeat(RepeatMode mode) => switch (mode) {
        RepeatMode.all => 'all',
        RepeatMode.one => 'one',
        RepeatMode.off => 'off',
      };

  RepeatMode _decodeRepeat(String? raw) => switch (raw) {
        'all' => RepeatMode.all,
        'one' => RepeatMode.one,
        _ => RepeatMode.off,
      };

  @override
  String get id => 'shuffle_repeat';

  @override
  String get name => 'Shuffle & Repeat';

  @override
  String get description =>
      'Remembers shuffle and repeat mode across restarts.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    final shuffle = storage.getBool(_shuffleKey) ?? false;
    final repeat = _decodeRepeat(storage.getString(_repeatKey));
    await context?.setShuffleEnabled(shuffle);
    await context?.setRepeatMode(repeat);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> dispose() async {}
}
