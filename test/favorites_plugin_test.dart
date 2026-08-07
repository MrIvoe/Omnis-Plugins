import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage-only behavior — no `PluginContext` needed. `FavoritesPlugin`
/// keeps its state in its own `PluginStorage`, which works even on a
/// bare, unattached instance (see the plugin's own class doc), unlike
/// `context`-gated plugins such as `ShuffleRepeatPlugin`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id) => BaseTrack(
        id: id,
        title: 'T$id',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: TrackType.local,
      );

  test('a track is not a favorite until marked', () {
    final plugin = FavoritesPlugin();
    expect(plugin.isFavorite('t1'), isFalse);
  });

  test('toggleFavorite flips state and persists across a fresh instance',
      () async {
    final plugin = FavoritesPlugin();
    await plugin.toggleFavorite('t1');
    expect(plugin.isFavorite('t1'), isTrue);

    final freshInstance = FavoritesPlugin();
    // A fresh PluginStorage starts cold (its own `_prefs` is null until
    // something awaits it) even though it reads the same underlying
    // SharedPreferences store — warm it explicitly before the
    // synchronous check below.
    await freshInstance.storage.initialize();
    expect(freshInstance.isFavorite('t1'), isTrue);

    await freshInstance.toggleFavorite('t1');
    expect(plugin.isFavorite('t1'), isFalse);
  });

  test(
      'favoritesFrom filters and orders by the input track list, not '
      'insertion order', () async {
    final plugin = FavoritesPlugin();
    final tracks = [track('a'), track('b'), track('c')];

    await plugin.setFavorite('c', true);
    await plugin.setFavorite('a', true);

    final favorites = plugin.favoritesFrom(tracks);
    expect(favorites.map((t) => t.id), ['a', 'c']);
  });

  test('setFavorite(false) on a non-favorite track is a harmless no-op',
      () async {
    final plugin = FavoritesPlugin();
    await plugin.setFavorite('t1', false);
    expect(plugin.isFavorite('t1'), isFalse);
  });

  test('count reflects the number of favorited tracks', () async {
    final plugin = FavoritesPlugin();
    expect(plugin.count, 0);
    await plugin.setFavorite('a', true);
    await plugin.setFavorite('b', true);
    expect(plugin.count, 2);
  });

  test('clearAll un-favorites everything', () async {
    final plugin = FavoritesPlugin();
    await plugin.setFavorite('a', true);
    await plugin.setFavorite('b', true);

    await plugin.clearAll();

    expect(plugin.count, 0);
    expect(plugin.isFavorite('a'), isFalse);
    expect(plugin.isFavorite('b'), isFalse);
  });
}
