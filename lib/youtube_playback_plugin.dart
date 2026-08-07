import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

/// Plays a YouTube video's real audio+video through YouTube's own
/// official embedded IFrame player — the only ToS-compliant way for a
/// third-party app to play YouTube content. Extracting a raw playable
/// stream URL from YouTube (yt-dlp/youtube-dl style) violates YouTube's
/// Terms of Service and is exactly the kind of stream-extraction this
/// project declines to build; the embedded player is real YouTube
/// playback, just through YouTube's UI, not Omnis's own [AudioEngine] —
/// no EQ, crossfade, gapless, or queue integration applies to it, the
/// same honest limitation `SpotifyPlaybackPlugin`'s Connect-remote-control
/// approach has for Spotify.
///
/// Deliberately its own small self-contained player (paste a video
/// URL/ID, watch/listen right there) rather than wired into Omnis's main
/// queue — a YouTube video isn't a `BaseTrack` Omnis can enqueue and play
/// the way a local file can, so pretending otherwise in the UI would be
/// misleading.
///
/// ### Platform support
///
/// The embedded player is a WebView under the hood
/// (`youtube_player_iframe` → `webview_flutter`), which has real,
/// maintained support on **Android, iOS, and web** — but Flutter has no
/// official WebView implementation for **Windows** (this project's
/// primary dev/test platform) or Linux. [isSupportedOnThisPlatform]
/// reports that honestly, and the settings view shows a plain "not
/// available on this platform" message instead of attempting to
/// construct a WebView that would fail to register.
///
/// **Verification status**: not run on a real Android/iOS device or web
/// build in this environment — implemented against the package's
/// documented API, not device-verified.
class YoutubePlaybackPlugin extends MusicPlugin {
  YoutubePlayerController? _controller;

  static bool get isSupportedOnThisPlatform =>
      kIsWeb || Platform.isAndroid || Platform.isIOS;

  YoutubePlayerController _ensureController() {
    return _controller ??= YoutubePlayerController(
      params: const YoutubePlayerParams(showControls: true, showFullscreenButton: true),
    );
  }

  /// Loads and plays [videoId] (the 11-character id from a YouTube URL,
  /// e.g. `dQw4w9WgXcQ` from `youtube.com/watch?v=dQw4w9WgXcQ`).
  void loadVideo(String videoId) {
    _ensureController().loadVideoById(videoId: videoId);
  }

  /// Extracts the video id from a full YouTube URL, or returns [input]
  /// unchanged if it already looks like a bare id.
  static String? videoIdFromInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.host.contains('youtu')) {
      if (uri.host.contains('youtu.be')) {
        return uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      }
      final v = uri.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
    }
    // A bare video id is exactly 11 URL-safe characters.
    final idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
    return idPattern.hasMatch(trimmed) ? trimmed : null;
  }

  @override
  String get id => 'youtube_playback';

  @override
  String get name => 'YouTube Playback';

  @override
  String get description => isSupportedOnThisPlatform
      ? 'Plays a YouTube video through YouTube\'s own embedded player.'
      : 'Not available on this platform (needs a WebView — Android, iOS, '
          'or web only).';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _YoutubePlaybackView(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _controller?.close();
  }
}

class _YoutubePlaybackView extends StatefulWidget {
  final YoutubePlaybackPlugin plugin;

  const _YoutubePlaybackView({required this.plugin});

  @override
  State<_YoutubePlaybackView> createState() => _YoutubePlaybackViewState();
}

class _YoutubePlaybackViewState extends State<_YoutubePlaybackView> {
  final _controller = TextEditingController();
  String? _error;
  String? _loadedVideoId;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _load() {
    final videoId = YoutubePlaybackPlugin.videoIdFromInput(_controller.text);
    if (videoId == null) {
      setState(() => _error = 'Paste a YouTube video URL or 11-character video ID.');
      return;
    }
    setState(() {
      _error = null;
      _loadedVideoId = videoId;
    });
    widget.plugin.loadVideo(videoId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!YoutubePlaybackPlugin.isSupportedOnThisPlatform) {
      return Text(
        'YouTube playback needs a WebView, which Flutter only supports on '
        'Android, iOS, and web today — not available on this platform.',
        style: TextStyle(color: theme.colorScheme.error),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Paste a YouTube video URL or id to play it here, through '
          'YouTube\'s own player.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'YouTube URL or video ID',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _load, child: const Text('Play')),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_loadedVideoId != null) ...[
          const SizedBox(height: 12),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: YoutubePlayer(controller: widget.plugin._ensureController()),
          ),
        ],
      ],
    );
  }
}
