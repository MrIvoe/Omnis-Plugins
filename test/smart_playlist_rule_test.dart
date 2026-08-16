import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/service_interfaces.dart' show ThumbState;
import 'package:omnis_plugins/smart_playlist_rule.dart';

BaseTrack _track({
  required String id,
  String title = 'Track',
  List<String> artists = const ['Artist'],
  String album = 'Album',
  List<String> genres = const [],
  String? mood,
  int? year,
}) =>
    BaseTrack(
      id: id,
      title: title,
      artists: artists,
      album: album,
      duration: 200,
      type: TrackType.local,
      genres: genres,
      mood: mood,
      year: year,
    );

void main() {
  group('RuleCondition — string fields', () {
    test('contains matches case-insensitively', () {
      const condition = RuleCondition(
        field: RuleField.artist,
        operator: RuleOperator.contains,
        value: 'queen',
      );
      expect(condition.matches(_track(id: '1', artists: ['Queen'])), isTrue);
      expect(
          condition.matches(_track(id: '2', artists: ['The Beatles'])),
          isFalse);
    });

    test('artist checks every artist in a multi-artist track', () {
      const condition = RuleCondition(
        field: RuleField.artist,
        operator: RuleOperator.contains,
        value: 'feat',
      );
      final track = _track(id: '1', artists: ['Artist A', 'feat. Artist B']);
      expect(condition.matches(track), isTrue);
    });

    test('genre checks every genre in a multi-genre track', () {
      const condition = RuleCondition(
        field: RuleField.genre,
        operator: RuleOperator.equals,
        value: 'rock',
      );
      final track = _track(id: '1', genres: ['Pop', 'Rock']);
      expect(condition.matches(track), isTrue);
    });

    test('mood on a track with no mood never matches', () {
      const condition = RuleCondition(
        field: RuleField.mood,
        operator: RuleOperator.contains,
        value: 'chill',
      );
      expect(condition.matches(_track(id: '1')), isFalse);
    });

    test('a numeric-only operator (e.g. greaterThan) on a string field '
        'matches nothing rather than throwing', () {
      const condition = RuleCondition(
        field: RuleField.title,
        operator: RuleOperator.greaterThan,
        value: '5',
      );
      expect(condition.matches(_track(id: '1', title: 'Song')), isFalse);
    });
  });

  group('RuleCondition — year field', () {
    test('equals matches an exact year', () {
      const condition = RuleCondition(
        field: RuleField.year,
        operator: RuleOperator.equals,
        value: '1975',
      );
      expect(condition.matches(_track(id: '1', year: 1975)), isTrue);
      expect(condition.matches(_track(id: '2', year: 1976)), isFalse);
    });

    test('greaterThanOrEqual/lessThanOrEqual/greaterThan/lessThan all '
        'compare correctly', () {
      final track = _track(id: '1', year: 2000);
      expect(
        const RuleCondition(
                field: RuleField.year,
                operator: RuleOperator.greaterThanOrEqual,
                value: '2000')
            .matches(track),
        isTrue,
      );
      expect(
        const RuleCondition(
                field: RuleField.year,
                operator: RuleOperator.lessThanOrEqual,
                value: '2000')
            .matches(track),
        isTrue,
      );
      expect(
        const RuleCondition(
                field: RuleField.year,
                operator: RuleOperator.greaterThan,
                value: '2000')
            .matches(track),
        isFalse,
      );
      expect(
        const RuleCondition(
                field: RuleField.year,
                operator: RuleOperator.lessThan,
                value: '2000')
            .matches(track),
        isFalse,
      );
    });

    test('a track with no year never matches', () {
      const condition = RuleCondition(
        field: RuleField.year,
        operator: RuleOperator.equals,
        value: '1975',
      );
      expect(condition.matches(_track(id: '1')), isFalse);
    });

    test('an unparseable value matches nothing rather than throwing', () {
      const condition = RuleCondition(
        field: RuleField.year,
        operator: RuleOperator.equals,
        value: 'not a number',
      );
      expect(condition.matches(_track(id: '1', year: 1975)), isFalse);
    });

    test('contains on a numeric field matches nothing', () {
      const condition = RuleCondition(
        field: RuleField.year,
        operator: RuleOperator.contains,
        value: '1975',
      );
      expect(condition.matches(_track(id: '1', year: 1975)), isFalse);
    });
  });

  group('RuleCondition — rating field', () {
    int ratingOf(String id) => id == 'rated' ? 5 : 0;

    test('compares against the caller-supplied ratingOf lookup', () {
      const condition = RuleCondition(
        field: RuleField.rating,
        operator: RuleOperator.greaterThanOrEqual,
        value: '4',
      );
      expect(
        condition.matches(_track(id: 'rated'), ratingOf: ratingOf),
        isTrue,
      );
      expect(
        condition.matches(_track(id: 'unrated'), ratingOf: ratingOf),
        isFalse,
      );
    });

    test('matches nothing when no ratingOf is supplied — same "don\'t '
        'silently ignore a field the caller didn\'t wire up" stance '
        'library_search.dart already established', () {
      const condition = RuleCondition(
        field: RuleField.rating,
        operator: RuleOperator.greaterThanOrEqual,
        value: '1',
      );
      expect(condition.matches(_track(id: 'rated')), isFalse);
    });
  });

  group('RuleCondition — favorite field', () {
    bool favoriteOf(String id) => id == 'loved';

    test('equals true matches only favorited tracks', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.equals,
        value: 'true',
      );
      expect(
        condition.matches(_track(id: 'loved'), favoriteOf: favoriteOf),
        isTrue,
      );
      expect(
        condition.matches(_track(id: 'not-loved'), favoriteOf: favoriteOf),
        isFalse,
      );
    });

    test('equals false matches only non-favorited tracks', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.equals,
        value: 'false',
      );
      expect(
        condition.matches(_track(id: 'loved'), favoriteOf: favoriteOf),
        isFalse,
      );
      expect(
        condition.matches(_track(id: 'not-loved'), favoriteOf: favoriteOf),
        isTrue,
      );
    });

    test('accepts yes/no/1/0 as well as true/false', () {
      final yes = const RuleCondition(
              field: RuleField.favorite,
              operator: RuleOperator.equals,
              value: 'yes')
          .matches(_track(id: 'loved'), favoriteOf: favoriteOf);
      final one = const RuleCondition(
              field: RuleField.favorite,
              operator: RuleOperator.equals,
              value: '1')
          .matches(_track(id: 'loved'), favoriteOf: favoriteOf);
      expect(yes, isTrue);
      expect(one, isTrue);
    });

    test('a non-equals operator matches nothing rather than throwing', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.contains,
        value: 'true',
      );
      expect(
        condition.matches(_track(id: 'loved'), favoriteOf: favoriteOf),
        isFalse,
      );
    });

    test('an unrecognized value matches nothing rather than throwing', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.equals,
        value: 'maybe',
      );
      expect(
        condition.matches(_track(id: 'loved'), favoriteOf: favoriteOf),
        isFalse,
      );
    });

    test('matches nothing when no favoriteOf is supplied — same "don\'t '
        'silently ignore a field the caller didn\'t wire up" stance '
        'rating already established', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.equals,
        value: 'true',
      );
      expect(condition.matches(_track(id: 'loved')), isFalse);
    });
  });

  group('RuleCondition — thumbUp/thumbDown fields (item 36)', () {
    ThumbState thumbOf(String id) => switch (id) {
          'up' => ThumbState.up,
          'down' => ThumbState.down,
          _ => ThumbState.none,
        };

    test('thumbUp equals true matches only thumbed-up tracks', () {
      const condition = RuleCondition(
        field: RuleField.thumbUp,
        operator: RuleOperator.equals,
        value: 'true',
      );
      expect(condition.matches(_track(id: 'up'), thumbOf: thumbOf), isTrue);
      expect(condition.matches(_track(id: 'down'), thumbOf: thumbOf), isFalse);
      expect(condition.matches(_track(id: 'none'), thumbOf: thumbOf), isFalse);
    });

    test('thumbDown equals true matches only thumbed-down tracks', () {
      const condition = RuleCondition(
        field: RuleField.thumbDown,
        operator: RuleOperator.equals,
        value: 'true',
      );
      expect(condition.matches(_track(id: 'down'), thumbOf: thumbOf), isTrue);
      expect(condition.matches(_track(id: 'up'), thumbOf: thumbOf), isFalse);
      expect(condition.matches(_track(id: 'none'), thumbOf: thumbOf), isFalse);
    });

    test('thumbUp equals false matches everything not thumbed up '
        '(including thumbed down)', () {
      const condition = RuleCondition(
        field: RuleField.thumbUp,
        operator: RuleOperator.equals,
        value: 'false',
      );
      expect(condition.matches(_track(id: 'up'), thumbOf: thumbOf), isFalse);
      expect(condition.matches(_track(id: 'down'), thumbOf: thumbOf), isTrue);
      expect(condition.matches(_track(id: 'none'), thumbOf: thumbOf), isTrue);
    });

    test('a non-equals operator matches nothing rather than throwing', () {
      const condition = RuleCondition(
        field: RuleField.thumbUp,
        operator: RuleOperator.contains,
        value: 'true',
      );
      expect(condition.matches(_track(id: 'up'), thumbOf: thumbOf), isFalse);
    });

    test('matches nothing when no thumbOf is supplied — same "don\'t '
        'silently ignore a field the caller didn\'t wire up" stance '
        'favorite/rating already establish', () {
      const upCondition = RuleCondition(
        field: RuleField.thumbUp,
        operator: RuleOperator.equals,
        value: 'true',
      );
      const downCondition = RuleCondition(
        field: RuleField.thumbDown,
        operator: RuleOperator.equals,
        value: 'true',
      );
      expect(upCondition.matches(_track(id: 'up')), isFalse);
      expect(downCondition.matches(_track(id: 'down')), isFalse);
    });

    test('thumbUp and thumbDown are independent conditions — a rule can '
        'combine both in one ALL/ANY/NONE group', () {
      final rule = SmartPlaylistRule(
        id: 'r1',
        name: 'Up not down',
        matchType: RuleMatchType.none,
        conditions: const [
          RuleCondition(
              field: RuleField.thumbDown,
              operator: RuleOperator.equals,
              value: 'true'),
        ],
      );
      final tracks = [_track(id: 'up'), _track(id: 'down'), _track(id: 'none')];

      final result = rule.apply(tracks, thumbOf: thumbOf);

      expect(result.map((t) => t.id).toSet(), {'up', 'none'});
    });
  });

  group('RuleCondition JSON round-trip', () {
    test('toJson/fromJson round-trips exactly', () {
      const condition = RuleCondition(
        field: RuleField.rating,
        operator: RuleOperator.greaterThanOrEqual,
        value: '4',
      );
      final decoded = RuleCondition.fromJson(condition.toJson());
      expect(decoded!.field, condition.field);
      expect(decoded.operator, condition.operator);
      expect(decoded.value, condition.value);
    });

    test('fromJson returns null for a missing/unknown field name', () {
      expect(
        RuleCondition.fromJson(
            {'field': 'not_a_real_field', 'operator': 'equals', 'value': 'x'}),
        isNull,
      );
    });

    test('fromJson returns null for an unknown operator name', () {
      expect(
        RuleCondition.fromJson(
            {'field': 'title', 'operator': 'not_a_real_op', 'value': 'x'}),
        isNull,
      );
    });

    test('fromJson returns null when value is not a string', () {
      expect(
        RuleCondition.fromJson(
            {'field': 'title', 'operator': 'equals', 'value': 123}),
        isNull,
      );
    });

    test('a favorite condition round-trips exactly too', () {
      const condition = RuleCondition(
        field: RuleField.favorite,
        operator: RuleOperator.equals,
        value: 'true',
      );
      final decoded = RuleCondition.fromJson(condition.toJson());
      expect(decoded!.field, RuleField.favorite);
      expect(decoded.operator, RuleOperator.equals);
      expect(decoded.value, 'true');
    });
  });

  group('SmartPlaylistRule — favoriteOf threading', () {
    test('apply() passes favoriteOf through to a favorite: condition',
        () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'My Favorites',
        matchType: RuleMatchType.all,
        conditions: const [
          RuleCondition(
            field: RuleField.favorite,
            operator: RuleOperator.equals,
            value: 'true',
          ),
        ],
      );
      final tracks = [_track(id: 'loved'), _track(id: 'not-loved')];
      final result = rule.apply(tracks, favoriteOf: (id) => id == 'loved');
      expect(result.map((t) => t.id), ['loved']);
    });

    test('apply() with no favoriteOf makes a favorite: condition match '
        'nothing, same as an unsupplied ratingOf', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'My Favorites',
        matchType: RuleMatchType.all,
        conditions: const [
          RuleCondition(
            field: RuleField.favorite,
            operator: RuleOperator.equals,
            value: 'true',
          ),
        ],
      );
      final tracks = [_track(id: 'loved')];
      expect(rule.apply(tracks), isEmpty);
    });
  });

  group('SmartPlaylistRule — ALL/ANY/NONE composition', () {
    final tracks = [
      _track(id: 'rock-recent', genres: ['Rock'], year: 2020),
      _track(id: 'rock-old', genres: ['Rock'], year: 1975),
      _track(id: 'pop-recent', genres: ['Pop'], year: 2020),
    ];
    const rockCondition = RuleCondition(
      field: RuleField.genre,
      operator: RuleOperator.equals,
      value: 'rock',
    );
    const recentCondition = RuleCondition(
      field: RuleField.year,
      operator: RuleOperator.greaterThanOrEqual,
      value: '2000',
    );

    test('ALL requires every condition to hold', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'Recent Rock',
        matchType: RuleMatchType.all,
        conditions: [rockCondition, recentCondition],
      );
      expect(rule.apply(tracks).map((t) => t.id), ['rock-recent']);
    });

    test('ANY requires at least one condition to hold', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'Rock or Recent',
        matchType: RuleMatchType.any,
        conditions: [rockCondition, recentCondition],
      );
      expect(
        rule.apply(tracks).map((t) => t.id).toSet(),
        {'rock-recent', 'rock-old', 'pop-recent'},
      );
    });

    test('NONE requires every condition to fail', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'Not Rock, Not Recent',
        matchType: RuleMatchType.none,
        conditions: [rockCondition, recentCondition],
      );
      // Only a track matching neither "rock" nor "recent" qualifies —
      // none of the three fixture tracks are both non-rock and old, so
      // add one that genuinely is.
      final withNoneMatch = [
        ...tracks,
        _track(id: 'pop-old', genres: ['Pop'], year: 1975),
      ];
      expect(rule.apply(withNoneMatch).map((t) => t.id), ['pop-old']);
    });

    test('a rule with zero conditions matches nothing — a setup gap, '
        'not "match everything"', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'Empty',
        matchType: RuleMatchType.all,
        conditions: const [],
      );
      expect(rule.apply(tracks), isEmpty);
    });

    test('recomputes fresh against whatever library is passed — a smart '
        'playlist has no fixed membership', () {
      final rule = SmartPlaylistRule(
        id: '1',
        name: 'Recent Rock',
        matchType: RuleMatchType.all,
        conditions: [rockCondition, recentCondition],
      );
      expect(rule.apply(tracks), hasLength(1));
      expect(rule.apply(const []), isEmpty);
      expect(
        rule.apply([_track(id: 'new-rock', genres: ['Rock'], year: 2024)]),
        hasLength(1),
      );
    });
  });

  group('SmartPlaylistRule JSON round-trip', () {
    test('toJson/fromJson round-trips a real multi-condition rule', () {
      final rule = SmartPlaylistRule(
        id: 'abc',
        name: 'Recent Rock',
        matchType: RuleMatchType.all,
        conditions: const [
          RuleCondition(
              field: RuleField.genre,
              operator: RuleOperator.equals,
              value: 'rock'),
          RuleCondition(
              field: RuleField.year,
              operator: RuleOperator.greaterThanOrEqual,
              value: '2000'),
        ],
      );
      final decoded = SmartPlaylistRule.fromJson(rule.toJson());
      expect(decoded!.id, 'abc');
      expect(decoded.name, 'Recent Rock');
      expect(decoded.matchType, RuleMatchType.all);
      expect(decoded.conditions, hasLength(2));
      expect(decoded.conditions[0].field, RuleField.genre);
      expect(decoded.conditions[1].value, '2000');
    });

    test('fromJson returns null for a missing id/name/matchType', () {
      expect(SmartPlaylistRule.fromJson({'name': 'X'}), isNull);
      expect(
        SmartPlaylistRule.fromJson({'id': '1', 'matchType': 'all'}),
        isNull,
      );
      expect(
        SmartPlaylistRule.fromJson({'id': '1', 'name': 'X'}),
        isNull,
      );
    });

    test('one malformed condition is skipped, not treated as a '
        'whole-rule decode failure', () {
      final json = {
        'id': '1',
        'name': 'X',
        'matchType': 'all',
        'conditions': [
          {'field': 'title', 'operator': 'equals', 'value': 'ok'},
          {'field': 'not_real', 'operator': 'equals', 'value': 'bad'},
        ],
      };
      final decoded = SmartPlaylistRule.fromJson(json);
      expect(decoded!.conditions, hasLength(1));
      expect(decoded.conditions.single.value, 'ok');
    });
  });
}
