import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugins/spotify_auth.dart';

/// A device Spotify Connect can hand playback control to (a phone, a
/// desktop app, a speaker — anything signed into the same account with
/// Spotify open).
class SpotifyDevice {
  final String id;
  final String name;
  final bool isActive;

  const SpotifyDevice({required this.id, required this.name, required this.isActive});
}

/// Current Spotify Connect playback state, as reported by the account's
/// active device.
class SpotifyPlaybackState {
  final String trackName;
  final String artistName;
  final bool isPlaying;
  final Duration progress;
  final Duration duration;
  final String? deviceName;

  const SpotifyPlaybackState({
    required this.trackName,
    required this.artistName,
    required this.isPlaying,
    required this.progress,
    required this.duration,
    this.deviceName,
  });
}

/// Remote-controls playback on a real Spotify app via Spotify Connect —
/// **not** audio decoded through Omnis's own [AudioEngine].
///
/// This is the honest ceiling of third-party Spotify "playback": Spotify's
/// catalog is DRM-protected, so no third-party app can decode and play it
/// directly. What Spotify's Web API *does* expose is the same mechanism
/// Spotify's own official apps use to hand control to a speaker or another
/// device — play/pause/skip/seek/volume on whichever device is active,
/// with the actual audio still flowing out of the real Spotify app/device,
/// not this one. So this plugin's UI is its own small transport panel
/// (device picker + play/pause/skip), deliberately not merged into
/// Omnis's main queue/Now Playing screen the way local tracks are — that
/// would misrepresent what's actually happening.
///
/// Uses its own [SpotifyAuth] (own Client ID, own tokens) rather than
/// sharing `SpotifyImportPlugin`'s — see `SpotifyAuth`'s doc for why
/// credentials stay per-plugin. Requires a Spotify Premium account and
/// the Spotify app open somewhere on the account (Spotify Connect's own
/// requirement, not something this plugin can work around).
///
/// **Verification status**: unverified against a real account/device —
/// see `SpotifyAuth`'s doc comment.
class SpotifyPlaybackPlugin extends MusicPlugin {
  final http.Client _client;
  late final SpotifyAuth _auth = SpotifyAuth(storage: storage, client: _client);

  String? lastError;

  SpotifyPlaybackPlugin({http.Client? client}) : _client = client ?? http.Client();

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

  Future<List<SpotifyDevice>> fetchDevices() async {
    final headers = await _authHeader();
    if (headers == null) return const [];
    try {
      final resp = await _client
          .get(Uri.https('api.spotify.com', '/v1/me/player/devices'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Spotify returned ${resp.statusCode}.';
        return const [];
      }
      final json = jsonDecode(resp.body);
      final devices = json is Map ? json['devices'] : null;
      if (devices is! List) return const [];
      lastError = null;
      return devices.whereType<Map>().map((d) => SpotifyDevice(
            id: d['id']?.toString() ?? '',
            name: d['name']?.toString() ?? 'Unknown device',
            isActive: d['is_active'] == true,
          )).where((d) => d.id.isNotEmpty).toList();
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  Future<bool> transferPlayback(String deviceId) => _put('/v1/me/player',
      body: jsonEncode({'device_ids': [deviceId], 'play': true}));

  Future<SpotifyPlaybackState?> fetchState() async {
    final headers = await _authHeader();
    if (headers == null) return null;
    try {
      final resp = await _client
          .get(Uri.https('api.spotify.com', '/v1/me/player'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 204) return null; // nothing playing
      if (resp.statusCode != 200) {
        lastError = 'Spotify returned ${resp.statusCode}.';
        return null;
      }
      final json = jsonDecode(resp.body);
      if (json is! Map) return null;
      final item = json['item'];
      if (item is! Map) return null;
      final artists = item['artists'];
      final artistName = artists is List && artists.isNotEmpty && artists.first is Map
          ? (artists.first as Map)['name']?.toString() ?? ''
          : '';
      final device = json['device'];
      lastError = null;
      return SpotifyPlaybackState(
        trackName: item['name']?.toString() ?? '',
        artistName: artistName,
        isPlaying: json['is_playing'] == true,
        progress: Duration(milliseconds: (json['progress_ms'] as num?)?.toInt() ?? 0),
        duration: Duration(milliseconds: (item['duration_ms'] as num?)?.toInt() ?? 0),
        deviceName: device is Map ? device['name']?.toString() : null,
      );
    } catch (e) {
      lastError = 'Network error: $e';
      return null;
    }
  }

  Future<bool> play() => _put('/v1/me/player/play');
  Future<bool> pause() => _put('/v1/me/player/pause');
  Future<bool> next() => _post('/v1/me/player/next');
  Future<bool> previous() => _post('/v1/me/player/previous');
  Future<bool> seek(Duration position) =>
      _put('/v1/me/player/seek?position_ms=${position.inMilliseconds}');
  Future<bool> setVolume(int percent) =>
      _put('/v1/me/player/volume?volume_percent=${percent.clamp(0, 100)}');

  Future<bool> _put(String path, {String? body}) async {
    final headers = await _authHeader();
    if (headers == null) return false;
    try {
      final resp = await _client
          .put(Uri.https('api.spotify.com', path),
              headers: {...headers, 'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 10));
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      lastError = ok ? null : 'Spotify returned ${resp.statusCode}.';
      return ok;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  Future<bool> _post(String path) async {
    final headers = await _authHeader();
    if (headers == null) return false;
    try {
      final resp = await _client
          .post(Uri.https('api.spotify.com', path), headers: headers)
          .timeout(const Duration(seconds: 10));
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      lastError = ok ? null : 'Spotify returned ${resp.statusCode}.';
      return ok;
    } catch (e) {
      lastError = 'Network error: $e';
      return false;
    }
  }

  @override
  String get id => 'spotify_playback';

  @override
  String get name => 'Spotify Playback';

  @override
  String get description => isConnected
      ? 'Connected — remote-controls Spotify Connect playback.'
      : 'Connect a Spotify Premium account to remote-control playback on '
          'a Spotify Connect device.';

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
      locationID == 'plugin_settings' ? _SpotifyPlaybackSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _SpotifyPlaybackSettings extends StatefulWidget {
  final SpotifyPlaybackPlugin plugin;

  const _SpotifyPlaybackSettings({required this.plugin});

  @override
  State<_SpotifyPlaybackSettings> createState() => _SpotifyPlaybackSettingsState();
}

class _SpotifyPlaybackSettingsState extends State<_SpotifyPlaybackSettings> {
  late final TextEditingController _clientIdController;
  bool _connecting = false;
  bool _loading = false;
  List<SpotifyDevice> _devices = const [];
  SpotifyPlaybackState? _state;

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
    // The OAuth browser round-trip inside connect() is exactly the kind
    // of long-running await this page can easily get disposed out from
    // under — navigating away mid-flow must not crash on return.
    final ok = await widget.plugin.connect();
    if (!mounted) return;
    setState(() => _connecting = false);
    if (ok) await _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final devices = await widget.plugin.fetchDevices();
    final state = await widget.plugin.fetchState();
    if (mounted) {
      setState(() {
        _devices = devices;
        _state = state;
        _loading = false;
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
          'Remote-controls playback on the Spotify app running on one of '
          'your devices (Spotify Connect) — audio plays through that '
          'device, not through Omnis. Requires Spotify Premium and the '
          'Spotify app open somewhere on your account.',
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
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(_connecting ? 'Connecting…' : 'Connect'),
              )
            else ...[
              FilledButton.tonalIcon(
                onPressed: () async {
                  await plugin.disconnect();
                  if (mounted) {
                    setState(() {
                      _devices = const [];
                      _state = null;
                    });
                  }
                },
                icon: const Icon(Icons.link_off),
                label: const Text('Disconnect'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
          ],
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_state != null) ...[
          const SizedBox(height: 16),
          Text('Now playing', style: theme.textTheme.titleSmall),
          Text('${_state!.trackName} — ${_state!.artistName}'),
          if (_state!.deviceName != null)
            Text('on ${_state!.deviceName}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                onPressed: () => plugin.previous(),
              ),
              IconButton(
                icon: Icon(_state!.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () =>
                    _state!.isPlaying ? plugin.pause() : plugin.play(),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                onPressed: () => plugin.next(),
              ),
            ],
          ),
        ],
        if (_devices.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('Devices', style: theme.textTheme.titleSmall),
          for (final device in _devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(device.isActive ? Icons.speaker : Icons.speaker_group),
              title: Text(device.name),
              trailing: device.isActive
                  ? const Chip(label: Text('Active'))
                  : TextButton(
                      onPressed: () => plugin.transferPlayback(device.id),
                      child: const Text('Use this device'),
                    ),
            ),
        ],
      ],
    );
  }
}
