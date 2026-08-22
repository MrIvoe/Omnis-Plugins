# Plugin Structure Document — Design

## Problem

Omnis-Plugins hosts two unrelated plugin systems (bundled `lib/*.dart`
Flutter classes, and downloadable per-folder `dart_eval`-sandboxed
plugins like `sample_logger/`), but nothing in this repo states the
downloadable format as a rule. That gap already produced a broken
artifact: an untracked `ai_playlist/` folder with a manifest in the
right place but a Flutter-based `plugin.dart` that cannot run under
`dart_eval`, plus a stray `omnis_plugin.yaml` committed directly into
`lib/` (which the installer never reads). Both are evidence that the
convention needs to be written down, not just implied by
`sample_logger/`'s existence.

## Scope

In scope:
- A single canonical structure document for this repo.
- A CI check that keeps its directory-tree block accurate.
- Removing the two broken artifacts described above.
- Pointers from `README.md`/`CONTRIBUTING.md` to the new doc.

Explicitly out of scope (deferred to future, per-plugin work):
- Migrating any of the ~30 `lib/*.dart` bundled plugins to the
  downloadable format. Many depend on Flutter widgets or platform
  channels (Bluetooth, device volume, equalizer, OAuth) that
  `dart_eval` cannot run; each candidate needs its own feasibility
  check.
- Any change to `plugin_installer.dart` or `plugin_manifest.dart` in
  the main Omnis repo (parsing logic, supported layouts).
- Building a working, sandbox-compatible `ai_playlist` downloadable
  plugin. Its dependency on outbound HTTP calls to an AI provider
  needs `dart_eval`'s network-call support confirmed first.

## Decisions

1. **One folder per downloadable plugin.** `repo/<plugin_id>/omnis_plugin.yaml`
   + entrypoint file (+ assets). No flat/name-matched-pair layout
   (`favorites.dart` + `favorites.omnis_plugin.yaml` side by side) —
   that would require new matching logic in `plugin_installer.dart`
   that doesn't exist today. This matches `sample_logger/` exactly and
   needs zero app-side code changes.
2. **New standalone doc:** `Omnis-Plugins/STRUCTURE.md`, not a README
   section. Single-purpose reference, linked from `README.md` and
   `CONTRIBUTING.md` rather than duplicated into them.
3. **Directory tree is CI-verified, not hand-maintained.** A checked-in
   generator script produces a tree between markers; a CI step
   regenerates it into a temp location and diffs against the committed
   copy, failing the build with rerun instructions if they differ.
   Auto-*committing* back onto PRs (including forks) is unreliable on
   GitHub Actions, so verify-and-fail beats auto-fix here.
4. **Cleanup, not migration.** Remove the stray tracked
   `lib/omnis_plugin.yaml` (contradicts the new rule — `lib/` never
   holds a manifest) and the untracked, broken `ai_playlist/` folder
   (Flutter code that can't run under the sandbox; owner confirmed
   removal over a same-session fix, since fixing it first requires
   confirming `dart_eval`'s network-call support — separate
   investigation).

## STRUCTURE.md contents

1. Framing paragraph: two plugin systems exist (bundled vs.
   downloadable); this doc only governs the downloadable one; full
   rules for both live in the main repo's `docs/PLUGIN_GUIDE.md` /
   `docs/COMMUNITY_PLUGINS.md` / `docs/ARCHITECTURE.md`.
2. The layout rule (decision 1), stated as the one supported pattern.
3. `omnis_plugin.yaml` field table — `id`, `name`, `description`,
   `version`, `author`, `entrypoint`, `min_omnis_version`, `hooks`,
   `permissions`, `dependencies`, `provides` — each marked
   required/optional with its default, sourced from
   `PluginManifest.parse` in the main repo's
   `lib/core/plugin_manifest.dart` so it can't drift from the parser
   silently.
4. Sandbox constraints callout: no `package:flutter`, no `dart:ui`, no
   platform channels, no direct `dart:io` — plain-Dart logic plus a
   declarative UI map only. Links to `PLUGIN_GUIDE.md` /
   `PLUGIN_SECURITY.md` for the full list.
5. Catalog listing: one-tap install via `catalog.json` /
   `officialPluginCatalog` requires a PR here; links to
   `CONTRIBUTING.md`.
6. Auto-generated tree, between `<!-- TREE:START -->` /
   `<!-- TREE:END -->` markers.

## Tree generator

New file `tool/generate_structure_tree.dart`:
- Walks the repo from its root.
- Excludes: `.git`, `.dart_tool`, `build`, any empty/junk top-level
  folder with no tracked contents, and other standard build noise.
- Collapses `lib/` to a single summary line (e.g. `lib/  (~30 bundled
  plugin implementations — see README's plugin table)`) rather than
  listing every `.dart` file, so adding a bundled plugin doesn't force
  a tree regen.
- Lists downloadable-plugin folders (`sample_logger/`, future ones) in
  full, since that's the part this doc is about.
- Writes the result between the marker comments in `STRUCTURE.md`.
- Run locally via `dart run tool/generate_structure_tree.dart`.

New CI job step in `.github/workflows/ci.yml` (after `flutter pub get`):
regenerate into a temp file, `diff` against the committed
`STRUCTURE.md`, fail with a clear message pointing at the local-run
command if they differ.

## Out-of-scope follow-ups worth tracking later

- Per-plugin feasibility pass over the ~30 bundled plugins to decide
  which could become downloadable.
- Confirming `dart_eval`'s network/HTTP capability, then rebuilding
  `ai_playlist` as a real downloadable plugin if feasible.
