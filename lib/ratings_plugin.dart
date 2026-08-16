import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

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
class RatingsPlugin extends MusicPlugin
    implements IRatingsProvider, IThumbsProvider {
  static const _ratingsKey = 'ratings_json';

  /// A track's thumbs-up/down preference — MusicBee comparison §36:
  /// distinct from the 0-5 star rating above, a coarse "yes/no" signal
  /// some listeners prefer over picking a specific star count. Stored as
  /// a second JSON map (trackId -> `1` for up, `-1` for down; absent
  /// means [ThumbState.none]) rather than folded into the ratings map,
  /// since a track can be thumbed without ever being star-rated and vice
  /// versa — these are two independent signals, not one field with two
  /// representations.
  static const _thumbsKey = 'thumbs_json';

  /// Internal storage is `double`, not `int` — MusicBee comparison §36's
  /// "half stars" gap: a rating like `4.5` needs to be representable at
  /// all, and a whole-star value is just the degenerate case of the same
  /// range. A pre-existing on-disk record decodes its value as a JSON
  /// `int` (`4`, not `4.0`) — accepted here and promoted to `4.0`, so
  /// every rating ever saved before half-stars existed keeps working
  /// unchanged. Only exact half-steps (`0.5` increments) are accepted;
  /// anything else (a stray `4.3`, a corrupted value) is dropped the
  /// same "one bad entry doesn't break the rest" way an out-of-range
  /// value already was.
  Map<String, double> _load() {
    final raw = storage.getString(_ratingsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final ratings = <String, double>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) continue;
        double? rating;
        if (value is int) {
          rating = value.toDouble();
        } else if (value is double) {
          rating = value;
        } else {
          continue;
        }
        if (!_isValidRating(rating)) continue;
        ratings[key] = rating;
      }
      return ratings;
    } catch (_) {
      return {};
    }
  }

  /// `0.5`-`5.0` in exact half-steps (`0` itself is "unrated," never
  /// stored — same convention [setPreciseRating] already enforces at the
  /// write path).
  static bool _isValidRating(double rating) =>
      rating >= 0.5 && rating <= 5 && (rating * 2) == (rating * 2).roundToDouble();

  Future<void> _persist(Map<String, double> ratings) =>
      storage.setString(_ratingsKey, jsonEncode(ratings));

  Map<String, int> _loadThumbs() {
    final raw = storage.getString(_thumbsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final thumbs = <String, int>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! int) continue;
        if (value != 1 && value != -1) continue;
        thumbs[key] = value;
      }
      return thumbs;
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistThumbs(Map<String, int> thumbs) =>
      storage.setString(_thumbsKey, jsonEncode(thumbs));

  /// [trackId]'s thumb state, or [ThumbState.none] if it's never been
  /// thumbed.
  @override
  ThumbState thumbOf(String trackId) {
    switch (_loadThumbs()[trackId]) {
      case 1:
        return ThumbState.up;
      case -1:
        return ThumbState.down;
      default:
        return ThumbState.none;
    }
  }

  /// Sets [trackId]'s thumb state. Setting [ThumbState.none] clears it —
  /// the UI's own toggle behavior (tapping the already-active thumb
  /// clears it) is expressed by the caller re-passing the current state
  /// as `none`, the same "tap the already-selected value to clear"
  /// convention [setRating] already uses for stars.
  Future<void> setThumb(String trackId, ThumbState state) async {
    final thumbs = _loadThumbs();
    switch (state) {
      case ThumbState.none:
        if (thumbs.remove(trackId) == null) return;
      case ThumbState.up:
        if (thumbs[trackId] == 1) return;
        thumbs[trackId] = 1;
      case ThumbState.down:
        if (thumbs[trackId] == -1) return;
        thumbs[trackId] = -1;
    }
    await _persistThumbs(thumbs);
  }

  /// A track's rating rounded to the nearest whole star, or 0
  /// ("unrated") if it has none — the [IRatingsProvider] interface
  /// contract stays `int` (every existing caller, e.g. `rating:`
  /// search/smart-playlist conditions, works in whole stars), so a
  /// half-star value like `4.5` rounds rather than truncating,
  /// `.round()`'s own standard "round half up" behavior.
  @override
  int ratingOf(String trackId) => (_load()[trackId] ?? 0).round();

  /// A track's exact rating, including a half-star value if it has one —
  /// `0.0` if unrated. The precise counterpart to [ratingOf]: the
  /// star-picker UI reads this, not the rounded whole-star value.
  double preciseRatingOf(String trackId) => _load()[trackId] ?? 0.0;

  /// Sets [trackId]'s rating to a whole number of stars. [rating] must be
  /// 0 (clears the rating) to 5 inclusive — matches the pre-half-star
  /// picker convention, kept as-is for any caller that only ever deals
  /// in whole stars. A thin wrapper over [setPreciseRating].
  Future<void> setRating(String trackId, int rating) async {
    if (rating < 0 || rating > 5) {
      throw ArgumentError.value(rating, 'rating', 'must be 0-5');
    }
    await setPreciseRating(trackId, rating.toDouble());
  }

  /// Sets [trackId]'s rating to an exact value, including a half-star.
  /// [rating] must be 0 (clears the rating) to 5 inclusive, in exact
  /// `0.5` steps — the same [_isValidRating] boundary [_load] itself
  /// enforces when reading stored data back.
  Future<void> setPreciseRating(String trackId, double rating) async {
    if (rating != 0 && !_isValidRating(rating)) {
      throw ArgumentError.value(
          rating, 'rating', 'must be 0-5 in 0.5 steps');
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

  /// Total number of thumbed (up or down) tracks, for the settings page.
  int get thumbCount => _loadThumbs().length;

  /// Every track in [tracks] rated at least [minRating] (1-5) — real
  /// consumers now exist for both cases this was originally written
  /// ahead of: the Omnis app's own `rating:>=4` search qualifier
  /// (`lib/core/library_search.dart`) calls [ratingOf] directly rather
  /// than this helper (it filters its own already-loaded track list),
  /// and `SmartPlaylistPlugin`'s rule engine reaches [ratingOf] through
  /// the newly-registered [IRatingsProvider] interface below, not a
  /// direct reference to this plugin.
  List<BaseTrack> ratedAtLeast(List<BaseTrack> tracks, int minRating) {
    final ratings = _load();
    return tracks.where((t) => (ratings[t.id] ?? 0) >= minRating).toList();
  }

  /// Un-rates everything **and** clears every thumb — used by this
  /// plugin's own settings page, which confirms before calling it —
  /// there's no undo. Both signals are wiped together since the
  /// settings page's own "Clear all" action doesn't distinguish them
  /// (see [_RatingsSettingsState] — a plain single confirmation, not a
  /// per-signal choice).
  Future<void> clearAll() async {
    final hadRatings = _load().isNotEmpty;
    final hadThumbs = _loadThumbs().isNotEmpty;
    if (hadRatings) await _persist({});
    if (hadThumbs) await _persistThumbs({});
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
  Future<void> initialize() async {
    context?.services.register(IRatingsProvider, this);
    context?.services.register(IThumbsProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _RatingsSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    context?.services.register(IRatingsProvider, this);
    context?.services.register(IThumbsProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IRatingsProvider, this);
    context?.services.unregister(IThumbsProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IRatingsProvider, this);
    context?.services.unregister(IThumbsProvider, this);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. There's no per-track configuration to speak of (rating/thumbs
/// are pickers, not something with modes), so the one real action here
/// is a bulk "clear all" — wiping both signals together, since they
/// share one plugin and one confirmation — with an explicit confirmation
/// since it can't be undone — same shape as `FavoritesPlugin`'s settings
/// page.
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
    final thumbCount = widget.plugin.thumbCount;
    final total = count + thumbCount;
    return Row(
      children: [
        Expanded(
          child: Text(
            total == 0
                ? 'No rated or thumbed tracks.'
                : '$count rated track${count == 1 ? '' : 's'}, '
                    '$thumbCount thumbed.',
          ),
        ),
        if (total > 0)
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear all ratings and thumbs?'),
                  content: Text(
                      'Removes every star rating and thumbs up/down. This '
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
