import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Connects to any OpenSubsonic-compatible media server — Navidrome,
/// Airsonic, the original Subsonic, and anything else implementing the
/// same REST API — via that public protocol.
///
/// Unlike `SpotifyImportPlugin` (metadata-only: Spotify's own catalog is
/// DRM-protected and can't be played by this app's `AudioEngine`), this
/// is a **real, directly playable** streaming provider: each track's
/// [BaseTrack.streamUrl] is the server's own `stream.view` endpoint —
/// genuine audio bytes, playable through the exact same code path
/// Radio/YouTube tracks already use (`AudioEngine.uriFor` plays any
/// track with a `streamUrl` set, no special-casing needed).
///
/// Since a single OpenSubsonic client already works against any
/// compliant server, this one plugin is also what makes a
/// Navidrome/Airsonic connection possible — those servers implement the
/// same protocol rather than a separate one of their own.
///
/// Auth uses OpenSubsonic's recommended token scheme (`t =
/// md5(password + salt)`, a fresh random `s` per request) instead of
/// sending the plaintext password on every call — but the password
/// itself is still stored locally in this plugin's own `PluginStorage`
/// (the same SharedPreferences-backed store `MetadataEnrichmentPlugin`
/// already uses for its API keys), since there is no secure-keystore
/// integration anywhere in this app yet.
///
/// This has not been exercised against a real Navidrome/Subsonic server
/// in this environment — what's verified is protocol-level request/
/// response handling against a mocked HTTP client (see this class's
/// tests), not a live server round-trip.
class OpenSubsonicPlugin extends MusicPlugin {
  static const _serverUrlKey = 'server_url';
  static const _usernameKey = 'username';
  static const _passwordKey = 'password';

  /// OpenSubsonic is additive-compatible with the Subsonic API this
  /// version string targets — every endpoint used here (`ping`,
  /// `search3`, `stream`, `getCoverArt`) has been stable since well
  /// before OpenSubsonic existed, so declaring a plain Subsonic version
  /// here (rather than an `openSubsonic` flag some but not all servers
  /// recognize) is what actually maximizes compatibility.
  static const _apiVersion = '1.16.1';
  static const _clientName = 'Omnis';

  final http.Client _client;
  final Random _random;

  String? lastError;

  OpenSubsonicPlugin({http.Client? client, Random? random})
      : _client = client ?? http.Client(),
        _random = random ?? Random.secure();

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

  static const _saltChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  String _randomSalt() =>
      List.generate(12, (_) => _saltChars[_random.nextInt(_saltChars.length)])
          .join();

  Map<String, String> _authParams() {
    final salt = _randomSalt();
    final token = md5.convert(utf8.encode('$password$salt')).toString();
    return {
      'u': username,
      't': token,
      's': salt,
      'v': _apiVersion,
      'c': _clientName,
      'f': 'json',
    };
  }

  /// Builds a full request URI for [endpoint] (e.g. `"ping.view"`),
  /// merging in fresh auth params plus [extra] query parameters. `null`
  /// when [serverUrl] is empty or not a real URI — every caller treats
  /// that the same as any other failure (sets [lastError], returns an
  /// empty/false result) rather than throwing.
  Uri? _buildUri(String endpoint, [Map<String, String> extra = const {}]) {
    final base = serverUrl.trim();
    if (base.isEmpty) return null;
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsedBase = Uri.tryParse(normalized);
    if (parsedBase == null || !parsedBase.hasScheme) return null;
    return Uri.parse('$normalized/rest/$endpoint')
        .replace(queryParameters: {..._authParams(), ...extra});
  }

  /// Verifies the configured server/credentials actually work by hitting
  /// `ping.view`. Never throws — a failure sets [lastError] and returns
  /// `false`.
  Future<bool> testConnection() async {
    if (!isConfigured) {
      lastError = 'Server URL, username, and password are all required.';
      return false;
    }
    final uri = _buildUri('ping.view');
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
      final error = _responseError(resp.body);
      if (error != null) {
        lastError = error;
        return false;
      }
      lastError = null;
      return true;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  /// Searches the server's library for tracks matching [query] — real,
  /// directly playable results. Returns an empty list (with [lastError]
  /// set on genuine failure, cleared on success) for a blank query, an
  /// unconfigured plugin, a network failure, a non-200 response, or a
  /// server-reported error — never throws.
  Future<List<BaseTrack>> search(String query, {int songCount = 25}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !isConfigured) return const [];
    final uri = _buildUri('search3.view', {
      'query': trimmed,
      'songCount': '$songCount',
      // Only songs — this plugin plays tracks directly, not a
      // browse-by-artist/album UI, so there's no use for the other two
      // result categories search3 can also return.
      'artistCount': '0',
      'albumCount': '0',
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
      final error = _responseError(resp.body);
      if (error != null) {
        lastError = error;
        return const [];
      }
      final decoded = jsonDecode(resp.body);
      final root = decoded is Map ? decoded['subsonic-response'] : null;
      final searchResult = root is Map ? root['searchResult3'] : null;
      final songs = searchResult is Map ? searchResult['song'] : null;
      if (songs is! List) {
        lastError = null;
        return const [];
      }
      final tracks = <BaseTrack>[];
      // Per-entry defensive decoding — one malformed song entry must not
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

  BaseTrack? _songToTrack(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final title = json['title']?.toString();
    if (id == null || id.isEmpty || title == null || title.isEmpty) {
      return null;
    }
    final streamUri = _buildUri('stream.view', {'id': id});
    if (streamUri == null) return null;

    final coverArtId = json['coverArt']?.toString();
    final coverUri = (coverArtId != null && coverArtId.isNotEmpty)
        ? _buildUri('getCoverArt.view', {'id': coverArtId})
        : null;

    final artist = json['artist']?.toString();
    final album = json['album']?.toString();
    final genre = json['genre']?.toString();
    final duration = json['duration'];
    final track = json['track'];
    final year = json['year'];

    return BaseTrack(
      id: 'subsonic:$id',
      title: title,
      artists: [
        (artist != null && artist.isNotEmpty) ? artist : 'Unknown Artist',
      ],
      album: (album != null && album.isNotEmpty) ? album : 'Unknown Album',
      duration: duration is int ? duration : 0,
      trackNumber: track is int ? track : null,
      year: year is int ? year : null,
      genres: (genre != null && genre.isNotEmpty) ? [genre] : const [],
      type: TrackType.subsonic,
      streamUrl: streamUri.toString(),
      coverArt: coverUri?.toString(),
    );
  }

  /// The server-reported error message from a `subsonic-response`
  /// envelope, or `null` when the response is missing, unparseable, or
  /// reports `status: "ok"`. Every OpenSubsonic response — success or
  /// failure — is wrapped the same way, so this one helper covers every
  /// endpoint this plugin calls.
  String? _responseError(String body) {
    try {
      final decoded = jsonDecode(body);
      final root = decoded is Map ? decoded['subsonic-response'] : null;
      if (root is! Map) return 'Unrecognized response from server.';
      if (root['status'] == 'ok') return null;
      final error = root['error'];
      final message = error is Map ? error['message']?.toString() : null;
      return message ?? 'Server rejected the request.';
    } catch (_) {
      return 'Unrecognized response from server.';
    }
  }

  @override
  String get id => 'opensubsonic';

  @override
  String get name => 'OpenSubsonic';

  @override
  String get description =>
      'Connect to a self-hosted OpenSubsonic-compatible server '
      '(Navidrome, Airsonic, Subsonic, and others) and stream directly '
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
  dynamic uiSlot(String locationID) => locationID == 'plugin_settings'
      ? _OpenSubsonicSettings(plugin: this)
      : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _OpenSubsonicSettings extends StatefulWidget {
  final OpenSubsonicPlugin plugin;

  const _OpenSubsonicSettings({required this.plugin});

  @override
  State<_OpenSubsonicSettings> createState() => _OpenSubsonicSettingsState();
}

class _OpenSubsonicSettingsState extends State<_OpenSubsonicSettings> {
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
          'Works with Navidrome, Airsonic, Subsonic, and any other '
          'server implementing the OpenSubsonic API.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://music.example.com',
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
                color: _lastTestOk!
                    ? Colors.green
                    : theme.colorScheme.error,
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
