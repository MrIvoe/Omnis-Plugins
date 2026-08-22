# Bundled plugins

Everything below ships compiled into every Omnis install (`lib/` in
this repo). "Verification status" reflects each plugin's own doc
comments, not a guess — several are honest that they're implemented
against a documented API but haven't been exercised against real
hardware or a real account. ⚠️ entries are exactly those; see
[docs/MANUAL_QA.md](https://github.com/MrIvoe/Omnis/blob/main/docs/MANUAL_QA.md)
for the two that need a physical device to verify at all.

| Plugin | What it does | Permissions / capabilities | Verification |
|---|---|---|---|
| `AudioAnalysisPlugin` | BPM/key/mood via a self-hosted Essentia service | Network | ⚠️ Client unit-tested against mocked responses; the companion service has not been built/run end-to-end |
| `BluetoothPlaybackPlugin` | Quick-play library/mood/playlist when a Bluetooth device connects | Bluetooth | ⚠️ Implemented against `audio_session`'s documented API; not exercised against a real device |
| `DrivingModePlugin` | Auto-switches to Car Mode layout above a GPS speed threshold | Location (foreground) | ⚠️ Implemented against `geolocator`'s documented API; not exercised against real movement — see [MANUAL_QA.md](https://github.com/MrIvoe/Omnis/blob/main/docs/MANUAL_QA.md) |
| `EqualizerPlugin` | Real per-band hardware EQ on Android; 3-band virtual model elsewhere | Hardware EQ (via `PluginContext`) | ⚠️ Hardware path not exercised against a real Android device |
| `FavoritesPlugin` | Mark tracks as favorites for quick access | None | No caveat noted |
| `LyricsPlugin` | Manual or auto-fetched (lrclib.net) synced lyrics | Network | No caveat noted |
| `MetadataEnrichmentPlugin` | Canonical track info + genre/mood tags from MusicBrainz/Last.fm/Discogs | Network | No caveat noted |
| `QueuePresetPlugin` | Chill/Focus/Workout/Sleep queues from BPM + genre keywords | None | No caveat noted |
| `RatingsPlugin` | 0-5 star rating per track | None | No caveat noted |
| `ReplayGainPlugin` | Loudness normalization from ReplayGain tags | None | No caveat noted |
| `RingtonePlugin` | Set a track as ringtone/notification/alarm (Android only) | Write settings (`set_ringtone`) | ⚠️ Implemented against `set_ringtone`'s documented API; not exercised against a real Android device |
| `ScrobblePlugin` | Play history for recently-played/most-played lists | None | No caveat noted |
| `ShuffleRepeatPlugin` | Remembers shuffle/repeat mode across restarts | None | No caveat noted |
| `SleepTimerPlugin` | Pause playback after a chosen duration | None | No caveat noted |
| `SmartPlaylistPlugin` | Mood-tag-based autoplay queues | None | No caveat noted |
| `SpotifyImportPlugin` | Browse/import Spotify playlists (metadata only, OAuth) | Network, OAuth | ⚠️ Not exercised against a real Spotify account |
| `SpotifyPlaybackPlugin` | Remote-control playback on a Spotify Connect device | Network, OAuth | ⚠️ Not exercised against a real Spotify account/device |
| `TagEditorPlugin` | Read/write every standard ID3 frame plus custom fields | Storage write | ✅ Verified via `test/id3_codec_safety_test.dart` and round-trip tests |
| `VisualizerPlugin` | Real spectrum bars via native FFT capture (`audify`) | Microphone (`RECORD_AUDIO` — an OS requirement of the native Visualizer/AVAudioEngine capture APIs, not a choice this plugin makes; requested lazily on first open, never at startup) | ⚠️ Real capture wired up, replacing an earlier hardcoded demo array; not yet exercised against a real device's audio output |
| `YoutubeMusicImportPlugin` | Search/browse YouTube playlists (metadata only) | Network, OAuth/API key | ⚠️ Not exercised against a real Google Cloud OAuth client |
| `YoutubePlaybackPlugin` | Plays a video through YouTube's own embedded player (Android/iOS/web only) | WebView | ⚠️ Not run on a real device or web build |

Two more files back the OAuth flows above but aren't standalone
plugins: `spotify_auth.dart` and `youtube_auth.dart` — both also
self-flag as unverified against real accounts.

New plugin, or a behavior change to an existing one? Update this table
in the same PR — see [CONTRIBUTING.md](../CONTRIBUTING.md).
