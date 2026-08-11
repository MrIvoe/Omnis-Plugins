 # Omnis-Plugins
 
+[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
+[![Catalog](https://img.shields.io/badge/catalog-mrivoe.github.io%2FOmnis--Plugins-A78BFA)](https://mrivoe.github.io/Omnis-Plugins/)
+[![Omnis app](https://img.shields.io/badge/app-mrivoe.github.io%2FOmnis-3DDCC4)](https://mrivoe.github.io/Omnis/)
+
 Bundled plugin implementations for [Omnis](https://github.com/MrIvoe/Omnis)
 — compiled directly into the app, with full platform access. Depends only
 on `omnis_plugin_api` (a dependency-free contracts package living inside
@@ -46,7 +50,7 @@ for the two that need a physical device to verify at all.
 | `SpotifyImportPlugin` | Browse/import Spotify playlists (metadata only, OAuth) | Network, OAuth | ⚠️ Not exercised against a real Spotify account |
 | `SpotifyPlaybackPlugin` | Remote-control playback on a Spotify Connect device | Network, OAuth | ⚠️ Not exercised against a real Spotify account/device |
 | `TagEditorPlugin` | Read/write every standard ID3 frame plus custom fields | Storage write | ✅ Verified via `test/id3_codec_safety_test.dart` and round-trip tests |
-| `VisualizerPlugin` | Animated spectrum-style bars in Now Playing | None | UI-driven, not real spectrum analysis — noted in its own doc, not a hidden gap |
+| `VisualizerPlugin` | Real spectrum bars via native FFT capture (`audify`) | Microphone (`RECORD_AUDIO` — an OS requirement of the native Visualizer/AVAudioEngine capture APIs, not a choice this plugin makes; requested lazily on first open, never at startup) | ⚠️ Real capture wired up, replacing an earlier hardcoded demo array; not yet exercised against a real device's audio output |
 | `YoutubeMusicImportPlugin` | Search/browse YouTube playlists (metadata only) | Network, OAuth/API key | ⚠️ Not exercised against a real Google Cloud OAuth client |
 | `YoutubePlaybackPlugin` | Plays a video through YouTube's own embedded player (Android/iOS/web only) | WebView | ⚠️ Not run on a real device or web build |
