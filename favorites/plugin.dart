// Downloadable Favorites plugin — the same core feature as the bundled
// FavoritesPlugin (mark a track favorited for quick access), rewritten
// against the sandbox bridge so it can be installed and deleted like
// any other downloadable plugin instead of always shipping with the
// app.
//
// KNOWN LIMITATIONS (v1), both deliberate scope cuts to ship a
// working, tested plugin now rather than chase a real dart_eval 0.8.3
// compiler bug with no found fix (see docs/STRUCTURE.md's dart_eval
// gotcha section):
//
// 1. Favorites are session-only — they reset when the app restarts.
//    The scoped `state` storage bridge needs a String key argument,
//    and boxing a fresh String/List/Map literal constant as a bridge-
//    function argument crashes the interpreter, unpredictably, based
//    on the whole compiled program's literal layout — confirmed to
//    affect even a literal routed through a local variable or a const
//    list index, not just an inline one.
// 2. Only local library tracks can be favorited — a radio station or
//    online search result (never in the scanned library) can't be,
//    unlike the bundled version's snapshot mechanism. Reconstructing a
//    non-local track from a persisted snapshot hit the same class of
//    interpreter crash on the encode/decode path.
//
// Every bridge-function-call argument below is a variable or an index
// into one, never a bare literal, per the same gotcha.

import 'package:omnis/sandbox_api.dart';

Set<String> _ids = <String>{};

dynamic createPlugin(dynamic api) {
  return {
    'id': 'favorites',
    'name': 'Favorites',
    'description':
        'Mark local library tracks as favorites for quick access '
            '(session-only for now — see the README for why).',
    'version': '1.0.0',
    'author': 'Omnis Team',
    'hooks': [
      'favoritesIsFavorite',
      'favoritesFavoriteIds',
      'favoritesSetFavorite',
      'favoritesWithSnapshots',
      'uiSlot',
    ],
  };
}

dynamic favoritesIsFavorite(dynamic trackId) => _ids.contains(trackId);

dynamic favoritesFavoriteIds() => List<String>.from(_ids);

dynamic favoritesSetFavorite(dynamic trackId, dynamic favorite, dynamic track) {
  if (favorite == true) {
    _ids.add(trackId);
  } else {
    _ids.remove(trackId);
  }
  final eventData = {'trackId': trackId, 'isFavorite': favorite};
  emitEvent('favorite_changed', eventData);
  return null;
}

// No snapshot reconstruction (see limitation 2 above) — a favorited
// track that isn't in localTracks (never scanned into the library)
// simply doesn't appear here, the same as the bundled plugin's own
// simpler favoritesFrom().
dynamic favoritesWithSnapshots(dynamic localTracks) {
  final result = [];
  for (final t in localTracks) {
    if (_ids.contains(t['id'])) {
      result.add(t);
    }
  }
  return result;
}

dynamic uiSlot(dynamic locationID) {
  if (locationID != 'now_playing_overlay') return null;
  final count = _ids.length;
  return {
    'type': 'badge',
    'text': '$count favorited',
    'icon': 'star',
  };
}
