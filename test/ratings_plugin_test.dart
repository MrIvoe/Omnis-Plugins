import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/ratings_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage-only behavior — no `PluginContext` needed, same as
/// `favorites_plugin_test.dart`.
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

  test('a track is unrated (0) until set', () {
    final plugin = RatingsPlugin();
    expect(plugin.ratingOf('t1'), 0);
  });

  test('setRating persists across a fresh instance', () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('t1', 4);
    expect(plugin.ratingOf('t1'), 4);

    final freshInstance = RatingsPlugin();
    // A fresh PluginStorage starts cold until something awaits it — warm
    // it explicitly before the synchronous check below (same pattern as
    // favorites_plugin_test.dart).
    await freshInstance.storage.initialize();
    expect(freshInstance.ratingOf('t1'), 4);
  });

  test('setRating overwrites a previous rating for the same track',
      () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('t1', 2);
    await plugin.setRating('t1', 5);
    expect(plugin.ratingOf('t1'), 5);
  });

  test('setRating(trackId, 0) clears the rating', () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('t1', 3);
    await plugin.setRating('t1', 0);
    expect(plugin.ratingOf('t1'), 0);
  });

  test('clearRating clears the rating', () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('t1', 3);
    await plugin.clearRating('t1');
    expect(plugin.ratingOf('t1'), 0);
  });

  test('setRating rejects out-of-range values', () async {
    final plugin = RatingsPlugin();
    expect(() => plugin.setRating('t1', -1), throwsArgumentError);
    expect(() => plugin.setRating('t1', 6), throwsArgumentError);
    expect(plugin.ratingOf('t1'), 0,
        reason: 'a rejected call must not partially apply');
  });

  test('setting the same rating twice is a harmless no-op (does not '
      'rewrite storage)', () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('t1', 3);
    // Not asserting on storage writes directly (no hook for that here),
    // just that the value is stable and no exception occurs.
    await plugin.setRating('t1', 3);
    expect(plugin.ratingOf('t1'), 3);
  });

  test('ratings for different tracks do not interfere with each other',
      () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('a', 1);
    await plugin.setRating('b', 5);
    expect(plugin.ratingOf('a'), 1);
    expect(plugin.ratingOf('b'), 5);
    expect(plugin.ratingOf('c'), 0);
  });

  test('count reflects the number of rated tracks', () async {
    final plugin = RatingsPlugin();
    expect(plugin.count, 0);
    await plugin.setRating('a', 3);
    await plugin.setRating('b', 4);
    expect(plugin.count, 2);
  });

  test('clearAll un-rates everything', () async {
    final plugin = RatingsPlugin();
    await plugin.setRating('a', 3);
    await plugin.setRating('b', 4);

    await plugin.clearAll();

    expect(plugin.count, 0);
    expect(plugin.ratingOf('a'), 0);
    expect(plugin.ratingOf('b'), 0);
  });

  group('ratedAtLeast', () {
    test('filters and orders by the input track list, not insertion '
        'order', () async {
      final plugin = RatingsPlugin();
      final tracks = [track('a'), track('b'), track('c')];

      await plugin.setRating('c', 5);
      await plugin.setRating('a', 4);
      await plugin.setRating('b', 2);

      final atLeast4 = plugin.ratedAtLeast(tracks, 4);
      expect(atLeast4.map((t) => t.id), ['a', 'c']);
    });

    test('an unrated track never matches, regardless of minRating',
        () async {
      final plugin = RatingsPlugin();
      final tracks = [track('a')];
      expect(plugin.ratedAtLeast(tracks, 1), isEmpty);
    });
  });

  group('corruption resilience', () {
    test('a single malformed entry among several valid ratings is '
        'skipped, not fatal to the rest', () async {
      final plugin = RatingsPlugin();
      await plugin.storage.setString(
        'ratings_json',
        jsonEncode({
          'good_a': 3,
          'bad_string_value': 'not a number',
          'bad_out_of_range': 9,
          'good_b': 5,
        }),
      );

      expect(plugin.ratingOf('good_a'), 3);
      expect(plugin.ratingOf('good_b'), 5);
      expect(plugin.ratingOf('bad_string_value'), 0);
      expect(plugin.ratingOf('bad_out_of_range'), 0);
    });

    test('completely corrupt JSON degrades to "no ratings", not a '
        'crash', () async {
      final plugin = RatingsPlugin();
      await plugin.storage
          .setString('ratings_json', 'not valid json {{{');

      expect(plugin.ratingOf('t1'), 0);
      expect(plugin.count, 0);
    });

    test('a JSON value that is not an object (e.g. a list) degrades to '
        '"no ratings"', () async {
      final plugin = RatingsPlugin();
      await plugin.storage
          .setString('ratings_json', jsonEncode([1, 2, 3]));

      expect(plugin.count, 0);
    });
  });

  group('IRatingsProvider (item 42)', () {
    test('RatingsPlugin implements IRatingsProvider — reachable by '
        'another plugin through the capability interface, not just as '
        'a concrete RatingsPlugin reference. Full registration/'
        'cross-plugin wiring is exercised in the main Omnis repo\'s '
        'test suite, where a real PluginContext exists.', () {
      expect(RatingsPlugin(), isA<IRatingsProvider>());
    });
  });
}
