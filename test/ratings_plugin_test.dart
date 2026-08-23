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

  group('half-star ratings (item 15, MusicBee comparison §36)', () {
    test('preciseRatingOf returns 0.0 for an unrated track', () {
      final plugin = RatingsPlugin();
      expect(plugin.preciseRatingOf('t1'), 0.0);
    });

    test('setPreciseRating persists an exact half-star value', () async {
      final plugin = RatingsPlugin();
      await plugin.setPreciseRating('t1', 4.5);
      expect(plugin.preciseRatingOf('t1'), 4.5);
    });

    test('setPreciseRating persists across a fresh instance', () async {
      final plugin = RatingsPlugin();
      await plugin.setPreciseRating('t1', 3.5);

      final freshInstance = RatingsPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.preciseRatingOf('t1'), 3.5);
    });

    test('setPreciseRating rejects a non-half-step value', () async {
      final plugin = RatingsPlugin();
      expect(() => plugin.setPreciseRating('t1', 4.3), throwsArgumentError);
      expect(plugin.preciseRatingOf('t1'), 0.0,
          reason: 'a rejected call must not partially apply');
    });

    test('setPreciseRating rejects out-of-range values', () async {
      final plugin = RatingsPlugin();
      expect(() => plugin.setPreciseRating('t1', -0.5), throwsArgumentError);
      expect(() => plugin.setPreciseRating('t1', 5.5), throwsArgumentError);
      expect(plugin.preciseRatingOf('t1'), 0.0);
    });

    test('setPreciseRating(trackId, 0) clears the rating', () async {
      final plugin = RatingsPlugin();
      await plugin.setPreciseRating('t1', 2.5);
      await plugin.setPreciseRating('t1', 0);
      expect(plugin.preciseRatingOf('t1'), 0.0);
    });

    test('ratingOf rounds a half-star value to the nearest whole star '
        'for the IRatingsProvider (int) contract', () async {
      final plugin = RatingsPlugin();
      await plugin.setPreciseRating('t1', 4.5);
      expect(plugin.ratingOf('t1'), 5, reason: 'round-half-up');

      await plugin.setPreciseRating('t2', 2.5);
      expect(plugin.ratingOf('t2'), 3);
    });

    test('a whole-star rating set via the legacy setRating(int) reads '
        'back identically through preciseRatingOf', () async {
      final plugin = RatingsPlugin();
      await plugin.setRating('t1', 4);
      expect(plugin.preciseRatingOf('t1'), 4.0);
      expect(plugin.ratingOf('t1'), 4);
    });

    test('legacy on-disk data written as a whole JSON int (the shape '
        'every rating predates half-stars with) still loads correctly '
        'through both ratingOf and preciseRatingOf', () async {
      final plugin = RatingsPlugin();
      await plugin.storage.setString(
        'ratings_json',
        jsonEncode({'legacy': 4}),
      );

      expect(plugin.ratingOf('legacy'), 4);
      expect(plugin.preciseRatingOf('legacy'), 4.0);
    });

    test('a stored non-half-step double (corrupted data) is dropped, '
        'not surfaced as a bogus rating', () async {
      final plugin = RatingsPlugin();
      await plugin.storage.setString(
        'ratings_json',
        jsonEncode({'good': 4.5, 'bad': 4.3}),
      );

      expect(plugin.preciseRatingOf('good'), 4.5);
      expect(plugin.preciseRatingOf('bad'), 0.0);
    });

    test('setting the exact same precise rating twice is a harmless '
        'no-op', () async {
      final plugin = RatingsPlugin();
      await plugin.setPreciseRating('t1', 3.5);
      await plugin.setPreciseRating('t1', 3.5);
      expect(plugin.preciseRatingOf('t1'), 3.5);
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

  group('thumbs up/down (item 36, MusicBee comparison §36)', () {
    test('a track has ThumbState.none until set', () {
      final plugin = RatingsPlugin();
      expect(plugin.thumbOf('t1'), ThumbState.none);
    });

    test('setThumb persists across a fresh instance', () async {
      final plugin = RatingsPlugin();
      await plugin.setThumb('t1', ThumbState.up);
      expect(plugin.thumbOf('t1'), ThumbState.up);

      final freshInstance = RatingsPlugin();
      await freshInstance.storage.initialize();
      expect(freshInstance.thumbOf('t1'), ThumbState.up);
    });

    test('setThumb(down) overwrites a previous up, and vice versa',
        () async {
      final plugin = RatingsPlugin();
      await plugin.setThumb('t1', ThumbState.up);
      await plugin.setThumb('t1', ThumbState.down);
      expect(plugin.thumbOf('t1'), ThumbState.down);

      await plugin.setThumb('t1', ThumbState.up);
      expect(plugin.thumbOf('t1'), ThumbState.up);
    });

    test('setThumb(none) clears an existing thumb', () async {
      final plugin = RatingsPlugin();
      await plugin.setThumb('t1', ThumbState.up);
      await plugin.setThumb('t1', ThumbState.none);
      expect(plugin.thumbOf('t1'), ThumbState.none);
    });

    test('setting the same state twice is a harmless no-op', () async {
      final plugin = RatingsPlugin();
      await plugin.setThumb('t1', ThumbState.down);
      await plugin.setThumb('t1', ThumbState.down);
      expect(plugin.thumbOf('t1'), ThumbState.down);
    });

    test('thumbs and star ratings are independent signals for the same '
        'track', () async {
      final plugin = RatingsPlugin();
      await plugin.setRating('t1', 5);
      await plugin.setThumb('t1', ThumbState.down);

      expect(plugin.ratingOf('t1'), 5,
          reason: 'thumbing down must not touch the star rating');
      expect(plugin.thumbOf('t1'), ThumbState.down);
    });

    test('thumbs for different tracks do not interfere with each other',
        () async {
      final plugin = RatingsPlugin();
      await plugin.setThumb('a', ThumbState.up);
      await plugin.setThumb('b', ThumbState.down);

      expect(plugin.thumbOf('a'), ThumbState.up);
      expect(plugin.thumbOf('b'), ThumbState.down);
      expect(plugin.thumbOf('c'), ThumbState.none);
    });

    test('thumbCount reflects the number of thumbed tracks', () async {
      final plugin = RatingsPlugin();
      expect(plugin.thumbCount, 0);
      await plugin.setThumb('a', ThumbState.up);
      await plugin.setThumb('b', ThumbState.down);
      expect(plugin.thumbCount, 2);
    });

    test('clearAll clears both ratings and thumbs', () async {
      final plugin = RatingsPlugin();
      await plugin.setRating('a', 3);
      await plugin.setThumb('a', ThumbState.up);
      await plugin.setThumb('b', ThumbState.down);

      await plugin.clearAll();

      expect(plugin.count, 0);
      expect(plugin.thumbCount, 0);
      expect(plugin.thumbOf('a'), ThumbState.none);
      expect(plugin.thumbOf('b'), ThumbState.none);
    });

    group('corruption resilience', () {
      test('a single malformed entry among several valid thumbs is '
          'skipped, not fatal to the rest', () async {
        final plugin = RatingsPlugin();
        await plugin.storage.setString(
          'thumbs_json',
          jsonEncode({
            'good_up': 1,
            'bad_string_value': 'not a number',
            'bad_out_of_range': 9,
            'good_down': -1,
          }),
        );

        expect(plugin.thumbOf('good_up'), ThumbState.up);
        expect(plugin.thumbOf('good_down'), ThumbState.down);
        expect(plugin.thumbOf('bad_string_value'), ThumbState.none);
        expect(plugin.thumbOf('bad_out_of_range'), ThumbState.none);
      });

      test('completely corrupt JSON degrades to "no thumbs", not a '
          'crash', () async {
        final plugin = RatingsPlugin();
        await plugin.storage
            .setString('thumbs_json', 'not valid json {{{');

        expect(plugin.thumbOf('t1'), ThumbState.none);
        expect(plugin.thumbCount, 0);
      });

      test('a JSON value that is not an object (e.g. a list) degrades '
          'to "no thumbs"', () async {
        final plugin = RatingsPlugin();
        await plugin.storage.setString('thumbs_json', jsonEncode([1, 2, 3]));

        expect(plugin.thumbCount, 0);
      });
    });

    test('RatingsPlugin implements IThumbsProvider — reachable by '
        'another plugin through the capability interface, not just as '
        'a concrete RatingsPlugin reference.', () {
      expect(RatingsPlugin(), isA<IThumbsProvider>());
    });
  });

  test('RatingsPlugin satisfies IRatingsProvider and IThumbsProvider', () {
    final plugin = RatingsPlugin();
    expect(plugin, isA<IRatingsProvider>());
    expect(plugin, isA<IThumbsProvider>());
  });
}
