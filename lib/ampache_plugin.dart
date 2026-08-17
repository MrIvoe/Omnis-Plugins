import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Connects to a self-hosted Ampache media server via its JSON API.
///
/// Like `EmbyPlugin`/`JellyfinPlugin`/`OpenSubsonicPlugin`/`PlexPlugin`,
/// and unlike `SpotifyImportPlugin`'s metadata-only imports, this is a
/// **real, directly playable** streaming provider — each track's
/// [BaseTrack.streamUrl] is the pre-authenticated `url` Ampache's own
/// `songs` response already embeds per song (no hand-built stream URI
/// needed, unlike Emby/Jellyfin/OpenSubsonic).
///
/// A fourth genuinely different self-hosted auth shape from its three
/// siblings: a single endpoint (`server/json.server.php`, chosen by an
/// `action=` query parameter, not a per-resource REST path) issues a
/// session token via a `handshake` call — `auth = SHA256(timestamp +
/// SHA256(password))`, timestamp first — which is then passed back on
/// every subsequent call as `auth=<token>`. Unlike Emby/Jellyfin/
/// OpenSubsonic, Ampache's own API (versions 3 through 6) always
/// returns HTTP 200 even on failure — an expired/invalid session is
/// signaled *only* inside the JSON body, as `{"error": {"errorCode":
/// ..., ...}}`, so the retry-once-on-auth-failure check below reads the
/// decoded body, not the HTTP status code, unlike every sibling plugin
/// here.
///
/// The session token is kept in memory only, re-authenticated on demand
/// — never persisted, unlike the username/password themselves, which
/// are stored in this plugin's own `PluginStorage`.
///
/// **This has not been exercised against a real Ampache server in this
/// environment.** What's verified is protocol-level request/response
/// handling against a mocked HTTP client (see this class's tests),
/// modeled on Ampache's own published JSON API documentation
/// (ampache.org/api) — not a live server round-trip. The song object's
/// exact field set was not fully confirmed from documentation alone
/// (Ampache's own docs list both `title` and `name` for the same field);
/// this plugin reads either, defensively.
class AmpachePlugin extends MusicPlugin {
  static const _serverUrlKey = 'server_url';
  static const _usernameKey = 'username';
  static const _passwordKey = 'password';

  /// The API version this plugin negotiates against — a stable, known
  /// value rather than "latest," so a future server-side API change
  /// doesn't silently reshape responses this plugin wasn't written
  /// against.
  static const _apiVersion = '6.6.1';

  final http.Client _client;

  String? _sessionToken;

  String? lastError;

  AmpachePlugin({http.Client? client}) : _client = client ?? http.Client();

  String get serverUrl => storage.getString(_serverUrlKey) ?? '';
  Future<void> setServerUrl(String url) =>
      storage.setString(_serverUrlKey, url.trim());

  String get username => storage.getString(_usernameKey) ?? '';
  Future<void> setUsername(String value) =>
      storage.setString(_usernameKey, value.trim());

  String get password => storage.getString(_passwordKey) ?? '';
  Future<void> setPassword(String value) =>
      storage.setString(_passwordKey, value);

  bool get isConfigured =>
      serverUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  String? _normalizedBase() {
    final base = serverUrl.trim();
    if (base.isEmpty) return null;
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || !parsed.hasScheme) return null;
    return normalized;
  }

  /// `SHA256(timestamp + SHA256(password))` — Ampache's own documented
  /// password-handshake formula, timestamp concatenated *after* the
  /// already-hashed password, not before. A small pure function on its
  /// own since it's genuinely new math versus every sibling plugin here
  /// (Emby's is a plain header token, OpenSubsonic's is `md5(password +
  /// salt)`).
  static String computeHandshakeAuth(String password, int timestampSeconds) {
    final passwordHash = sha256.convert(utf8.encode(password)).toString();
    return sha256
        .convert(utf8.encode('$timestampSeconds$passwordHash'))
        .toString();
  }

  Uri? _endpoint(Map<String, String> params) {
    final base = _normalizedBase();
    if (base == null) return null;
    return Uri.parse('$base/server/json.server.php')
        .replace(queryParameters: params);
  }

  /// `null` when [decoded] isn't an Ampache-shaped error body at all;
  /// otherwise the human-readable message to surface via [lastError].
  /// Ampache's API (versions 3-6) always returns HTTP 200, even on
  /// failure — the *only* place a failure is signaled is this JSON
  /// shape, `{"error": {"errorCode": ..., "errorMessage": ...}}`, which
  /// is why every call site below checks the decoded body instead of
  /// `resp.statusCode`.
  static String? _errorMessage(dynamic decoded) {
    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error is! Map) return null;
    final message = error['errorMessage']?.toString();
    final code = error['errorCode']?.toString();
    if (message != null && message.isNotEmpty) return message;
    if (code != null && code.isNotEmpty) return 'Server error $code.';
    return 'Server reported an error.';
  }

  /// Authenticates via a `handshake` call and caches the session token
  /// in memory on success. Never throws — a failure sets [lastError]
  /// and returns `false`.
  Future<bool> _authenticate() async {
    if (!isConfigured) {
      lastError = 'Server URL, username, and password are all required.';
      return false;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = _endpoint({
      'action': 'handshake',
      'user': username,
      'timestamp': '$timestamp',
      'version': _apiVersion,
      'auth': computeHandshakeAuth(password, timestamp),
    });
    if (uri == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return false;
    }
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return false;
      }
      final decoded = jsonDecode(resp.body);
      final errorMessage = _errorMessage(decoded);
      if (errorMessage != null) {
        lastError = errorMessage;
        return false;
      }
      if (decoded is! Map) {
        lastError = 'Unrecognized response from server.';
        return false;
      }
      final token = decoded['auth']?.toString();
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
  /// handshake attempt, not just a reachability ping. Never throws.
  Future<bool> testConnection() => _authenticate();

  /// Searches the server's library for tracks matching [query] — real,
  /// directly playable results. Authenticates first if there's no
  /// cached session, and transparently re-authenticates exactly once on
  /// an Ampache-shaped error body (an expired/invalid session — see
  /// [_errorMessage]'s own doc for why this checks the body, not the
  /// HTTP status) before giving up. Returns an empty list (with
  /// [lastError] set on genuine failure) for a blank query, an
  /// unconfigured plugin, a network failure, or a server error — never
  /// throws.
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
    final uri = _endpoint({
      'action': 'songs',
      'filter': trimmed,
      'limit': '$limit',
      'auth': _sessionToken!,
    });
    if (uri == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return const [];
    }
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return const [];
      }
      final decoded = jsonDecode(resp.body);
      final errorMessage = _errorMessage(decoded);
      if (errorMessage != null) {
        if (!retried) {
          final ok = await _authenticate();
          if (!ok) return const [];
          return _search(query, limit: limit, retried: true);
        }
        lastError = errorMessage;
        return const [];
      }
      final songs = decoded is Map ? decoded['song'] : null;
      if (songs is! List) {
        lastError = null;
        return const [];
      }
      final tracks = <BaseTrack>[];
      // Per-entry defensive decoding — one malformed entry must not
      // wipe the rest of the search result, the same contract every
      // other network-backed plugin in this repo follows.
      for (final entry in songs) {
        if (entry is! Map) continue;
        try {
          final track = _songToTrack(Map<String, dynamic>.from(entry));
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

  /// Ampache's docs list a song's title field as both `title` and
  /// `name` — reads either defensively rather than trusting one.
  static String? _namedReferenceName(dynamic value) =>
      value is Map ? value['name']?.toString() : null;

  BaseTrack? _songToTrack(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final title = (json['title'] ?? json['name'])?.toString();
    if (id == null || id.isEmpty || title == null || title.isEmpty) {
      return null;
    }

    final artistName = _namedReferenceName(json['artist']);
    final albumName = _namedReferenceName(json['album']);
    final genreField = json['genre'];
    final genres = genreField is List
        ? genreField
            .map(_namedReferenceName)
            .whereType<String>()
            .where((g) => g.isNotEmpty)
            .toList()
        : const <String>[];
    final track = json['track'];
    final year = json['year'];
    final time = json['time'];
    final streamUrl = json['url']?.toString();
    final art = json['art']?.toString();

    return BaseTrack(
      id: 'ampache:$id',
      title: title,
      artists: (artistName != null && artistName.isNotEmpty)
          ? [artistName]
          : const ['Unknown Artist'],
      album: (albumName != null && albumName.isNotEmpty)
          ? albumName
          : 'Unknown Album',
      duration: time is int ? time : 0,
      trackNumber: track is int ? track : null,
      year: year is int ? year : null,
      genres: genres,
      type: TrackType.ampache,
      streamUrl: (streamUrl != null && streamUrl.isNotEmpty) ? streamUrl : null,
      coverArt: (art != null && art.isNotEmpty) ? art : null,
    );
  }

  @override
  String get id => 'ampache';

  @override
  String get name => 'Ampache';

  @override
  String get description =>
      'Connect to a self-hosted Ampache media server and stream '
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
      locationID == 'plugin_settings' ? _AmpacheSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _AmpacheSettings extends StatefulWidget {
  final AmpachePlugin plugin;

  const _AmpacheSettings({required this.plugin});

  @override
  State<_AmpacheSettings> createState() => _AmpacheSettingsState();
}

class _AmpacheSettingsState extends State<_AmpacheSettings> {
  late final TextEditingController _serverController;
  late final TextEditingController _usernameController;
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
    _usernameController = TextEditingController(text: widget.plugin.username);
    _passwordController = TextEditingController(text: widget.plugin.password);
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    await widget.plugin.setServerUrl(_serverController.text);
    await widget.plugin.setUsername(_usernameController.text);
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
          'Connect to any Ampache server you already run.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://ampache.example.com',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _usernameController,
          decoration: const InputDecoration(
            labelText: 'Username',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline),
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
