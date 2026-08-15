import 'package:omnis_plugin_api/base_track.dart';

/// Null-safe "find the first match, or null" — avoids adding
/// `package:collection` as a dependency just for `firstOrNull`.
T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// A field a [SmartPlaylistCondition] can test — item 42's "rule-based,
/// multi-condition... engine" gap named `SmartPlaylistRule`/condition-
/// group model as not existing anywhere; this is that model. Mirrors
/// the field vocabulary `lib/core/library_search.dart` (the Omnis app's
/// own search-query parser) already established, for the same reason a
/// search qualifier and a smart-playlist condition are conceptually the
/// same kind of thing — "does this track's X satisfy Y" — just reached
/// through a structured rule-builder UI instead of typed `field:value`
/// syntax.
enum RuleField { title, artist, album, genre, mood, year, rating }

/// How a condition's [RuleCondition.value] is compared against a
/// track's field. String fields (`title`/`artist`/`album`/`genre`/
/// `mood`) support [contains] and [equals] (both case-insensitive, see
/// [RuleCondition._matchesString]); numeric fields (`year`/`rating`)
/// support the full comparison set — mirroring exactly which operators
/// `library_search.dart`'s `year:`/`rating:` qualifiers already support.
enum RuleOperator {
  contains,
  equals,
  greaterThanOrEqual,
  lessThanOrEqual,
  greaterThan,
  lessThan,
}

/// How a rule's [SmartPlaylistRule.conditions] combine — the "ALL/ANY/
/// NONE" item 42 explicitly names as missing.
enum RuleMatchType { all, any, none }

/// One condition within a [SmartPlaylistRule] — "artist contains Queen,"
/// "rating >= 4," "year equals 1975."
class RuleCondition {
  final RuleField field;
  final RuleOperator operator;
  final String value;

  const RuleCondition({
    required this.field,
    required this.operator,
    required this.value,
  });

  /// Whether [track] satisfies this single condition. [ratingOf] is the
  /// same caller-supplied lookup `library_search.dart`'s `rating:`
  /// qualifier uses — this stays plugin-storage-free itself, the same
  /// "pure function, caller supplies the join data" design that file's
  /// own doc comment already settled on. Never throws: an operator that
  /// doesn't make sense for a field (e.g. `greaterThan` on `artist`)
  /// simply matches nothing, the same "a bad combination finds nothing,
  /// not a crash" contract `library_search.dart` uses for a malformed
  /// query.
  bool matches(BaseTrack track, {int Function(String trackId)? ratingOf}) {
    switch (field) {
      case RuleField.title:
        return _matchesString(track.title);
      case RuleField.artist:
        return track.artists.any(_matchesString);
      case RuleField.album:
        return _matchesString(track.album);
      case RuleField.genre:
        return track.genres.any(_matchesString);
      case RuleField.mood:
        return _matchesString(track.mood ?? '');
      case RuleField.year:
        return _matchesNumber(track.year);
      case RuleField.rating:
        if (ratingOf == null) return false;
        return _matchesNumber(ratingOf(track.id));
    }
  }

  bool _matchesString(String haystack) {
    if (operator != RuleOperator.contains &&
        operator != RuleOperator.equals) {
      return false;
    }
    final h = haystack.toLowerCase();
    final v = value.toLowerCase();
    return operator == RuleOperator.equals ? h == v : h.contains(v);
  }

  bool _matchesNumber(int? trackValue) {
    if (trackValue == null) return false;
    final threshold = int.tryParse(value);
    if (threshold == null) return false;
    return switch (operator) {
      RuleOperator.equals => trackValue == threshold,
      RuleOperator.greaterThanOrEqual => trackValue >= threshold,
      RuleOperator.lessThanOrEqual => trackValue <= threshold,
      RuleOperator.greaterThan => trackValue > threshold,
      RuleOperator.lessThan => trackValue < threshold,
      RuleOperator.contains => false,
    };
  }

  Map<String, dynamic> toJson() => {
        'field': field.name,
        'operator': operator.name,
        'value': value,
      };

  /// Returns `null` for a malformed entry rather than throwing — every
  /// JSON-backed store/plugin in this app decodes per-entry defensively
  /// so one bad record can't wipe the rest of a saved rule (or, at the
  /// next level up, the rest of a listener's saved rules).
  static RuleCondition? fromJson(Map<String, dynamic> json) {
    final field =
        _firstWhereOrNull(RuleField.values, (f) => f.name == json['field']);
    final operator = _firstWhereOrNull(
        RuleOperator.values, (o) => o.name == json['operator']);
    final value = json['value'];
    if (field == null || operator == null || value is! String) return null;
    return RuleCondition(field: field, operator: operator, value: value);
  }
}

/// A saved, named smart playlist — real rule-based membership (§42),
/// not a static list of track ids the way `PlaylistStore`'s ordinary
/// playlists are. [conditions] combine according to [matchType]: every
/// one must hold ([RuleMatchType.all]), at least one must hold
/// ([RuleMatchType.any]), or none may hold ([RuleMatchType.none]).
class SmartPlaylistRule {
  final String id;
  final String name;
  final RuleMatchType matchType;
  final List<RuleCondition> conditions;

  const SmartPlaylistRule({
    required this.id,
    required this.name,
    required this.matchType,
    required this.conditions,
  });

  /// The tracks in [library] this rule currently matches — recomputed
  /// fresh every call, since a smart playlist's whole point is that its
  /// membership follows the library rather than being fixed at save
  /// time. An empty [conditions] list matches nothing (a rule with no
  /// conditions isn't "everything," it's "not yet configured") —
  /// deliberately not the same "no query = unfiltered" convention
  /// `library_search.dart`'s `filterTracks` uses for an *empty search
  /// box*, since a saved smart playlist with zero conditions is a
  /// setup gap, not an intentional "match everything" query.
  List<BaseTrack> apply(
    List<BaseTrack> library, {
    int Function(String trackId)? ratingOf,
  }) {
    if (conditions.isEmpty) return const [];
    return library.where((track) => _matchesTrack(track, ratingOf)).toList();
  }

  bool _matchesTrack(BaseTrack track, int Function(String)? ratingOf) {
    switch (matchType) {
      case RuleMatchType.all:
        return conditions.every((c) => c.matches(track, ratingOf: ratingOf));
      case RuleMatchType.any:
        return conditions.any((c) => c.matches(track, ratingOf: ratingOf));
      case RuleMatchType.none:
        return conditions.every((c) => !c.matches(track, ratingOf: ratingOf));
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'matchType': matchType.name,
        'conditions': conditions.map((c) => c.toJson()).toList(),
      };

  /// Returns `null` for a malformed entry — same per-entry-defensive
  /// contract as [RuleCondition.fromJson], one level up: a single
  /// corrupted saved rule must not wipe every other saved rule.
  static SmartPlaylistRule? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final matchType = _firstWhereOrNull(
        RuleMatchType.values, (m) => m.name == json['matchType']);
    final rawConditions = json['conditions'];
    if (id is! String || name is! String || matchType == null) return null;
    if (rawConditions is! List) return null;
    final conditions = <RuleCondition>[];
    for (final entry in rawConditions) {
      if (entry is! Map) continue;
      final condition = RuleCondition.fromJson(Map<String, dynamic>.from(entry));
      if (condition != null) conditions.add(condition);
    }
    return SmartPlaylistRule(
      id: id,
      name: name,
      matchType: matchType,
      conditions: conditions,
    );
  }
}
