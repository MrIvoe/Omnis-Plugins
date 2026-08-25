/// A single version-to-version upgrade step: given the *previous*
/// version's decoded payload, returns the next version's shape. Stored
/// per store, keyed by the version it upgrades *from* (so migration
/// `0` takes a v0 payload and returns a v1 one).
///
/// A duplicate of the Omnis app's own `lib/core/schema_versioning.dart` —
/// not a move, since that file also backs three other core-only stores
/// (`LibraryStore`, `PlaylistStore`, `RecoveryJournal`) that stay in the
/// app and can't be touched by this task. This isn't a "the app can't
/// reach a shared copy" situation — the app already depends on
/// `omnis_plugins` — the underlying reason a shared copy doesn't already
/// live there is this plan's own Global Constraint deferring every
/// cross-repo `omnis_plugins` pin bump to Tier 2 task 6: the app is
/// pinned to `omnis_plugins` tag `v0.50.0`, which predates this file's
/// existence. `HomeLayoutStore` (moved here from
/// `lib/core/home_layout_store.dart` as part of extracting the Home
/// dashboard into a plugin) needs the exact same versioned-envelope +
/// migration-dispatch scaffold every JSON-backed store in this app
/// already builds on, to keep reading the same on-disk file shape its
/// pre-extraction self wrote. Kept byte-for-byte identical to the
/// original so both copies stay trivially comparable if either ever
/// needs a real migration added. Once task 6 bumps the app's pin, this
/// and the app's copy become candidates for consolidation into one
/// shared copy — not done here, just flagged (though the three other
/// core-only stores above would still need their own reason to move
/// before that consolidation could go all the way to a single copy).
typedef SchemaMigration = dynamic Function(dynamic data);

/// Wraps [payload] in the standard versioned-envelope shape:
/// `{"schemaVersion": N, "data": payload}`. Always writes
/// [currentVersion] — there's never anything to migrate on write, only
/// on read, so a save always produces the newest known shape.
Map<String, dynamic> wrapVersioned(dynamic payload, int currentVersion) => {
      'schemaVersion': currentVersion,
      'data': payload,
    };

/// Reads the `(version, payload)` pair out of a store's raw decoded
/// JSON. Understands the pre-versioning "bare" shape every file this
/// app has ever written looks like today: no `schemaVersion` key at
/// all, because the payload itself — a bare list, a bare map, a bare
/// object — *is* the whole file. That shape decodes as version `0` with
/// [decoded] itself as the payload, so nothing already on disk needs a
/// one-time conversion pass; the very next `save()` from any store
/// upgrades it to the versioned envelope transparently, the same
/// "old data still reads fine, new data gets the new shape" contract
/// every additive `BaseTrack`/`PluginManifest` field already follows in
/// this codebase.
({int version, dynamic data}) unwrapVersioned(dynamic decoded) {
  if (decoded is Map && decoded.containsKey('schemaVersion')) {
    return (version: decoded['schemaVersion'] as int, data: decoded['data']);
  }
  return (version: 0, data: decoded);
}

/// Runs every migration step from [fromVersion] up to (not including)
/// [toVersion] in order, using whichever of [migrations] apply — a
/// store with nothing registered for a given version (the common case:
/// today, every store's map is empty, since nothing has needed a real
/// payload transformation yet) just leaves the payload as-is for that
/// step, so a gap in the map is a no-op, never an error.
dynamic runMigrations(
  dynamic data,
  int fromVersion,
  int toVersion,
  Map<int, SchemaMigration> migrations,
) {
  var result = data;
  for (var version = fromVersion; version < toVersion; version++) {
    final migrate = migrations[version];
    if (migrate != null) result = migrate(result);
  }
  return result;
}
