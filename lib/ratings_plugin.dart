import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// A 0–5 star rating per track — §9 of the Omnis 2.0 product spec lists
/// "Rating 0–5" alongside Favorite/play count/skip count as part of the
/// built-in listening-history data model.
///
/// Same shape as [FavoritesPlugin] (persists via this plugin's own
/// [MusicPlugin.storage], works on a bare unattached instance), but a
/// rating is a *value* per track, not membership in a set, so it's
/// stored as one JSON object (trackId -> 1..5) under a single key rather
/// than [PluginStorage]'s scalar getters/setters. Decoded defensively,
/// per-entry: a single malformed record must not discard every other
/// track's rating — the same "one bad entry breaks everything" bug
/// found and fixed in several of Omnis's own stores (`LibraryStore`,
/// `PlaylistStore`, `PlayHistoryStore`) this cycle applies just as much
/// here, so it's built in from the start rather than retrofitted later.
class RatingsPlugin extends MusicPlugin {
  static const _ratingsKey = 'ratings_json';

  Map<String, int> _load() {
    final raw = storage.getString(_ratingsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final ratings = <String, int>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! int) continue;
        if (value < 1 || value > 5) continue;
        ratings[key] = value;
      }
      return ratings;
    } catch (_) {
      return {};
    }
  }

  Future<void> _persist(Map<String, int> ratings) =>
      storage.setString(_ratingsKey, jsonEncode(ratings));

  /// A track's rating, or 0 ("unrated") if it has none.
  int ratingOf(String trackId) => _load()[trackId] ?? 0;

  /// Sets [trackId]'s rating. [rating] must be 0 (clears the rating) to 5
  /// inclusive — matches the star-picker UI, where tapping the
  /// already-selected star clears the rating rather than re-setting it.
  Future<void> setRating(String trackId, int rating) async {
    if (rating < 0 || rating > 5) {
      throw ArgumentError.value(rating, 'rating', 'must be 0-5');
    }
    final ratings = _load();
    if (rating == 0) {
      if (ratings.remove(trackId) == null) return;
    } else {
      if (ratings[trackId] == rating) return;
      ratings[trackId] = rating;
    }
    await _persist(ratings);
  }

  /// Clears [trackId]'s rating — equivalent to `setRating(trackId, 0)`,
  /// kept as a named action for callers (e.g. a context-menu "Clear
  /// rating" item) that want to express intent without a magic `0`.
  Future<void> clearRating(String trackId) => setRating(trackId, 0);

  /// Total number of rated tracks, for the settings page.
  int get count => _load().length;

  /// Every track in [tracks] rated at least [minRating] (1-5) — the
  /// building block for a future `rating:>=4` search operator (§6) and
  /// smart-playlist rule (§8), neither of which exist yet; exposed now so
  /// this plugin is ready for them without changing its storage shape
  /// later.
  List<BaseTrack> ratedAtLeast(List<BaseTrack> tracks, int minRating) {
    final ratings = _load();
    return tracks.where((t) => (ratings[t.id] ?? 0) >= minRating).toList();
  }

  /// Un-rates everything. Used by this plugin's own settings page, which
  /// confirms before calling it — there's no undo.
  Future<void> clearAll() async {
    if (_load().isEmpty) return;
    await _persist({});
  }

  @override
  String get id => 'ratings';

  @override
  String get name => 'Ratings';

  @override
  String get description => 'Rate tracks 0-5 stars.';

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
      locationID == 'plugin_settings' ? _RatingsSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {}
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. There's no per-track configuration to speak of (rating is a
/// star picker, not something with modes), so the one real action here
/// is a bulk "clear all," with an explicit confirmation since it can't
/// be undone — same shape as `FavoritesPlugin`'s settings page.
class _RatingsSettings extends StatefulWidget {
  final RatingsPlugin plugin;

  const _RatingsSettings({required this.plugin});

  @override
  State<_RatingsSettings> createState() => _RatingsSettingsState();
}

class _RatingsSettingsState extends State<_RatingsSettings> {
  @override
  Widget build(BuildContext context) {
    final count = widget.plugin.count;
    return Row(
      children: [
        Expanded(
          child: Text(
            count == 0
                ? 'No rated tracks.'
                : '$count rated track${count == 1 ? '' : 's'}.',
          ),
        ),
        if (count > 0)
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear all ratings?'),
                  content: Text(
                      'Removes the rating from all $count tracks. This '
                      'cannot be undone.'),
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
