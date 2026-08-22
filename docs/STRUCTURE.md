# Plugin structure reference

This repo hosts two unrelated kinds of plugin. This page only covers
the **downloadable** kind — the one anyone can add without touching
the Omnis app itself. For the full rules on both kinds (the
`MusicPlugin` lifecycle, `PluginContext`/`PluginStorage`, sandbox
internals), see the main repo's
[docs/PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md),
[docs/COMMUNITY_PLUGINS.md](https://github.com/MrIvoe/Omnis/blob/main/docs/COMMUNITY_PLUGINS.md),
and [docs/PLUGIN_SECURITY.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_SECURITY.md).

| | Bundled (`lib/`) | Downloadable (everything else in this repo) |
|---|---|---|
| Ships how | compiled into the Omnis binary | installed at runtime, by URL |
| Code access | full Flutter, platform channels | sandboxed plain Dart only |
| Manifest | none | `omnis_plugin.yaml`, required |
| Who adds it | reviewed PR to this repo | anyone, any public repo |

## The one supported layout

Every downloadable plugin is **one folder, at the root of a repo**,
containing exactly:

```
<plugin_id>/
├── omnis_plugin.yaml   ← manifest, this exact filename
├── plugin.dart         ← entrypoint (name it whatever `entrypoint:` says)
└── (anything else your plugin needs — assets, extra .dart files)
```

`sample_logger/` at the root of this repo is a working, minimal example
of this — copy it as a starting point.

There is no supported flat/no-folder layout (multiple plugins sharing
one directory with name-matched yaml files). The Omnis app's installer
looks for a fixed filename, `omnis_plugin.yaml`, inside whatever folder
you point it at — one folder, one plugin, one manifest.

You can host a plugin either as its own dedicated repo (folder = repo
root) or as a subfolder of a monorepo like this one — the app's
"paste a GitHub URL" installer accepts a `tree/<branch>/<subfolder>`
link either way.

## `omnis_plugin.yaml` field reference

Parsed by `PluginManifest.parse` in the main Omnis repo
(`lib/core/plugin_manifest.dart`) — this table is sourced directly from
that parser, not a separate description of it.

| Field | Required | Default if omitted | Meaning |
|---|---|---|---|
| `id` | **yes** | — (parse fails without it) | Unique plugin id |
| `name` | **yes** | — (parse fails without it) | Display name |
| `description` | no | `"No description"` | One-line summary shown to the user |
| `version` | no | `"0.0.1"` | Plugin version string |
| `author` | no | `"Unknown"` | Displayed to the user |
| `entrypoint` | no | `"plugin.dart"` | Which file in the folder to run |
| `min_omnis_version` | no | *(none)* | Refuses to install/register on an older app |
| `hooks` | no | `[]` | Which lifecycle hooks this plugin implements |
| `permissions` | no | `[]` | What this plugin needs from the app (e.g. `network`) — shown to the user in a confirmation dialog before any code runs |
| `dependencies` | no | `[]` | Other plugin `id`s that must already be installed |
| `provides` | no | `[]` | Capabilities this plugin registers for other plugins to use |

## What the sandbox will not run

Downloadable plugins execute through `dart_eval`, a restricted Dart
interpreter — not the full Flutter runtime. Concretely, a
`plugin.dart` **cannot**:

- `import 'package:flutter/...'` or `dart:ui`
- use platform channels (Bluetooth, hardware volume, native EQ, OS-level
  settings, etc.)
- make raw `dart:io` calls

It **can** hold plain-Dart logic and return a small declarative map for
UI (see `uiSlot()` in `sample_logger/plugin.dart` for the pattern) —
`{'type': 'badge', ...}`, rendered by the host app, not real widgets.
If a plugin idea needs any of the disallowed capabilities, it belongs
in the **bundled** system (`lib/`) instead — see this repo's
[CONTRIBUTING.md](../CONTRIBUTING.md).

Beyond the static UI badge, a plugin can also reach back into the app
for real capabilities — reading/controlling playback, editing the
queue, volume/gain, a small persistent key-value store, and announcing
events — each gated by declaring the matching permission. See the main
repo's
[docs/PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md#reaching-back-into-the-app-the-sandbox-bridge)
for the full function/permission table, and **read its "real dart_eval
gotcha" callout before writing an `async` hook that calls any of
them** — passing a bare literal (`'one'`, `{...}`, `[]`) to a bridge
function from `async` code crashes the interpreter; always derive the
value from your hook's own argument instead.

## Getting a one-tap catalog listing

A working downloadable plugin becomes one-tap-installable in the app
by being added to `catalog.json` at this repo's root (and mirrored in
the main repo's `officialPluginCatalog`). That's a PR here — see
[CONTRIBUTING.md](../CONTRIBUTING.md).

## Repo layout

<!-- TREE:START -->
<!-- Run `dart run tool/generate_structure_tree.dart` to regenerate. -->

```
Omnis-Plugins/
├── CONTRIBUTING.md           # workflow for contributing to this repo
├── README.md                 # start here
├── catalog.json              # one-tap-install catalog for downloadable plugins
├── docs/                     # documentation directory — see docs/README.md
├── lib/                      # ~30 bundled plugin implementations — see docs/PLUGINS.md
├── pubspec.yaml              # package manifest for the bundled-plugins package
├── sample_logger/            # example downloadable plugin — copy this to start one
├── test/                     # automated tests
└── tool/                     # repo maintenance scripts (this generator)
```
<!-- TREE:END -->
