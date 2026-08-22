# Documentation directory

Everything technical about this repo, in one place. If you just want
to know what this repo *is*, read the [root README](../README.md)
instead — this folder is the "how it actually works" layer underneath
it.

| Doc | What's in it |
|---|---|
| [STRUCTURE.md](STRUCTURE.md) | How to build a downloadable plugin: the one supported folder layout, the full `omnis_plugin.yaml` field reference, and what the sandbox will and won't run |
| [PLUGINS.md](PLUGINS.md) | Every bundled plugin, what it does, what permissions it needs, and its honest verification status |
| [VERSIONING.md](VERSIONING.md) | How this repo and the main Omnis repo stay pinned to each other by git tag |

Building a **bundled** plugin (full platform access, ships inside the
app)? Start with [../CONTRIBUTING.md](../CONTRIBUTING.md) — the deep
rules (the `MusicPlugin` lifecycle, `PluginContext`/`PluginStorage`,
code style) live in the main Omnis repo:
[CONTRIBUTING.md](https://github.com/MrIvoe/Omnis/blob/main/CONTRIBUTING.md),
[docs/PLUGIN_GUIDE.md](https://github.com/MrIvoe/Omnis/blob/main/docs/PLUGIN_GUIDE.md).

Building a **downloadable** plugin (installs from a pasted GitHub URL,
sandboxed)? Start with [STRUCTURE.md](STRUCTURE.md) above.
