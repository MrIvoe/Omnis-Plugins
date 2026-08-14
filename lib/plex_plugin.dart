import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Connects to a self-hosted Plex Media Server via its REST API.
///
/// Like `OpenSubsonicPlugin`/`JellyfinPlugin`, and unlike
/// `SpotifyImportPlugin`'s metadata-only imports, this is a **real,
/// directly playable** streaming provider — each track's
/// [BaseTrack.streamUrl] points at the actual media file Plex serves,
/// playable through the exact path Radio/YouTube/OpenSubsonic/Jellyfin
/// tracks already use (`AudioEngine.uriFor` plays any track with a
/// `streamUrl` set).
///
/// A third, separate plugin rather than reusing either existing one:
/// Plex's auth model is a single account-scoped `X-Plex-Token` sent on
/// every request, not a per-request computed token (OpenSubsonic) or a
/// session exchanged via a login call (Jellyfin) — this plugin
/// deliberately does **not** implement the `plex.tv` sign-in/PIN-pairing
/// flow real Plex account holders normally use to obtain that token; the
/// user is expected to already have one (a well-documented, standard
/// step for any third-party Plex client — Tautulli, PlexPy, and many
/// scripts all start the same way: "paste your X-Plex-Token"). Building
/// the full plex.tv OAuth-like flow is real, separate work.
///
/// Plex's `/search` response mixes every media type it knows about
/// (movies, shows, artists, albums, tracks, ...) in one flat list — only
/// entries with `"type": "track"` are kept. Field shapes differ from
/// both other providers: an artist name lives on `grandparentTitle` (not
/// `artist`/`Artists`), duration is `duration` in **milliseconds** (not
/// Jellyfin's 100-nanosecond ticks or OpenSubsonic's seconds), and the
/// real stream path is nested three levels down
/// (`Media[0].Part[0].key`), not a top-level id this plugin can build a
/// stream URL from directly the way `search3.view`'s `id`/`stream.view`
/// or `/Items`'s `Id`/`/Audio/{id}/stream` can.
///
/// This has not been exercised against a real Plex Media Server in this
/// environment — what's verified is protocol-level request/response
/// handling against a mocked HTTP client (see this class's tests), not a
/// live server round-trip.
class PlexPlugin extends MusicPlugin {
  static const _serverUrlKey = 'server_url';
  static const _tokenKey = 'token';

  final http.Client _client;

  String? lastError;

  PlexPlugin({http.Client? client}) : _client = client ?? http.Client();

  String get serverUrl => storage.getString(_serverUrlKey) ?? '';
  Future<void> setServerUrl(String url) =>
      storage.setString(_serverUrlKey, url.trim());

  /// The account-scoped `X-Plex-Token` the user already has (see class
  /// doc for why obtaining one isn't handled by this plugin).
  String get token => storage.getString(_tokenKey) ?? '';
  Future<void> setToken(String value) =>
      storage.setString(_tokenKey, value.trim());

  bool get isConfigured => serverUrl.isNotEmpty && token.isNotEmpty;

  String? _normalizedBase() {
    final base = serverUrl.trim();
    if (base.isEmpty) return null;
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || !parsed.hasScheme) return null;
    return normalized;
  }

  Map<String, String> _headers() => {
        'Accept': 'application/json',
        'X-Plex-Token': token,
      };

  /// Verifies the configured server/token actually work by listing
  /// library sections — a real authenticated call, not just a bare
  /// reachability ping. Never throws — a failure sets [lastError] and
  /// returns `false`.
  Future<bool> testConnection() async {
    if (!isConfigured) {
      lastError = 'Server URL and token are both required.';
      return false;
    }
    final base = _normalizedBase();
    if (base == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return false;
    }
    try {
      final resp = await _client
          .get(Uri.parse('$base/library/sections'), headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401) {
        lastError = 'Invalid or expired token.';
        return false;
      }
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return false;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map || decoded['MediaContainer'] == null) {
        lastError = 'Unrecognized response from server.';
        return false;
      }
      lastError = null;
      return true;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  /// Searches the server for tracks matching [query] — real, directly
  /// playable results (only `"type": "track"` entries from Plex's mixed
  /// `/search` response; movies/shows/artists/albums/etc. are filtered
  /// out). Returns an empty list (with [lastError] set on genuine
  /// failure) for a blank query, an unconfigured plugin, a network
  /// failure, or a non-200 response — never throws.
  Future<List<BaseTrack>> search(String query, {int limit = 25}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !isConfigured) return const [];
    final base = _normalizedBase();
    if (base == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return const [];
    }
    final uri = Uri.parse('$base/search')
        .replace(queryParameters: {'query': trimmed});
    try {
      final resp = await _client
          .get(uri, headers: _headers())
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return const [];
      }
      final decoded = jsonDecode(resp.body);
      final container = decoded is Map ? decoded['MediaContainer'] : null;
      final metadata = container is Map ? container['Metadata'] : null;
      if (metadata is! List) {
        lastError = null;
        return const [];
      }
      final tracks = <BaseTrack>[];
      // Per-entry defensive decoding — one malformed/unexpected entry
      // must not wipe the rest of the search result, the same contract
      // every other network-backed plugin in this repo follows.
      for (final entry in metadata) {
        if (tracks.length >= limit) break;
        if (entry is! Map) continue;
        if (entry['type'] != 'track') continue;
        try {
          final track = _metadataToTrack(Map<String, dynamic>.from(entry), base);
          if (track != null) tracks.add(track);
        } catch (_) {
          continue;
        }
      }
      lastError = null;
      return tracks;
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  BaseTrack? _metadataToTrack(Map<String, dynamic> json, String base) {
    final ratingKey = json['ratingKey']?.toString();
    final title = json['title']?.toString();
    if (ratingKey == null || ratingKey.isEmpty || title == null || title.isEmpty) {
      return null;
    }

    final partKey = _firstPartKey(json['Media']);
    if (partKey == null || partKey.isEmpty) {
      // No playable file reference at all — nothing to stream.
      return null;
    }
    final streamUrl = Uri.parse('$base$partKey')
        .replace(queryParameters: {'X-Plex-Token': token}).toString();

    final artist = json['grandparentTitle']?.toString();
    final album = json['parentTitle']?.toString();
    final durationMs = json['duration'];
    final index = json['index'];
    final year = json['year'];
    final thumb = json['thumb']?.toString();
    final coverArt = (thumb != null && thumb.isNotEmpty)
        ? Uri.parse('$base$thumb')
            .replace(queryParameters: {'X-Plex-Token': token}).toString()
        : null;

    return BaseTrack(
      id: 'plex:$ratingKey',
      title: title,
      artists: [
        (artist != null && artist.isNotEmpty) ? artist : 'Unknown Artist',
      ],
      album: (album != null && album.isNotEmpty) ? album : 'Unknown Album',
      // Plex reports duration in milliseconds; BaseTrack.duration is
      // seconds everywhere else in this app.
      duration: durationMs is int ? durationMs ~/ 1000 : 0,
      trackNumber: index is int ? index : null,
      year: year is int ? year : null,
      type: TrackType.plex,
      streamUrl: streamUrl,
      coverArt: coverArt,
    );
  }

  /// Digs out `Media[0].Part[0].key` — the actual streamable file path —
  /// from a track's `Media` field, defensively at every level (any
  /// shape Plex didn't promise stays a clean `null`, not a cast
  /// exception).
  String? _firstPartKey(dynamic media) {
    if (media is! List || media.isEmpty) return null;
    final firstMedia = media.first;
    if (firstMedia is! Map) return null;
    final parts = firstMedia['Part'];
    if (parts is! List || parts.isEmpty) return null;
    final firstPart = parts.first;
    if (firstPart is! Map) return null;
    return firstPart['key']?.toString();
  }

  @override
  String get id => 'plex';

  @override
  String get name => 'Plex';

  @override
  String get description =>
      'Connect to a self-hosted Plex Media Server and stream directly '
      'from it.';

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
      locationID == 'plugin_settings' ? _PlexSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _PlexSettings extends StatefulWidget {
  final PlexPlugin plugin;

  const _PlexSettings({required this.plugin});

  @override
  State<_PlexSettings> createState() => _PlexSettingsState();
}

class _PlexSettingsState extends State<_PlexSettings> {
  late final TextEditingController _serverController;
  late final TextEditingController _tokenController;
  final _searchController = TextEditingController();

  bool _testing = false;
  bool? _lastTestOk;
  bool _searching = false;
  List<BaseTrack> _results = const [];

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: widget.plugin.serverUrl);
    _tokenController = TextEditingController(text: widget.plugin.token);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _tokenController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    await widget.plugin.setServerUrl(_serverController.text);
    await widget.plugin.setToken(_tokenController.text);
    setState(() => _testing = true);
    final ok = await widget.plugin.testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _lastTestOk = ok;
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    final results = await widget.plugin.search(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  Future<void> _play(int index) async {
    final context = widget.plugin.context;
    if (context == null) return;
    await context.setQueue(_results, startIndex: index);
    await context.play();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect to a Plex Media Server you already run. Needs your '
          'account\'s X-Plex-Token — see plex.tv/support for how to '
          'find it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://192.168.1.10:32400',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _tokenController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'X-Plex-Token',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_testing ? 'Testing…' : 'Test connection'),
            ),
            if (_lastTestOk != null) ...[
              const SizedBox(width: 8),
              Icon(
                _lastTestOk! ? Icons.check_circle : Icons.error,
                color: _lastTestOk! ? Colors.green : theme.colorScheme.error,
              ),
            ],
          ],
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 20),
        Text('Search & play', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            labelText: 'Search your library',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search),
          ),
          onSubmitted: _search,
        ),
        if (_searching) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ] else if (_results.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (var i = 0; i < _results.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: Text(_results[i].title),
              subtitle: Text(_results[i].artists.join(', ')),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => _play(i),
            ),
        ],
      ],
    );
  }
}
