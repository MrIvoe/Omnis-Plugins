# Versioning

This repo is pinned to `omnis_plugin_api` by git tag (`pubspec.yaml`'s
`ref:`), not a floating branch — a push to Omnis never silently changes
what this package builds against. Omnis pins back to this repo the
same way. To pick up new work on purpose: cut a new tag here, then bump
the `ref:` in Omnis's `pubspec.yaml`, as its own reviewed commit.

See also the Omnis-side docs:
[ARCHITECTURE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/ARCHITECTURE.md),
[PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md).
