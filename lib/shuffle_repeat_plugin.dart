import 'package:omnis_plugin_api/repeat_mode.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Shuffle and repeat mode — the Core Philosophy doc lists "Shuffle
/// Algorithms" explicitly under Layer 3 (Plugin Ecosystem), not Layer 2
/// (Player Runtime): repeat-mode handling stays a thin call into
/// [PluginContext] (`setRepeatMode` just forwards to just_audio's own loop
/// mode, which is where it has to live to stay consistent with
/// just_audio's gapless auto-advance — see `AudioEngine`'s doc), but
/// shuffle *order* is this plugin's own algorithm, not just_audio's plain
/// shuffle — see [toggleShuffle].
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

  /// Whether shuffle is currently on. Tracked here, not read from the
  /// engine — since shuffle re-orders the queue itself rather than
  /// delegating to just_audio's own shuffle mode (see [toggleShuffle]),
  /// the engine's own shuffle flag is never set and isn't the source of
  /// truth.
  bool _shuffleOn = false;
  bool get shuffleEnabled => _shuffleOn;

  /// The queue as it was immediately before the most recent shuffle, so
  /// turning shuffle back off restores the original order instead of
  /// leaving it scrambled. `null` when shuffle has never been turned on
  /// this session.
  List<BaseTrack>? _preShuffleQueue;

  /// The current repeat mode. Reads live from the engine.
  RepeatMode get repeatMode => context?.repeatMode ?? RepeatMode.off;

  /// Flips shuffle and persists the new state.
  ///
  /// Unlike a plain `List.shuffle()` (or just_audio's own shuffle mode,
  /// which is what this used to delegate to), this avoids placing two
  /// tracks by the same artist or from the same album back-to-back where
  /// avoidable — the difference between a shuffle that still feels like
  /// "the last three songs were all from one album" and one that
  /// actually reads as varied. Turning shuffle back off restores the
  /// exact pre-shuffle order.
  Future<void> toggleShuffle() async {
    final ctx = context;
    _shuffleOn = !_shuffleOn;
    await storage.setBool(_shuffleKey, _shuffleOn);
    if (ctx == null) return;

    if (_shuffleOn) {
      final current = List<BaseTrack>.from(ctx.queue);
      _preShuffleQueue = current;
      final reordered = deClusteredOrder(current);
      final currentTrack = ctx.currentTrack;
      final startIndex = currentTrack == null
          ? 0
          : reordered.indexWhere((t) => t.id == currentTrack.id).clamp(0,
              reordered.isEmpty ? 0 : reordered.length - 1);
      if (reordered.isNotEmpty) {
        await ctx.setQueue(reordered, startIndex: startIndex);
      }
    } else {
      final original = _preShuffleQueue;
      _preShuffleQueue = null;
      if (original != null && original.isNotEmpty) {
        final currentTrack = ctx.currentTrack;
        final startIndex = currentTrack == null
            ? 0
            : original.indexWhere((t) => t.id == currentTrack.id).clamp(
                0, original.length - 1);
        await ctx.setQueue(original, startIndex: startIndex);
      }
    }
  }

  /// Re-orders [tracks] to avoid adjacent same-artist/same-album pairs
  /// where avoidable. Two stages:
  ///
  ///  1. Group by primary artist, then round-robin-interleave the groups,
  ///     always placing next from whichever remaining group is largest
  ///     and isn't the one just placed. This is the standard
  ///     "reorganize so no two adjacent items share a key" greedy
  ///     strategy, and it provably produces zero adjacent same-artist
  ///     pairs whenever that's achievable at all — i.e. whenever no
  ///     single artist makes up more than half the tracks. (When one
  ///     artist genuinely dominates the list, some adjacency is
  ///     mathematically unavoidable; the interleave still minimizes it.)
  ///  2. A local-swap pass for same-album adjacency, which the
  ///     artist-only interleave doesn't account for. This one is
  ///     genuinely best-effort — album grouping is a second, independent
  ///     dimension the interleave doesn't guarantee anything about — but
  ///     it never undoes stage 1's guarantee, since every candidate swap
  ///     is re-checked against both artist and album before being taken.
  static List<BaseTrack> deClusteredOrder(List<BaseTrack> tracks) {
    if (tracks.length < 3) return List.of(tracks);

    final byArtist = <String, List<BaseTrack>>{};
    for (final t in tracks) {
      final key = t.artists.isNotEmpty ? t.artists.first : t.id;
      byArtist.putIfAbsent(key, () => []).add(t);
    }
    final groups = byArtist.values
        .map((g) => List<BaseTrack>.from(g)..shuffle())
        .toList()
      ..shuffle();

    final result = <BaseTrack>[];
    String? lastArtistKey;
    while (result.length < tracks.length) {
      groups.sort((a, b) => b.length.compareTo(a.length));
      var pickIndex = -1;
      for (var i = 0; i < groups.length; i++) {
        if (groups[i].isEmpty) continue;
        final key = groups[i].first.artists.isNotEmpty
            ? groups[i].first.artists.first
            : groups[i].first.id;
        if (key != lastArtistKey) {
          pickIndex = i;
          break;
        }
      }
      // Every remaining group matches lastArtistKey — only possible once
      // a single artist's tracks are the only ones left, so no safe
      // choice exists. Take the largest remaining group anyway.
      if (pickIndex == -1) {
        pickIndex = groups.indexWhere((g) => g.isNotEmpty);
      }
      final track = groups[pickIndex].removeAt(0);
      result.add(track);
      lastArtistKey = track.artists.isNotEmpty ? track.artists.first : track.id;
    }

    for (var i = 1; i < result.length; i++) {
      if (!_conflicts(result[i - 1], result[i])) continue;
      for (var j = i + 1; j < result.length; j++) {
        if (!_swapIsSafe(result, i, j)) continue;
        final tmp = result[i];
        result[i] = result[j];
        result[j] = tmp;
        break;
      }
    }
    return result;
  }

  /// Whether swapping the tracks at [i] and [j] (i < j) leaves every
  /// *changed* neighbor pair conflict-free — not just the pair at [i]
  /// that motivated the swap. Checking only one side would risk fixing
  /// one adjacency by silently creating another, which could even
  /// reintroduce a same-artist pair the round-robin interleave already
  /// eliminated — this is what keeps stage 2 from ever undoing stage 1's
  /// guarantee.
  static bool _swapIsSafe(List<BaseTrack> list, int i, int j) {
    final newAtI = list[j];
    final newAtJ = list[i];
    if (_conflicts(list[i - 1], newAtI)) return false;
    if (i + 1 < list.length && i + 1 != j && _conflicts(newAtI, list[i + 1])) {
      return false;
    }
    if (j - 1 != i && _conflicts(list[j - 1], newAtJ)) return false;
    if (j + 1 < list.length && _conflicts(newAtJ, list[j + 1])) return false;
    // Adjacent swap (j == i + 1): newAtI and newAtJ become each other's
    // neighbor, a pair none of the checks above cover.
    if (j == i + 1 && _conflicts(newAtI, newAtJ)) return false;
    return true;
  }

  /// Two tracks "conflict" for shuffle-adjacency purposes if they share a
  /// primary artist or an album (ignoring "Unknown Album", which isn't a
  /// real album grouping).
  static bool _conflicts(BaseTrack a, BaseTrack b) {
    final sameArtist = a.artists.isNotEmpty &&
        b.artists.isNotEmpty &&
        a.artists.first == b.artists.first;
    final sameAlbum = a.album.isNotEmpty &&
        a.album != 'Unknown Album' &&
        a.album == b.album;
    return sameArtist || sameAlbum;
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
    _shuffleOn = storage.getBool(_shuffleKey) ?? false;
    final repeat = _decodeRepeat(storage.getString(_repeatKey));
    await context?.setRepeatMode(repeat);
    // Deliberately not re-shuffling the queue here: at plugin-init time
    // the real library/queue usually isn't loaded into the engine yet
    // (that happens later, once the library scan/restore finishes), so
    // there's nothing meaningful to reorder. _shuffleOn still restores
    // correctly for the UI toggle; the next toggleShuffle() call (or a
    // future explicit "reshuffle" hook) does the actual reordering
    // against whatever queue exists by then.
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
