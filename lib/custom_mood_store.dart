import 'dart:convert';
import 'dart:io';

import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugins/schema_versioning.dart';
import 'package:path_provider/path_provider.dart';

/// This store's current on-disk shape version — see
/// `schema_versioning.dart`.
const _currentSchemaVersion = 1;
const _migrations = <int, SchemaMigration>{};

/// Persists user-created [CustomMood]s — the same load/save shape as
/// `PlaylistStore`: one JSON file in the app's documents directory, the
/// caller (the Moods page) owns the in-memory list and decides when to
/// save, rather than this store caching state itself. Custom moods are
/// only ever read by the Moods page and, indirectly, by whatever asks
/// `IMoodPlayer.customMoods` for them, so there's no need for a
/// `LibraryRepository`-style shared-cache wrapper here.
///
/// Moved here from the Omnis app's own `lib/core/custom_mood.dart` (Tier
/// 2 task 4), which used to hold both this store and the [CustomMood]
/// value type. Only the value type went to `omnis_plugin_api` — it's part
/// of `IMoodPlayer`'s signature, so both sides of that contract need it —
/// while this store is plugin-private state and belongs next to
/// `MoodsPage`, the only thing that writes it. Reads and writes the same
/// `omnis_custom_moods.json` file, in the same versioned-envelope shape,
/// its pre-extraction self did, so an existing install's saved moods
/// survive the move untouched.
class CustomMoodStore {
  CustomMoodStore._();

  static final CustomMoodStore instance = CustomMoodStore._();

  File? _file;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/omnis_custom_moods.json');
    return _file!;
  }

  /// Load persisted custom moods. Returns an empty list if none exist or
  /// the file is corrupt — never throws.
  Future<List<CustomMood>> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      final unwrapped = unwrapVersioned(decoded);
      final migrated = runMigrations(unwrapped.data, unwrapped.version,
          _currentSchemaVersion, _migrations);
      if (migrated is! List) return [];
      final moods = <CustomMood>[];
      for (final entry in migrated) {
        if (entry is! Map) continue;
        final mood = CustomMood.fromJson(Map<String, dynamic>.from(entry));
        if (mood != null) moods.add(mood);
      }
      return moods;
    } catch (e) {
      return [];
    }
  }

  /// Persist [moods] to disk. Atomic write (sibling `.tmp` + rename), the
  /// same crash/power-loss-safe pattern `PlaylistStore.save`/
  /// `LibraryStore._flushPending` already use — this is user-authored
  /// content a rescan can't regenerate.
  Future<void> save(List<CustomMood> moods) async {
    try {
      final file = await _getFile();
      final json = jsonEncode(wrapVersioned(
          moods.map((m) => m.toJson()).toList(), _currentSchemaVersion));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      // Best-effort persistence; a failure here must never crash the app.
    }
  }

  /// Test-only: drops the cached file handle so each test starts clean
  /// regardless of what an earlier test in the same file resolved to —
  /// mirrors `LibraryRepository.resetForTesting`.
  void resetForTesting() {
    _file = null;
  }
}
