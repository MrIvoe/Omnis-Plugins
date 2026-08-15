import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/events.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// "Like"/"Top rated" -- a track can be marked a favorite, the same basic
/// feature every named competitor has under one name or another (Spotify's
/// heart, Musicolet's "top rated", Poweramp's star).
///
/// Persists via this plugin's own [MusicPlugin.storage] rather than a
/// shared app-settings singleton — this is plugin-private state with no
/// reason to live anywhere else, and `storage` (unlike `context`) works
/// even before this plugin is attached to a `PluginManager`, which is
/// what keeps it usable standalone in tests.
class FavoritesPlugin extends MusicPlugin {
  static const _favoriteTrackIdsKey = 'favorite_track_ids';

  /// A snapshot store keyed by track id, same shape/purpose as
  /// `PlayHistoryStore.TrackPlayStats.trackSnapshot` in the main app —
  /// `favoritesFrom`'s caller-supplied-library lookup only ever finds a
  /// favorited track that's actually in the *scanned local* library, so a
  /// favorited radio station or Spotify/YouTube/Jellyfin/Plex/Subsonic/
  /// DLNA/Emby track was genuinely marked favorite (this plugin's own
  /// `isFavorite`/toggle state was always correct) but silently invisible
  /// in any aggregate "Favorites" list built from a scanned-library join —
  /// the identical root cause `PlayHistoryStore`'s own snapshot fix
  /// already closed for Recently/Most Played. Stored as one JSON blob
  /// (trackId -> `BaseTrack.toJson()`) rather than per-key entries, the
  /// same single-value-per-store-key shape `ScrobblePlugin`'s history
  /// list already uses.
  static const _snapshotsKey = 'favorite_track_snapshots';

  Set<String> get _storedIds =>
      (storage.getStringList(_favoriteTrackIdsKey) ?? const <String>[])
          .toSet();

  Future<void> _persist(Set<String> ids) =>
      storage.setStringList(_favoriteTrackIdsKey, ids.toList());

  Map<String, dynamic> _readSnapshots() {
    final raw = storage.getString(_snapshotsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistSnapshots(Map<String, dynamic> snapshots) =>
      storage.setString(_snapshotsKey, jsonEncode(snapshots));

  bool isFavorite(String trackId) => _storedIds.contains(trackId);

  /// Marks [trackId] favorited/unfavorited. [track], when given, is
  /// captured as a snapshot for later reconstruction by
  /// [favoritesWithSnapshots] — **only** if [track.type] isn't
  /// [TrackType.local] (a local track's full metadata already lives in
  /// the scanned library, so a second copy here would be pure
  /// duplication, the same "only snapshot what the library join can't
  /// already find" rule `PlayHistoryStore.recordPlay` already applies).
  /// Un-favoriting always clears any stored snapshot for [trackId],
  /// [track] or not — a stale snapshot for a track that's no longer
  /// favorited would otherwise leak forever.
  Future<void> setFavorite(String trackId, bool favorite, {BaseTrack? track}) async {
    final ids = _storedIds;
    final changed = favorite ? ids.add(trackId) : ids.remove(trackId);
    if (favorite && track != null && track.type != TrackType.local) {
      final snapshots = _readSnapshots();
      snapshots[trackId] = track.toJson();
      await _persistSnapshots(snapshots);
    } else if (!favorite) {
      final snapshots = _readSnapshots();
      if (snapshots.remove(trackId) != null) {
        await _persistSnapshots(snapshots);
      }
    }
    if (!changed) return;
    await _persist(ids);
    // Lets a favorites-derived view elsewhere in the app (the Playlists
    // page's "Favorites" smart list, kept alive alongside the Library
    // page in the same IndexedStack) refresh immediately instead of only
    // the next time something unrelated happens to rebuild it.
    context?.events.emit(FavoriteChangedEvent(trackId, favorite));
  }

  Future<void> toggleFavorite(String trackId, {BaseTrack? track}) =>
      setFavorite(trackId, !isFavorite(trackId), track: track);

  /// Total number of favorited tracks, for the settings page — cheaper
  /// than callers reading the raw id set themselves.
  int get count => _storedIds.length;

  /// Un-favorites everything. Used by this plugin's own settings page,
  /// which confirms before calling it — there's no undo.
  Future<void> clearAll() async {
    final ids = _storedIds;
    if (ids.isEmpty) return;
    await _persist({});
    await _persistSnapshots({});
    for (final id in ids) {
      context?.events.emit(FavoriteChangedEvent(id, false));
    }
  }

  /// Every favorited track, filtered from and in the order of [tracks] --
  /// callers hand in the current library rather than this plugin owning
  /// its own copy of track data, the same pattern
  /// `SmartPlaylistPlugin.buildQueue` uses.
  ///
  /// Local-library-only: a favorited track that isn't in [tracks] (a
  /// station, a streaming-service track — anything never scanned into the
  /// local library) is silently absent here. See [favoritesWithSnapshots]
  /// for the version that also surfaces those.
  List<BaseTrack> favoritesFrom(List<BaseTrack> tracks) {
    final ids = _storedIds;
    if (ids.isEmpty) return const [];
    return tracks.where((t) => ids.contains(t.id)).toList();
  }

  /// Every favorited track, in favorited order: a scanned-library match
  /// from [localTracks] when there is one (always the freshest data —
  /// tags may have changed since a track was favorited), otherwise a
  /// reconstruction from the snapshot [setFavorite] captured when it was
  /// favorited. A favorited local track that's since been deleted, or a
  /// non-local one favorited before this snapshot mechanism existed (no
  /// snapshot on file), is silently skipped rather than producing a
  /// broken entry — the same per-entry-defensive stance every other
  /// JSON-backed store/snapshot in this app already takes.
  List<BaseTrack> favoritesWithSnapshots(List<BaseTrack> localTracks) {
    final ids = storage.getStringList(_favoriteTrackIdsKey) ?? const <String>[];
    if (ids.isEmpty) return const [];
    final byId = {for (final t in localTracks) t.id: t};
    final snapshots = _readSnapshots();
    final result = <BaseTrack>[];
    for (final id in ids) {
      final local = byId[id];
      if (local != null) {
        result.add(local);
        continue;
      }
      final snapshot = snapshots[id];
      if (snapshot is Map) {
        try {
          result.add(BaseTrack.fromJson(Map<String, dynamic>.from(snapshot)));
        } catch (_) {
          // Corrupt snapshot — skip this one entry, not the whole list.
        }
      }
    }
    return result;
  }

  @override
  String get id => 'favorites';

  @override
  String get name => 'Favorites';

  @override
  String get description => 'Mark tracks as favorites for quick access.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _FavoritesSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {}
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. There's no per-track configuration to speak of (favoriting is a
/// heart-icon toggle, not something with modes), so the one real action
/// here is a bulk "clear all," with an explicit confirmation since it
/// can't be undone.
class _FavoritesSettings extends StatefulWidget {
  final FavoritesPlugin plugin;

  const _FavoritesSettings({required this.plugin});

  @override
  State<_FavoritesSettings> createState() => _FavoritesSettingsState();
}

class _FavoritesSettingsState extends State<_FavoritesSettings> {
  @override
  Widget build(BuildContext context) {
    final count = widget.plugin.count;
    return Row(
      children: [
        Expanded(
          child: Text(
            count == 0
                ? 'No favorited tracks.'
                : '$count favorited track${count == 1 ? '' : 's'}.',
          ),
        ),
        if (count > 0)
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear all favorites?'),
                  content: Text(
                      'Un-favorites all $count tracks. This cannot be '
                      'undone.'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await widget.plugin.clearAll();
                if (mounted) setState(() {});
              }
            },
            child: const Text('Clear all'),
          ),
      ],
    );
  }
}
