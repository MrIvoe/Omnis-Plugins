import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Connects to a self-hosted Koel media server via its REST API.
///
/// Like `EmbyPlugin`/`JellyfinPlugin`/`OpenSubsonicPlugin`/`PlexPlugin`/
/// `AmpachePlugin`, and unlike `SpotifyImportPlugin`'s metadata-only
/// imports, this is a **real, directly playable** streaming provider.
///
/// A sixth genuinely different self-hosted auth shape: a plain
/// `POST /api/me` login with `{email, password}` (email, not a
/// Subsonic/Ampache-style username) returns a short-lived `token`,
/// passed back on every subsequent call as a `Bearer` header — closer
/// in spirit to a conventional web-app login than any sibling's own
/// handshake/salted-token/header-token scheme. Unlike every sibling
/// plugin's streaming URL, Koel's own `GET /play/{songId}/{transcode}/
/// {bitrate}` endpoint takes its auth as an `api-token` **query
/// parameter**, not the `Bearer` header the rest of the API uses — so
/// [BaseTrack.streamUrl] embeds the token directly in the URL, the same
/// query-param-token shape `OpenSubsonicPlugin` already uses for its own
/// stream URLs.
///
/// Koel *does* have a real server-side search endpoint
/// (`GET /api/search/songs?q=...`), unlike an earlier assumption this
/// plugin was almost built around — confirmed directly against Koel's
/// own published OpenAPI spec (github.com/koel/koel/blob/master/
/// api-docs/api.yaml), not assumed. That spec's own response schema for
/// this endpoint is genuinely underspecified (an empty `responses: {}`
/// in the published YAML — a real gap in Koel's own documentation, not
/// a research shortcoming), so [_songsToTracks] decodes defensively
/// for either a bare JSON array or a `{"songs": [...]}` wrapper, and
/// each song entry for either the plain `Song` shape (`artist_id`/
/// `album_id` only) or the enriched `SongWithAlbumAndArtist` shape
/// (embedded `artist`/`album` objects) the spec's schema components
/// separately document.
///
/// [BaseTrack.coverArt] is deliberately left `null` — Koel's own album-
/// thumbnail endpoint (`GET /api/album/{id}/thumbnail`) requires a
/// separate authenticated round-trip per album (it returns a JSON
/// `{"thumbnailUrl": ...}` wrapper, not a directly loadable image URL,
/// and needs a `Bearer` header the way the `/play` endpoint's query-
/// param token doesn't), which would mean one extra network call per
/// search result. Not attempted in this pass — the same "don't
/// manufacture a claim the data can't support" stance every sibling
/// plugin here already takes for a field it can't honestly fill in.
///
/// The session token is kept in memory only, re-authenticated on demand
/// — never persisted, unlike the email/password themselves, which are
/// stored in this plugin's own `PluginStorage`.
///
/// **This has not been exercised against a real Koel server in this
/// environment.** What's verified is protocol-level request/response
/// handling against a mocked HTTP client (see this class's tests),
/// modeled on Koel's own published OpenAPI spec — not a live server
/// round-trip.
class KoelPlugin extends MusicPlugin {
  static const _serverUrlKey = 'server_url';
  static const _emailKey = 'email';
  static const _passwordKey = 'password';

  final http.Client _client;

  String? _sessionToken;

  String? lastError;

  KoelPlugin({http.Client? client}) : _client = client ?? http.Client();

  String get serverUrl => storage.getString(_serverUrlKey) ?? '';
  Future<void> setServerUrl(String url) =>
      storage.setString(_serverUrlKey, url.trim());

  String get email => storage.getString(_emailKey) ?? '';
  Future<void> setEmail(String value) =>
      storage.setString(_emailKey, value.trim());

  String get password => storage.getString(_passwordKey) ?? '';
  Future<void> setPassword(String value) =>
      storage.setString(_passwordKey, value);

  bool get isConfigured =>
      serverUrl.isNotEmpty && email.isNotEmpty && password.isNotEmpty;

  String? _normalizedBase() {
    final base = serverUrl.trim();
    if (base.isEmpty) return null;
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || !parsed.hasScheme) return null;
    return normalized;
  }

  Map<String, String> _authHeader() =>
      {'Authorization': 'Bearer $_sessionToken'};

  /// Authenticates against `POST /api/me` and caches the session token
  /// in memory on success. Never throws — a failure sets [lastError]
  /// and returns `false`.
  Future<bool> _authenticate() async {
    if (!isConfigured) {
      lastError = 'Server URL, email, and password are all required.';
      return false;
    }
    final base = _normalizedBase();
    if (base == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return false;
    }
    try {
      final resp = await _client
          .post(
            Uri.parse('$base/api/me'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return false;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) {
        lastError = 'Unrecognized response from server.';
        return false;
      }
      final token = decoded['token']?.toString();
      if (token == null || token.isEmpty) {
        lastError = 'Server did not return a valid session.';
        return false;
      }
      _sessionToken = token;
      lastError = null;
      return true;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  /// Verifies the configured server/credentials actually work — a real
  /// login attempt, not just a reachability ping. Never throws.
  Future<bool> testConnection() => _authenticate();

  /// Searches the server's library for tracks matching [query] — real,
  /// directly playable results, via Koel's own `GET /api/search/songs`.
  /// Authenticates first if there's no cached session, and transparently
  /// re-authenticates exactly once on a `401` (an expired/invalid
  /// token) before giving up. Returns an empty list (with [lastError]
  /// set on genuine failure) for a blank query, an unconfigured plugin,
  /// a network failure, or a server error — never throws.
  Future<List<BaseTrack>> search(String query, {int limit = 25}) =>
      _search(query, limit: limit, retried: false);

  Future<List<BaseTrack>> _search(
    String query, {
    required int limit,
    required bool retried,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (_sessionToken == null) {
      final ok = await _authenticate();
      if (!ok) return const [];
    }
    final base = _normalizedBase();
    if (base == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return const [];
    }
    final uri = Uri.parse('$base/api/search/songs')
        .replace(queryParameters: {'q': trimmed});
    try {
      final resp =
          await _client.get(uri, headers: _authHeader()).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401 && !retried) {
        final ok = await _authenticate();
        if (!ok) return const [];
        return _search(query, limit: limit, retried: true);
      }
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return const [];
      }
      final tracks = _songsToTracks(jsonDecode(resp.body), base);
      lastError = null;
      return tracks.take(limit).toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  /// Decodes either a bare JSON array or a `{"songs": [...]}` wrapper —
  /// see this class's own doc comment for why both are handled
  /// defensively rather than assuming one.
  List<BaseTrack> _songsToTracks(dynamic decoded, String base) {
    final list = decoded is List
        ? decoded
        : (decoded is Map ? decoded['songs'] : null);
    if (list is! List) return const [];
    final tracks = <BaseTrack>[];
    // Per-entry defensive decoding — one malformed entry must not wipe
    // the rest of the search result, the same contract every other
    // network-backed plugin in this repo follows.
    for (final entry in list) {
      if (entry is! Map) continue;
      try {
        final track = _songToTrack(Map<String, dynamic>.from(entry), base);
        if (track != null) tracks.add(track);
      } catch (_) {
        continue;
      }
    }
    return tracks;
  }

  BaseTrack? _songToTrack(Map<String, dynamic> json, String base) {
    final id = json['id']?.toString();
    final title = json['title']?.toString();
    if (id == null || id.isEmpty || title == null || title.isEmpty) {
      return null;
    }

    // The enriched `SongWithAlbumAndArtist` shape embeds these objects;
    // the plain `Song` shape has only the *_id references, in which
    // case there's no honest name to show — falls back to the same
    // "Unknown Artist"/"Unknown Album" placeholder every sibling plugin
    // already uses for missing data, rather than showing a bare id.
    final artistField = json['artist'];
    final artistName =
        artistField is Map ? artistField['name']?.toString() : null;
    final albumField = json['album'];
    final albumName =
        albumField is Map ? albumField['name']?.toString() : null;

    final track = json['track'];
    final length = json['length'];
    final streamUrl = Uri.parse('$base/play/$id/false/0')
        .replace(queryParameters: {'api-token': _sessionToken ?? ''})
        .toString();

    return BaseTrack(
      id: 'koel:$id',
      title: title,
      artists: (artistName != null && artistName.isNotEmpty)
          ? [artistName]
          : const ['Unknown Artist'],
      album: (albumName != null && albumName.isNotEmpty)
          ? albumName
          : 'Unknown Album',
      duration: length is num ? length.round() : 0,
      trackNumber: track is int ? track : null,
      type: TrackType.koel,
      streamUrl: streamUrl,
    );
  }

  @override
  String get id => 'koel';

  @override
  String get name => 'Koel';

  @override
  String get description =>
      'Connect to a self-hosted Koel media server and stream '
      'directly from it.';

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
      locationID == 'plugin_settings' ? _KoelSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _KoelSettings extends StatefulWidget {
  final KoelPlugin plugin;

  const _KoelSettings({required this.plugin});

  @override
  State<_KoelSettings> createState() => _KoelSettingsState();
}

class _KoelSettingsState extends State<_KoelSettings> {
  late final TextEditingController _serverController;
  late final TextEditingController _emailController;
  late final TextEditingController _passwordController;
  final _searchController = TextEditingController();

  bool _testing = false;
  bool? _lastTestOk;
  bool _searching = false;
  List<BaseTrack> _results = const [];

  @override
  void initState() {
    super.initState();
    _serverController = TextEditingController(text: widget.plugin.serverUrl);
    _emailController = TextEditingController(text: widget.plugin.email);
    _passwordController = TextEditingController(text: widget.plugin.password);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    await widget.plugin.setServerUrl(_serverController.text);
    await widget.plugin.setEmail(_emailController.text);
    await widget.plugin.setPassword(_passwordController.text);
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
          'Connect to any Koel server you already run.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://koel.example.com',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _emailController,
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Password',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
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
