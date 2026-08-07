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

  Set<String> get _storedIds =>
      (storage.getStringList(_favoriteTrackIdsKey) ?? const <String>[])
          .toSet();

  Future<void> _persist(Set<String> ids) =>
      storage.setStringList(_favoriteTrackIdsKey, ids.toList());

  bool isFavorite(String trackId) => _storedIds.contains(trackId);

  Future<void> setFavorite(String trackId, bool favorite) async {
    final ids = _storedIds;
    final changed = favorite ? ids.add(trackId) : ids.remove(trackId);
    if (!changed) return;
    await _persist(ids);
    // Lets a favorites-derived view elsewhere in the app (the Playlists
    // page's "Favorites" smart list, kept alive alongside the Library
    // page in the same IndexedStack) refresh immediately instead of only
    // the next time something unrelated happens to rebuild it.
    context?.events.emit(FavoriteChangedEvent(trackId, favorite));
  }

  Future<void> toggleFavorite(String trackId) =>
      setFavorite(trackId, !isFavorite(trackId));

  /// Total number of favorited tracks, for the settings page — cheaper
  /// than callers reading the raw id set themselves.
  int get count => _storedIds.length;

  /// Un-favorites everything. Used by this plugin's own settings page,
  /// which confirms before calling it — there's no undo.
  Future<void> clearAll() async {
    final ids = _storedIds;
    if (ids.isEmpty) return;
    await _persist({});
    for (final id in ids) {
      context?.events.emit(FavoriteChangedEvent(id, false));
    }
  }

  /// Every favorited track, filtered from and in the order of [tracks] --
  /// callers hand in the current library rather than this plugin owning
  /// its own copy of track data, the same pattern
  /// `SmartPlaylistPlugin.buildQueue` uses.
  List<BaseTrack> favoritesFrom(List<BaseTrack> tracks) {
    final ids = _storedIds;
    if (ids.isEmpty) return const [];
    return tracks.where((t) => ids.contains(t.id)).toList();
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
