import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:omnis_plugins/schema_versioning.dart';
import 'package:path_provider/path_provider.dart';

/// This store's current on-disk shape version — see `schema_versioning.dart`.
const _currentSchemaVersion = 1;
const _migrations = <int, SchemaMigration>{};

/// The Home tab's fixed set of sections and their stable ids — item 45's
/// "0% for Home" gap (no reordering/hiding, unlike Now Playing's real
/// drag-and-drop `LayoutEditorPage`). A full free-form "widget canvas"
/// is the larger spec vision and out of scope here; this is the
/// tractable slice — persisted order + per-section visibility for this
/// fixed set. Ids are independent of the display title so a future
/// rename never breaks a saved layout the way keying by title would.
const homeSectionCatalog = <String, String>{
  'continue_listening': 'Continue Listening',
  'recently_played': 'Recently Played',
  'most_played': 'Most Played',
  'recently_added': 'Recently Added',
  'favorites': 'Favorites',
  'most_skipped': 'Most Skipped',
};

/// One section's saved position (implicit — its index in the saved
/// list) and visibility.
class HomeSectionPreference {
  final String sectionId;
  final bool visible;

  const HomeSectionPreference({required this.sectionId, required this.visible});

  HomeSectionPreference copyWith({bool? visible}) => HomeSectionPreference(
        sectionId: sectionId,
        visible: visible ?? this.visible,
      );

  Map<String, dynamic> toJson() => {'sectionId': sectionId, 'visible': visible};

  factory HomeSectionPreference.fromJson(Map<String, dynamic> json) =>
      HomeSectionPreference(
        sectionId: json['sectionId'] as String,
        visible: json['visible'] as bool? ?? true,
      );
}

/// Persists the Home tab's customized section order/visibility. Same
/// atomic-write + schema-versioned-envelope shape every other store in
/// this app already uses.
class HomeLayoutStore {
  HomeLayoutStore._();

  static final HomeLayoutStore instance = HomeLayoutStore._();

  File? _file;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/omnis_home_layout.json');
    return _file!;
  }

  /// Loads the saved layout, oldest-added-first — an empty list means
  /// nothing has ever been customized (existing users see today's fixed
  /// order/all-visible until they opt in), not that every section is
  /// hidden. Each entry is decoded independently, so one malformed
  /// record can't wipe the rest.
  Future<List<HomeSectionPreference>> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      final unwrapped = unwrapVersioned(decoded);
      final migrated = runMigrations(
          unwrapped.data, unwrapped.version, _currentSchemaVersion, _migrations);
      if (migrated is! List) return [];
      final prefs = <HomeSectionPreference>[];
      for (final entry in migrated) {
        if (entry is! Map) continue;
        try {
          prefs.add(
              HomeSectionPreference.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {
          continue;
        }
      }
      return prefs;
    } catch (_) {
      return [];
    }
  }

  /// Persist [prefs] to disk. Writes to a sibling `.tmp` file and
  /// renames it over the real path — atomic on the filesystems this app
  /// targets, the same crash-safety every other store's `save` already
  /// has.
  Future<void> save(List<HomeSectionPreference> prefs) async {
    try {
      final file = await _getFile();
      final json = jsonEncode(wrapVersioned(
          prefs.map((p) => p.toJson()).toList(), _currentSchemaVersion));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Best-effort persistence; a failure here must never crash the app.
    }
  }

  /// Test-only: deletes the persisted file, so tests that share this
  /// process-wide singleton across a fresh `PathProviderPlatform` per
  /// test start clean — same convention `LibraryStore.clear`/
  /// `PlayHistoryStore.clear` already establish.
  @visibleForTesting
  Future<void> clear() async {
    try {
      final file = await _getFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Reorders/filters [defaultSections] (already-built, in today's fixed
/// order) according to [saved] — an empty [saved] returns
/// [defaultSections] completely unchanged, so a user who's never
/// customized anything sees exactly today's behavior. A section named
/// in [saved] with `visible: false` is dropped; a section named in
/// [saved] that has nothing to show right now (e.g. "Favorites" with no
/// favorited tracks, [idOf] finds no match in [defaultSections]) is
/// simply skipped, same as it already is today. A section [saved] never
/// mentions at all — a new section type added after the user last
/// customized their layout — is appended at the end, visible by
/// default, rather than silently disappearing because an old save
/// predates it.
///
/// Pure — no store/file dependency, so it's fully unit-testable with a
/// plain list of already-built sections.
List<T> applyHomeLayout<T>(
  List<T> defaultSections,
  List<HomeSectionPreference> saved,
  String Function(T) idOf,
) {
  if (saved.isEmpty) return defaultSections;

  final byId = {for (final s in defaultSections) idOf(s): s};
  final seen = <String>{};
  final result = <T>[];
  for (final pref in saved) {
    seen.add(pref.sectionId);
    if (!pref.visible) continue;
    final section = byId[pref.sectionId];
    if (section != null) result.add(section);
  }
  for (final section in defaultSections) {
    final id = idOf(section);
    if (!seen.contains(id)) result.add(section);
  }
  return result;
}
