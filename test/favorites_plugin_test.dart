import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/favorites_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only `services` is stubbed — the only context member this plugin's
/// lifecycle touches, same "stub only what's used" shape
/// `replay_gain_plugin_test.dart`'s `_FakeContext` already establishes.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

/// Storage-only behavior — no `PluginContext` needed. `FavoritesPlugin`
/// keeps its state in its own `PluginStorage`, which works even on a
/// bare, unattached instance (see the plugin's own class doc), unlike
/// `context`-gated plugins such as `ShuffleRepeatPlugin`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track(String id, {TrackType type = TrackType.local}) => BaseTrack(
        id: id,
        title: 'T$id',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: type,
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

  group('favoritesWithSnapshots', () {
    test('empty favorites returns empty', () {
      final plugin = FavoritesPlugin();
      expect(plugin.favoritesWithSnapshots(const []), isEmpty);
    });

    test('a scanned-library track is returned from the library, no '
        'snapshot needed', () async {
      final plugin = FavoritesPlugin();
      final a = track('a');
      await plugin.setFavorite('a', true, track: a);
      expect(plugin.favoritesWithSnapshots([a]).map((t) => t.id), ['a']);
    });

    test('a non-local favorited track absent from the local library is '
        'still surfaced, reconstructed from its snapshot', () async {
      final plugin = FavoritesPlugin();
      final station = track('radio:1', type: TrackType.radio);
      await plugin.setFavorite(station.id, true, track: station);

      final result = plugin.favoritesWithSnapshots(const []);
      expect(result, hasLength(1));
      expect(result.single.id, 'radio:1');
      expect(result.single.type, TrackType.radio);
      expect(result.single.title, station.title);
    });

    test('a local track passed as `track:` never gets a snapshot stored — '
        'if it later disappears from the library it is silently dropped, '
        'not resurrected from a snapshot', () async {
      final plugin = FavoritesPlugin();
      final a = track('a'); // TrackType.local
      await plugin.setFavorite('a', true, track: a);

      expect(plugin.favoritesWithSnapshots(const []), isEmpty);
    });

    test('a live library match takes precedence over a stored snapshot for '
        'the same id', () async {
      final plugin = FavoritesPlugin();
      final station = track('x', type: TrackType.radio);
      await plugin.setFavorite('x', true, track: station);

      final freshLibraryCopy = BaseTrack(
        id: 'x',
        title: 'Updated title',
        artists: const ['Artist'],
        album: 'Album',
        duration: 180,
        type: TrackType.local,
      );
      final result = plugin.favoritesWithSnapshots([freshLibraryCopy]);
      expect(result.single.title, 'Updated title');
    });

    test('un-favoriting clears the stored snapshot — re-favoriting the '
        'same id without passing a track again does not resurrect the '
        'old snapshot', () async {
      final plugin = FavoritesPlugin();
      final station = track('radio:1', type: TrackType.radio);
      await plugin.setFavorite(station.id, true, track: station);
      await plugin.setFavorite(station.id, false);
      await plugin.setFavorite(station.id, true); // no track: this time

      expect(plugin.favoritesWithSnapshots(const []), isEmpty);
    });

    test('clearAll also wipes stored snapshots, not just the id list',
        () async {
      final plugin = FavoritesPlugin();
      final station = track('radio:1', type: TrackType.radio);
      await plugin.setFavorite(station.id, true, track: station);

      await plugin.clearAll();
      await plugin.setFavorite(station.id, true); // no track: this time

      expect(plugin.favoritesWithSnapshots(const []), isEmpty);
    });

    test('results are ordered by favorite order, mixing local and '
        'reconstructed-from-snapshot tracks', () async {
      final plugin = FavoritesPlugin();
      final local = track('local1');
      final station = track('radio:1', type: TrackType.radio);
      await plugin.setFavorite(station.id, true, track: station);
      await plugin.setFavorite('local1', true, track: local);

      final result = plugin.favoritesWithSnapshots([local]);
      expect(result.map((t) => t.id), ['radio:1', 'local1']);
    });

    test('a corrupted snapshot entry is skipped rather than breaking the '
        'whole list', () async {
      final plugin = FavoritesPlugin();
      final good = track('good', type: TrackType.radio);
      await plugin.setFavorite('good', true, track: good);
      await plugin.setFavorite('corrupt', true);
      // Manually corrupt just the 'corrupt' entry's snapshot underneath
      // the plugin, simulating a malformed/partial write.
      await plugin.storage.setString(
        'favorite_track_snapshots',
        jsonEncode({
          'good': good.toJson(),
          'corrupt': {'title': 'no id or type'},
        }),
      );

      final result = plugin.favoritesWithSnapshots(const []);
      expect(result.map((t) => t.id), ['good']);
    });

    test('a fresh instance reconstructs snapshots after a cold-storage '
        'warm-up, same as the id list does', () async {
      final plugin = FavoritesPlugin();
      final station = track('radio:1', type: TrackType.radio);
      await plugin.setFavorite(station.id, true, track: station);

      final fresh = FavoritesPlugin();
      await fresh.storage.initialize();
      final result = fresh.favoritesWithSnapshots(const []);
      expect(result.map((t) => t.id), ['radio:1']);
    });
  });

  group('IFavoritesProvider', () {
    test('favoriteIds returns ids in favorited order, empty when nothing '
        'is favorited', () async {
      final plugin = FavoritesPlugin();
      expect(plugin.favoriteIds(), isEmpty);

      await plugin.setFavorite('b', true);
      await plugin.setFavorite('a', true);
      expect(plugin.favoriteIds(), ['b', 'a']);
    });

    test('favoriteIds drops an id once un-favorited', () async {
      final plugin = FavoritesPlugin();
      await plugin.setFavorite('a', true);
      await plugin.setFavorite('b', true);
      await plugin.setFavorite('a', false);
      expect(plugin.favoriteIds(), ['b']);
    });

    test('initialize registers IFavoritesProvider; dispose unregisters it',
        () async {
      final plugin = FavoritesPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isTrue);
      expect(ctx.servicesRegistry.get<IFavoritesProvider>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = FavoritesPlugin();
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IFavoritesProvider>(), isTrue);
    });

    test('initialize/enable/disable/dispose are no-ops without an '
        'attached context', () async {
      final plugin = FavoritesPlugin();
      await plugin.initialize();
      await plugin.enable();
      await plugin.disable();
      await plugin.dispose();
    });
  });
}
