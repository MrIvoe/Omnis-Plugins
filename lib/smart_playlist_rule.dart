import 'dart:convert';

import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/service_interfaces.dart' show ThumbState;

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
enum RuleField {
  title,
  artist,
  album,
  genre,
  mood,
  year,
  rating,
  favorite,
  thumbUp,
  thumbDown,

  /// Beats per minute — reads `BaseTrack.bpm` directly, the same field
  /// `library_search.dart`'s `bpm:` qualifier already reads with no
  /// plugin lookup needed.
  bpm,

  /// Track length in seconds — reads `BaseTrack.duration` directly.
  duration,

  /// Bitrate in kbps — reads `BaseTrack.bitrateKbps` directly, the same
  /// field `library_search.dart`'s `bitrate:` qualifier already reads.
  bitrate,

  /// Codec/format label (e.g. "FLAC", "MP3") — reads `BaseTrack.codec`
  /// directly, the same field `library_search.dart`'s `format:`
  /// qualifier already reads. Categorical, not free text — see
  /// [RuleCondition._matchesCodec].
  codec,
}

/// How a condition's [RuleCondition.value] is compared against a
/// track's field. String fields (`title`/`artist`/`album`/`genre`/
/// `mood`) support [contains] and [equals] (both case-insensitive, see
/// [RuleCondition._matchesString]); numeric fields (`year`/`rating`/
/// `bpm`/`duration`/`bitrate`) support the full comparison set —
/// mirroring exactly which operators `library_search.dart`'s `year:`/
/// `rating:`/`bpm:`/`bitrate:` qualifiers already support; `codec` only
/// ever uses [equals] (categorical, not free text — see
/// [RuleCondition._matchesCodec]), the same restriction `favorite`/
/// `thumbUp`/`thumbDown` already have for their own boolean fields.
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

  /// Whether [track] satisfies this single condition. [ratingOf]/
  /// [favoriteOf] are the same caller-supplied lookups
  /// `library_search.dart`'s `rating:`/`favorite:` qualifiers use — this
  /// stays plugin-storage-free itself, the same "pure function, caller
  /// supplies the join data" design that file's own doc comment already
  /// settled on. Never throws: an operator that doesn't make sense for a
  /// field (e.g. `greaterThan` on `artist`) simply matches nothing, the
  /// same "a bad combination finds nothing, not a crash" contract
  /// `library_search.dart` uses for a malformed query.
  bool matches(
    BaseTrack track, {
    int Function(String trackId)? ratingOf,
    bool Function(String trackId)? favoriteOf,
    ThumbState Function(String trackId)? thumbOf,
  }) {
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
      case RuleField.favorite:
        if (favoriteOf == null) return false;
        return _matchesBoolean(favoriteOf(track.id));
      case RuleField.thumbUp:
        if (thumbOf == null) return false;
        return _matchesBoolean(thumbOf(track.id) == ThumbState.up);
      case RuleField.thumbDown:
        if (thumbOf == null) return false;
        return _matchesBoolean(thumbOf(track.id) == ThumbState.down);
      case RuleField.bpm:
        return _matchesDouble(track.bpm);
      case RuleField.duration:
        return _matchesNumber(track.duration);
      case RuleField.bitrate:
        return _matchesNumber(track.bitrateKbps);
      case RuleField.codec:
        return _matchesCodec(track.codec);
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

  /// `favorite` only ever uses [RuleOperator.equals] — `>`/`>=`/`<`/`<=`/
  /// `contains` don't mean anything for a boolean field, so they match
  /// nothing, the same "an inapplicable operator finds nothing" contract
  /// [_matchesNumber] already has for `contains` on a numeric field.
  /// Accepts `true`/`false`/`yes`/`no`/`1`/`0` (case-insensitive), the
  /// same forgiving value set `library_search.dart`'s `favorite:`/
  /// `lyrics:` qualifiers already accept.
  bool _matchesBoolean(bool trackValue) {
    if (operator != RuleOperator.equals) return false;
    final v = value.toLowerCase();
    if (v == 'true' || v == 'yes' || v == '1') return trackValue;
    if (v == 'false' || v == 'no' || v == '0') return !trackValue;
    return false;
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

  /// Same shape as [_matchesNumber], for `bpm` — a separate method
  /// rather than a generic `num` version purely because [double.tryParse]
  /// and [int.tryParse] are different calls; the comparison logic itself
  /// is identical.
  bool _matchesDouble(double? trackValue) {
    if (trackValue == null) return false;
    final threshold = double.tryParse(value);
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

  /// `codec` only ever uses [RuleOperator.equals], exact and case-
  /// insensitive — the same categorical-not-substring stance
  /// `library_search.dart`'s `format:` qualifier already takes (a codec
  /// label like "FLAC"/"MP3" is a discrete value, not free text, so
  /// `contains` doesn't mean anything for it the way it does for
  /// title/artist/album/genre/mood).
  bool _matchesCodec(String? trackValue) {
    if (trackValue == null) return false;
    if (operator != RuleOperator.equals) return false;
    return trackValue.toLowerCase() == value.toLowerCase();
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
    bool Function(String trackId)? favoriteOf,
    ThumbState Function(String trackId)? thumbOf,
  }) {
    if (conditions.isEmpty) return const [];
    return library
        .where((track) => _matchesTrack(track, ratingOf, favoriteOf, thumbOf))
        .toList();
  }

  bool _matchesTrack(
    BaseTrack track,
    int Function(String)? ratingOf,
    bool Function(String)? favoriteOf,
    ThumbState Function(String)? thumbOf,
  ) {
    switch (matchType) {
      case RuleMatchType.all:
        return conditions.every((c) => c.matches(track,
            ratingOf: ratingOf, favoriteOf: favoriteOf, thumbOf: thumbOf));
      case RuleMatchType.any:
        return conditions.any((c) => c.matches(track,
            ratingOf: ratingOf, favoriteOf: favoriteOf, thumbOf: thumbOf));
      case RuleMatchType.none:
        return conditions.every((c) => !c.matches(track,
            ratingOf: ratingOf, favoriteOf: favoriteOf, thumbOf: thumbOf));
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

/// This export payload's current shape version — bumped only if the
/// envelope structure itself ever needs to change; each [SmartPlaylistRule]
/// inside already carries its own `toJson()`/`fromJson()` shape
/// independently, the same layering `schema_versioning.dart`'s
/// envelope/payload split uses elsewhere in the main app.
const _exportSchemaVersion = 1;

/// Item 42's "no import/export" gap — a plain JSON envelope a listener
/// can copy/paste (via the clipboard, not a file — deliberately, so
/// this feature adds no new dependency like `file_picker` to a package
/// that doesn't otherwise need one) to share a smart playlist with
/// another install, or just back one up outside this app's own storage.
/// Reuses each [SmartPlaylistRule]'s existing [SmartPlaylistRule.toJson]
/// rather than inventing a second serialization for the same model.
String exportRulesToJson(List<SmartPlaylistRule> rules) => jsonEncode({
      'schemaVersion': _exportSchemaVersion,
      'rules': rules.map((r) => r.toJson()).toList(),
    });

/// Decodes [raw] back into a list of rules. Per-entry defensive, the
/// same contract [SmartPlaylistRule.fromJson] itself already documents
/// one level down — a single malformed rule in a pasted payload (hand-
/// edited, truncated in transit, from a future/older app version) is
/// skipped rather than discarding every other rule in the same paste.
/// Malformed JSON, or JSON that isn't the expected envelope shape at
/// all, returns an empty list rather than throwing — the same "a bad
/// paste finds nothing to import, not a crash" contract every other
/// parser in this app already follows for hand-editable input.
List<SmartPlaylistRule> importRulesFromJson(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const [];
    final rawRules = decoded['rules'];
    if (rawRules is! List) return const [];
    final rules = <SmartPlaylistRule>[];
    for (final entry in rawRules) {
      if (entry is! Map) continue;
      final rule = SmartPlaylistRule.fromJson(Map<String, dynamic>.from(entry));
      if (rule != null) rules.add(rule);
    }
    return rules;
  } catch (_) {
    return const [];
  }
}
