# Versioning

This repo is pinned to `omnis_plugin_api` by git tag (`pubspec.yaml`'s
`ref:`), not a floating branch — a push to Omnis never silently changes
what this package builds against. Omnis pins back to this repo the
same way. To pick up new work on purpose: cut a new tag here, then bump
the `ref:` in Omnis's `pubspec.yaml`, as its own reviewed commit.

**If the work you're releasing also needs a newer `omnis_plugin_api`
pin** (you're using new API surface added to that package), bump
*this repo's own* `omnis_plugin_api:` ref in `pubspec.yaml` and commit
that first — then cut the new tag at that commit, never before it. A
tag cut before the pin-bump commit still points at the old
`omnis_plugin_api` ref, which is invisible locally (a
`pubspec_overrides.yaml` pointing at a sibling checkout resolves around
any tag entirely) but breaks a clean checkout outright: Omnis resolving
the new `omnis_plugin_api` tag while this repo's tag still declares the
old one is an unresolvable version conflict, not a silent fallback.
This exact ordering mistake has shipped before — a tag cut one commit
too early, before its own pin bump landed — and only surfaced once
someone resolved both repos from their published tags with no local
override in place, the same way a clean CI checkout does.

See also the Omnis-side docs:
[ARCHITECTURE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/ARCHITECTURE.md),
[PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md).
