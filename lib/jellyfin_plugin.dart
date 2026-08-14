import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// Connects to a self-hosted Jellyfin media server via its REST API.
///
/// Like `OpenSubsonicPlugin`, and unlike `SpotifyImportPlugin`'s
/// metadata-only imports, this is a **real, directly playable**
/// streaming provider — each track's [BaseTrack.streamUrl] is Jellyfin's
/// own real audio endpoint, playable through the exact path Radio/
/// YouTube/OpenSubsonic tracks already use (`AudioEngine.uriFor` plays
/// any track with a `streamUrl` set).
///
/// A separate plugin from `OpenSubsonicPlugin` rather than a shared
/// client, because Jellyfin is its own protocol: session-token auth via
/// `/Users/AuthenticateByName` (not OpenSubsonic's per-request MD5
/// token), and different endpoint/field shapes entirely (`/Items` search
/// with `Artists`/`RunTimeTicks`/`IndexNumber`, not `search3.view` with
/// `artist`/`duration`/`track`).
///
/// The session access token is kept in memory only, re-authenticated on
/// demand (including transparently on a `401` mid-request) — never
/// persisted, unlike the username/password themselves, which are stored
/// in this plugin's own `PluginStorage` (the same SharedPreferences-
/// backed store `MetadataEnrichmentPlugin` already uses for its API
/// keys; there is no secure-keystore integration anywhere in this app
/// yet).
///
/// This has not been exercised against a real Jellyfin server in this
/// environment — what's verified is protocol-level request/response
/// handling against a mocked HTTP client (see this class's tests), not a
/// live server round-trip.
class JellyfinPlugin extends MusicPlugin {
  static const _serverUrlKey = 'server_url';
  static const _usernameKey = 'username';
  static const _passwordKey = 'password';
  static const _hexChars = '0123456789abcdef';

  final http.Client _client;
  final Random _random;

  /// A per-install id Jellyfin's auth header wants, to label this
  /// "device" in its admin UI — generated once per plugin instance
  /// rather than persisted, since it needs no stability across app
  /// restarts for correctness (only cosmetic effect on how many
  /// "devices" a long-lived install shows there over time).
  late final String _deviceId =
      List.generate(32, (_) => _hexChars[_random.nextInt(16)]).join();

  String? _accessToken;
  String? _userId;

  String? lastError;

  JellyfinPlugin({http.Client? client, Random? random})
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

  String? _normalizedBase() {
    final base = serverUrl.trim();
    if (base.isEmpty) return null;
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final parsed = Uri.tryParse(normalized);
    if (parsed == null || !parsed.hasScheme) return null;
    return normalized;
  }

  Map<String, String> _authHeader({String? token}) => {
        'Content-Type': 'application/json',
        'X-Emby-Authorization': 'MediaBrowser Client="Omnis", '
            'Device="Omnis", DeviceId="$_deviceId", Version="1.0.0"'
            '${token != null ? ', Token="$token"' : ''}',
      };

  /// Authenticates against `/Users/AuthenticateByName` and caches the
  /// session token/user id in memory on success. Never throws — a
  /// failure sets [lastError] and returns `false`.
  Future<bool> _authenticate() async {
    if (!isConfigured) {
      lastError = 'Server URL, username, and password are all required.';
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
            Uri.parse('$base/Users/AuthenticateByName'),
            headers: _authHeader(),
            body: jsonEncode({'Username': username, 'Pw': password}),
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
      final token = decoded['AccessToken']?.toString();
      final user = decoded['User'];
      final userId = user is Map ? user['Id']?.toString() : null;
      if (token == null ||
          token.isEmpty ||
          userId == null ||
          userId.isEmpty) {
        lastError = 'Server did not return a valid session.';
        return false;
      }
      _accessToken = token;
      _userId = userId;
      lastError = null;
      return true;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  /// Verifies the configured server/credentials actually work — a real
  /// authentication attempt, not just a reachability ping. Never throws.
  Future<bool> testConnection() => _authenticate();

  /// Searches the server's library for tracks matching [query] — real,
  /// directly playable results. Authenticates first if there's no
  /// cached session, and transparently re-authenticates exactly once on
  /// a `401` (an expired/invalid token) before giving up. Returns an
  /// empty list (with [lastError] set on genuine failure) for a blank
  /// query, an unconfigured plugin, a network failure, or a server
  /// error — never throws.
  Future<List<BaseTrack>> search(String query, {int limit = 25}) =>
      _search(query, limit: limit, retried: false);

  Future<List<BaseTrack>> _search(
    String query, {
    required int limit,
    required bool retried,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    if (_accessToken == null || _userId == null) {
      final ok = await _authenticate();
      if (!ok) return const [];
    }
    final base = _normalizedBase();
    if (base == null) {
      lastError = 'That doesn\'t look like a valid server URL.';
      return const [];
    }
    final uri = Uri.parse('$base/Items').replace(queryParameters: {
      'searchTerm': trimmed,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'Limit': '$limit',
      'UserId': _userId!,
    });
    try {
      final resp = await _client
          .get(uri, headers: _authHeader(token: _accessToken))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401 && !retried) {
        final ok = await _authenticate();
        if (!ok) return const [];
        return _search(query, limit: limit, retried: true);
      }
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return const [];
      }
      final decoded = jsonDecode(resp.body);
      final items = decoded is Map ? decoded['Items'] : null;
      if (items is! List) {
        lastError = null;
        return const [];
      }
      final tracks = <BaseTrack>[];
      // Per-entry defensive decoding — one malformed item must not wipe
      // the rest of the search result, the same contract every other
      // network-backed plugin in this repo follows.
      for (final entry in items) {
        if (entry is! Map) continue;
        try {
          final track = _itemToTrack(Map<String, dynamic>.from(entry), base);
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

  BaseTrack? _itemToTrack(Map<String, dynamic> json, String base) {
    final id = json['Id']?.toString();
    final name = json['Name']?.toString();
    if (id == null || id.isEmpty || name == null || name.isEmpty) {
      return null;
    }

    final streamUrl = Uri.parse('$base/Audio/$id/stream')
        .replace(queryParameters: {
      'static': 'true',
      'api_key': _accessToken ?? '',
    }).toString();

    final artistsField = json['Artists'];
    final artists = artistsField is List
        ? artistsField.whereType<String>().where((a) => a.isNotEmpty).toList()
        : const <String>[];
    final album = json['Album']?.toString();
    final genresField = json['Genres'];
    final genres =
        genresField is List ? genresField.whereType<String>().toList() : const <String>[];
    final runTimeTicks = json['RunTimeTicks'];
    // RunTimeTicks is in 100-nanosecond units — 10,000,000 per second.
    final duration = runTimeTicks is int ? runTimeTicks ~/ 10000000 : 0;
    final indexNumber = json['IndexNumber'];
    final year = json['ProductionYear'];
    final imageTags = json['ImageTags'];
    final hasPrimaryImage = imageTags is Map && imageTags.containsKey('Primary');
    final coverArt = hasPrimaryImage
        ? Uri.parse('$base/Items/$id/Images/Primary').replace(
            queryParameters: {'api_key': _accessToken ?? ''},
          ).toString()
        : null;

    return BaseTrack(
      id: 'jellyfin:$id',
      title: name,
      artists: artists.isNotEmpty ? artists : const ['Unknown Artist'],
      album: (album != null && album.isNotEmpty) ? album : 'Unknown Album',
      duration: duration,
      trackNumber: indexNumber is int ? indexNumber : null,
      year: year is int ? year : null,
      genres: genres,
      type: TrackType.jellyfin,
      streamUrl: streamUrl,
      coverArt: coverArt,
    );
  }

  @override
  String get id => 'jellyfin';

  @override
  String get name => 'Jellyfin';

  @override
  String get description =>
      'Connect to a self-hosted Jellyfin media server and stream '
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
      locationID == 'plugin_settings' ? _JellyfinSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _JellyfinSettings extends StatefulWidget {
  final JellyfinPlugin plugin;

  const _JellyfinSettings({required this.plugin});

  @override
  State<_JellyfinSettings> createState() => _JellyfinSettingsState();
}

class _JellyfinSettingsState extends State<_JellyfinSettings> {
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
          'Connect to any Jellyfin server you already run.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://jellyfin.example.com',
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
