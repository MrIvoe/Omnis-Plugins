import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/spotify_auth.dart';

/// One playlist from the connected Spotify account.
class SpotifyPlaylist {
  final String id;
  final String name;
  final int trackCount;

  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
  });
}

/// Browses and imports playlist/track *metadata* from a user's Spotify
/// account via Spotify's public Web API.
///
/// Deliberately metadata-only: this plugin does not and cannot play
/// Spotify's actual audio — Spotify's catalog is DRM-protected and the
/// Web API returns track/playlist data, not decodable audio. Imported
/// tracks come back as `BaseTrack(type: TrackType.spotify, spotifyId: ...)`
/// with no `localPath`, so they're recognisable everywhere `BaseTrack` is
/// used (Library, playlists) but Omnis's own `AudioEngine` — which only
/// plays local files and direct stream URLs — can't play them directly.
/// Actually controlling Spotify playback is `SpotifyPlaybackPlugin`'s job
/// (Spotify Connect remote control of the real Spotify app), a
/// deliberately separate plugin: importing your library and controlling
/// playback are different capabilities, and a user might reasonably want
/// one without the other.
///
/// See `SpotifyAuth`'s doc comment for the full OAuth/PKCE story,
/// including its verification status — this has not been exercised
/// against a real Spotify account in this environment.
class SpotifyImportPlugin extends MusicPlugin {
  final http.Client _client;
  late final SpotifyAuth _auth = SpotifyAuth(storage: storage, client: _client);

  String? lastError;

  SpotifyImportPlugin({http.Client? client}) : _client = client ?? http.Client();

  bool get isConnected => _auth.isConnected;
  String get clientId => _auth.clientId;
  Future<void> setClientId(String id) => _auth.setClientId(id);

  Future<bool> connect() async {
    final ok = await _auth.connect();
    lastError = ok ? null : 'Could not connect. Check the Client ID and try again.';
    return ok;
  }

  Future<void> disconnect() => _auth.disconnect();

  Future<Map<String, String>?> _authHeader() async {
    final token = await _auth.validAccessToken();
    if (token == null) {
      lastError = 'Not connected to Spotify.';
      return null;
    }
    return {'Authorization': 'Bearer $token'};
  }

  /// The connected user's playlists. Empty (with [lastError] set) on any
  /// failure — never throws.
  Future<List<SpotifyPlaylist>> fetchPlaylists() async {
    final headers = await _authHeader();
    if (headers == null) return const [];
    try {
      final resp = await _client
          .get(Uri.https('api.spotify.com', '/v1/me/playlists', {'limit': '50'}),
              headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Spotify returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final items = json is Map ? json['items'] : null;
      if (items is! List) return const [];
      lastError = null;
      return items.whereType<Map>().map((item) {
        final tracks = item['tracks'];
        final total = tracks is Map ? tracks['total'] : null;
        return SpotifyPlaylist(
          id: item['id']?.toString() ?? '',
          name: item['name']?.toString() ?? 'Untitled playlist',
          trackCount: total is num ? total.toInt() : 0,
        );
      }).where((p) => p.id.isNotEmpty).toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  /// Track metadata for one playlist, as [BaseTrack]s of
  /// `type: TrackType.spotify` — see class doc for why these aren't
  /// directly playable through [AudioEngine].
  Future<List<BaseTrack>> fetchPlaylistTracks(String playlistId) async {
    final headers = await _authHeader();
    if (headers == null) return const [];
    try {
      final resp = await _client
          .get(
            Uri.https('api.spotify.com', '/v1/playlists/$playlistId/tracks',
                {'limit': '100'}),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Spotify returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final items = json is Map ? json['items'] : null;
      if (items is! List) return const [];
      lastError = null;
      return items
          .whereType<Map>()
          .map((item) => item['track'])
          .whereType<Map>()
          .map(_trackFromSpotifyJson)
          .whereType<BaseTrack>()
          .toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  BaseTrack? _trackFromSpotifyJson(Map json) {
    final id = json['id']?.toString();
    final name = json['name']?.toString();
    if (id == null || name == null) return null;
    final artists = json['artists'];
    final artistNames = artists is List
        ? artists.whereType<Map>().map((a) => a['name']?.toString() ?? '').where((s) => s.isNotEmpty).toList()
        : <String>[];
    final album = json['album'];
    final albumName = album is Map ? album['name']?.toString() ?? '' : '';
    final images = album is Map ? album['images'] : null;
    final coverArt = images is List && images.isNotEmpty && images.first is Map
        ? (images.first as Map)['url']?.toString()
        : null;
    final durationMs = json['duration_ms'];

    return BaseTrack(
      id: 'spotify:$id',
      title: name,
      artists: artistNames.isEmpty ? const ['Unknown Artist'] : artistNames,
      album: albumName,
      duration: durationMs is num ? (durationMs / 1000).round() : 0,
      type: TrackType.spotify,
      spotifyId: id,
      coverArt: coverArt,
    );
  }

  @override
  String get id => 'spotify_import';

  @override
  String get name => 'Spotify Import';

  @override
  String get description => isConnected
      ? 'Connected — browse and import your Spotify playlists.'
      : 'Connect a Spotify account (in this plugin\'s settings) to browse '
          'and import your playlists.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _SpotifyImportSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _SpotifyImportSettings extends StatefulWidget {
  final SpotifyImportPlugin plugin;

  const _SpotifyImportSettings({required this.plugin});

  @override
  State<_SpotifyImportSettings> createState() => _SpotifyImportSettingsState();
}

class _SpotifyImportSettingsState extends State<_SpotifyImportSettings> {
  late final TextEditingController _clientIdController;
  bool _connecting = false;
  bool _loadingPlaylists = false;
  List<SpotifyPlaylist> _playlists = const [];

  @override
  void initState() {
    super.initState();
    _clientIdController = TextEditingController(text: widget.plugin.clientId);
  }

  @override
  void dispose() {
    _clientIdController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    await widget.plugin.setClientId(_clientIdController.text);
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
    final playlists = await widget.plugin.fetchPlaylists();
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
        Text(
          'Requires a free Spotify app registered at '
          'developer.spotify.com/dashboard, with these exact redirect '
          'URIs added: http://127.0.0.1:${SpotifyAuth.loopbackPort}/callback '
          '(desktop) and omnis://callback (Android/iOS).',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientIdController,
          decoration: const InputDecoration(
            labelText: 'Spotify Client ID',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key),
          ),
          onChanged: (value) => plugin.setClientId(value),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            if (!plugin.isConnected)
              FilledButton.icon(
                onPressed: _connecting ? null : _connect,
                icon: _connecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
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
          Text('Playlists', style: theme.textTheme.titleSmall),
          for (final playlist in _playlists)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              subtitle: Text('${playlist.trackCount} tracks'),
            ),
        ],
      ],
    );
  }
}
