# Contributing to Omnis-Plugins

This repo holds the **bundled** plugins that ship compiled into
[Omnis](https://github.com/MrIvoe/Omnis) — full platform access, no
sandbox, reviewed the same as any other Omnis change. Building a
**downloadable** plugin instead (installs from a pasted GitHub URL,
sandboxed, permission-gated)? You can build and host that right in
this repo, in its own folder — see
[docs/STRUCTURE.md](docs/STRUCTURE.md) for the exact layout and yaml
format, then list it in `catalog.json` once it works.

The full rules — the Core/plugin split, `MusicPlugin` lifecycle,
`PluginContext`/`PluginStorage`, code style, testing conventions — live
in the main repo's [CONTRIBUTING.md](https://github.com/MrIvoe/Omnis/blob/main/CONTRIBUTING.md)
and [docs/PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md);
this file only covers what's specific to working in *this* repo.

## Before you start

- This package depends only on `omnis_plugin_api`
  (`packages/omnis_plugin_api` in the Omnis repo) — never on Omnis
  internals. If your change needs something from Omnis directly, that's
  a sign it needs a new capability added to `omnis_plugin_api` first,
  as its own reviewed change in the Omnis repo.
- New bundled plugin, or change to an existing one? Add or update its
  entry in [docs/PLUGINS.md](docs/PLUGINS.md), including an honest
  "Verification status" — see the existing rows for the tone: this
  project would rather say "implemented against a documented API, not
  exercised against a real device" than imply something is more tested
  than it is.

## Development workflow

```bash
flutter pub get
flutter analyze
flutter test
```

Both must be clean before opening a PR. A new plugin or a behavior
change comes with tests — mock HTTP/hardware where a real dependency
isn't practical in CI, the same pattern the existing plugin tests use.

## Versioning

This repo is pinned to `omnis_plugin_api` by git tag, and Omnis pins
back to this repo by git tag — see [docs/VERSIONING.md](docs/VERSIONING.md).
If your PR needs a capability that doesn't exist in
`omnis_plugin_api` yet, that's a separate, reviewed change in the Omnis
repo first, then a tag bump here.

## Conduct

See the main repo's
[CODE_OF_CONDUCT.md](https://github.com/MrIvoe/Omnis/blob/main/CODE_OF_CONDUCT.md) —
it applies here too.
