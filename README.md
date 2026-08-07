# Omnis-Plugins

Bundled plugin implementations for [Omnis](https://github.com/MrIvoe/Omnis)
— compiled directly into the app, with full platform access. Depends only
on `omnis_plugin_api` (a dependency-free contracts package living inside
the Omnis repo at `packages/omnis_plugin_api`), never on Omnis internals,
so there's no circular dependency between this repo and the app.

## Versioning

Pinned to `omnis_plugin_api` by git tag (`pubspec.yaml`'s `ref:`), not a
floating branch — a push to Omnis never silently changes what this
package builds against. Omnis pins back to this repo the same way. To
pick up new work on purpose: cut a new tag here, then bump the `ref:` in
Omnis's `pubspec.yaml`, as its own reviewed commit.

See the plugin table below for what's implemented, along with the
Omnis-side docs: [ARCHITECTURE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/ARCHITECTURE.md),
[PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md).
