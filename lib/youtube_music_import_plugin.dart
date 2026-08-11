import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/youtube_auth.dart';

/// One playlist from the connected YouTube account.
class YoutubePlaylist {
  final String id;
  final String title;
  final int itemCount;

  const YoutubePlaylist({required this.id, required this.title, required this.itemCount});
}

/// Browses and imports playlist/video *metadata* from YouTube via the
/// YouTube Data API v3.
///
/// Two independent capabilities, matching two different auth needs:
///  - **Public search** ([searchPublic]) needs only an API key (a simple
///    server key from Google Cloud Console, no user login) — works
///    against any public video/playlist.
///  - **Your own playlists** ([fetchMyPlaylists]/[fetchPlaylistItems])
///    needs a full OAuth connection ([connect]), since they're private to
///    the signed-in account.
///
/// Like `SpotifyImportPlugin`, this is metadata-only: a `BaseTrack(type:
/// TrackType.youtube, youtubeId: ...)` describes a video, it doesn't make
/// it playable through Omnis's own [AudioEngine] — YouTube's Data API
/// returns metadata, not a decodable audio stream (extracting one would
/// mean scraping YouTube's playback pipeline, which violates its ToS and
/// is exactly the kind of stream-extraction this project avoids).
/// `YouTubePlaybackPlugin` covers actual playback, through YouTube's own
/// official embedded player — a genuinely different mechanism, which is
/// why it's a separate plugin.
///
/// **Verification status**: unverified against a real Google Cloud OAuth
/// client/API key in this environment — see `YoutubeAuth`'s doc comment.
class YoutubeMusicImportPlugin extends MusicPlugin {
  static const _apiKeyStorageKey = 'youtube_api_key';

  final http.Client _client;
  late final YoutubeAuth _auth = YoutubeAuth(storage: storage, client: _client);

  String? lastError;

  YoutubeMusicImportPlugin({http.Client? client}) : _client = client ?? http.Client();

  String get apiKey => storage.getString(_apiKeyStorageKey) ?? '';
  Future<void> setApiKey(String key) => storage.setString(_apiKeyStorageKey, key.trim());

  bool get isConnected => _auth.isConnected;
  String get clientId => _auth.clientId;
  Future<void> setClientId(String id) => _auth.setClientId(id);
  String get clientSecret => _auth.clientSecret;
  Future<void> setClientSecret(String secret) => _auth.setClientSecret(secret);

  Future<bool> connect() async {
    final ok = await _auth.connect();
    lastError = ok ? null : 'Could not connect. Check the Client ID/Secret and try again.';
    return ok;
  }

  Future<void> disconnect() => _auth.disconnect();

  /// Public video search — works with just [apiKey], no OAuth connection
  /// required. Returns metadata only, same caveats as class doc.
  Future<List<BaseTrack>> searchPublic(String query) async {
    if (apiKey.isEmpty) {
      lastError = 'No API key configured.';
      return const [];
    }
    try {
      final resp = await _client
          .get(Uri.https('www.googleapis.com', '/youtube/v3/search', {
            'part': 'snippet',
            'type': 'video',
            'videoCategoryId': '10', // Music
            'q': query,
            'maxResults': '25',
            'key': apiKey,
          }))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'YouTube returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final items = json is Map ? json['items'] : null;
      if (items is! List) return const [];
      lastError = null;
      return items.whereType<Map>().map(_trackFromSearchItem).whereType<BaseTrack>().toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  BaseTrack? _trackFromSearchItem(Map json) {
    final id = json['id'];
    final videoId = id is Map ? id['videoId']?.toString() : null;
    final snippet = json['snippet'];
    if (videoId == null || snippet is! Map) return null;
    final title = snippet['title']?.toString();
    if (title == null) return null;
    final channelTitle = snippet['channelTitle']?.toString() ?? 'Unknown Artist';
    final thumbnails = snippet['thumbnails'];
    final thumb = thumbnails is Map ? thumbnails['high'] ?? thumbnails['default'] : null;
    final coverArt = thumb is Map ? thumb['url']?.toString() : null;

    return BaseTrack(
      id: 'youtube:$videoId',
      title: title,
      artists: [channelTitle],
      album: '',
      duration: 0, // search results don't include duration; videos.list would
      type: TrackType.youtube,
      youtubeId: videoId,
      coverArt: coverArt,
    );
  }

  Future<Map<String, String>?> _authHeader() async {
    final token = await _auth.validAccessToken();
    if (token == null) {
      lastError = 'Not connected to YouTube.';
      return null;
    }
    return {'Authorization': 'Bearer $token'};
  }

  /// The connected account's own playlists. Requires [connect].
  Future<List<YoutubePlaylist>> fetchMyPlaylists() async {
    final headers = await _authHeader();
    if (headers == null) return const [];
    try {
      final resp = await _client
          .get(
            Uri.https('www.googleapis.com', '/youtube/v3/playlists',
                {'part': 'snippet,contentDetails', 'mine': 'true', 'maxResults': '50'}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'YouTube returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final items = json is Map ? json['items'] : null;
      if (items is! List) return const [];
      lastError = null;
      return items.whereType<Map>().map((item) {
        final snippet = item['snippet'];
        final contentDetails = item['contentDetails'];
        final count = contentDetails is Map ? contentDetails['itemCount'] : null;
        return YoutubePlaylist(
          id: item['id']?.toString() ?? '',
          title: snippet is Map ? (snippet['title']?.toString() ?? 'Untitled playlist') : 'Untitled playlist',
          itemCount: count is num ? count.toInt() : 0,
        );
      }).where((p) => p.id.isNotEmpty).toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  /// Video metadata for one playlist's items.
  Future<List<BaseTrack>> fetchPlaylistItems(String playlistId) async {
    final headers = await _authHeader();
    if (headers == null) return const [];
    try {
      final resp = await _client
          .get(
            Uri.https('www.googleapis.com', '/youtube/v3/playlistItems', {
              'part': 'snippet',
              'playlistId': playlistId,
              'maxResults': '50',
            }),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'YouTube returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final items = json is Map ? json['items'] : null;
      if (items is! List) return const [];
      lastError = null;
      return items.whereType<Map>().map(_trackFromPlaylistItem).whereType<BaseTrack>().toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  BaseTrack? _trackFromPlaylistItem(Map json) {
    final snippet = json['snippet'];
    if (snippet is! Map) return null;
    final resourceId = snippet['resourceId'];
    final videoId = resourceId is Map ? resourceId['videoId']?.toString() : null;
    final title = snippet['title']?.toString();
    if (videoId == null || title == null) return null;
    final channelTitle = snippet['videoOwnerChannelTitle']?.toString() ??
        snippet['channelTitle']?.toString() ??
        'Unknown Artist';
    final thumbnails = snippet['thumbnails'];
    final thumb = thumbnails is Map ? thumbnails['high'] ?? thumbnails['default'] : null;
    final coverArt = thumb is Map ? thumb['url']?.toString() : null;

    return BaseTrack(
      id: 'youtube:$videoId',
      title: title,
      artists: [channelTitle],
      album: '',
      duration: 0,
      type: TrackType.youtube,
      youtubeId: videoId,
      coverArt: coverArt,
    );
  }

  @override
  String get id => 'youtube_music_import';

  @override
  String get name => 'YouTube Music Import';

  @override
  String get description => apiKey.isNotEmpty || isConnected
      ? 'Search YouTube and browse your playlists.'
      : 'Add an API key (public search) or connect an account (your own '
          'playlists) in this plugin\'s settings.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() => _auth.warmUp();

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _YoutubeImportSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _YoutubeImportSettings extends StatefulWidget {
  final YoutubeMusicImportPlugin plugin;

  const _YoutubeImportSettings({required this.plugin});

  @override
  State<_YoutubeImportSettings> createState() => _YoutubeImportSettingsState();
}

class _YoutubeImportSettingsState extends State<_YoutubeImportSettings> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _clientIdController;
  late final TextEditingController _clientSecretController;
  bool _connecting = false;
  bool _loadingPlaylists = false;
  List<YoutubePlaylist> _playlists = const [];

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.plugin.apiKey);
    _clientIdController = TextEditingController(text: widget.plugin.clientId);
    _clientSecretController = TextEditingController(text: widget.plugin.clientSecret);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    await widget.plugin.setClientId(_clientIdController.text);
    await widget.plugin.setClientSecret(_clientSecretController.text);
    // The OAuth browser round-trip inside connect() is exactly the kind
    // of long-running await this page can easily get disposed out from
    // under — navigating away mid-flow must not crash on return.
    final ok = await widget.plugin.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (ok) await _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    if (!mounted) return;
    setState(() => _loadingPlaylists = true);
    final playlists = await widget.plugin.fetchMyPlaylists();
    if (mounted) {
      setState(() {
        _playlists = playlists;
        _loadingPlaylists = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Public search', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'A free API key from Google Cloud Console (YouTube Data API v3) '
          'is enough to search public videos — no account connection '
          'needed.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _apiKeyController,
          decoration: const InputDecoration(
            labelText: 'YouTube Data API key',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.vpn_key),
          ),
          onChanged: (value) => plugin.setApiKey(value),
        ),
        const SizedBox(height: 20),
        Text('Your playlists', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Requires a full OAuth client (Google Cloud Console → Credentials '
          '→ OAuth client ID, type "Desktop app") with these exact redirect '
          'URIs added: http://127.0.0.1:${YoutubeAuth.loopbackPort}/callback '
          '(desktop) and omnis://callback (Android/iOS).',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _clientIdController,
          decoration: const InputDecoration(
            labelText: 'OAuth Client ID',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key),
          ),
          onChanged: (value) => plugin.setClientId(value),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _clientSecretController,
          decoration: const InputDecoration(
            labelText: 'OAuth Client Secret (if your client has one)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.password),
          ),
          obscureText: true,
          onChanged: (value) => plugin.setClientSecret(value),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (!plugin.isConnected)
              FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(_connecting ? 'Connecting…' : 'Connect'),
              )
            else ...[
              FilledButton.tonalIcon(
                onPressed: () async {
                  await plugin.disconnect();
                  if (mounted) setState(() => _playlists = const []);
                },
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _loadingPlaylists ? null : _loadPlaylists,
                icon: const Icon(Icons.refresh),
                label: const Text('Load playlists'),
              ),
            ],
          ],
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_loadingPlaylists) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ] else if (_playlists.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final playlist in _playlists)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.playlist_play),
              title: Text(playlist.title),
              subtitle: Text('${playlist.itemCount} videos'),
            ),
        ],
      ],
    );
  }
}
