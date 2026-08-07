import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/plugin_storage.dart';

/// Shared Authorization Code + PKCE flow against Spotify's Web API,
/// composed into both `SpotifyImportPlugin` and `SpotifyPlaybackPlugin`
/// rather than shared via a cross-plugin interface — each plugin still
/// holds its **own** client id and tokens in its **own** [PluginStorage]
/// (the same "every plugin owns its own credentials" pattern
/// `MetadataEnrichmentPlugin`/`AudioAnalysisPlugin` already use), this
/// class only avoids duplicating the OAuth math itself.
///
/// PKCE (RFC 7636) is used instead of a classic client-secret flow
/// because this is a public client — a compiled app has nowhere safe to
/// keep a secret — which is exactly what Spotify's own docs recommend
/// for a native/mobile/desktop app.
///
/// ### Redirect URI — you must register these yourself
///
/// Spotify requires an *exact* redirect URI match, and mobile vs. desktop
/// need genuinely different mechanisms:
///  - **Desktop (Windows/Linux/macOS)**: a loopback HTTP redirect,
///    `http://127.0.0.1:$loopbackPort/callback` — `flutter_web_auth_2`
///    runs a tiny local server on that port to catch it. Register this
///    exact URI in your Spotify app's dashboard.
///  - **Android/iOS**: a custom URL scheme, `$mobileCallbackScheme://callback`
///    — the platform routes it back into the app via a manifest/plist
///    entry. Already added to `android/app/src/main/AndroidManifest.xml`
///    in this repo; there is no `ios/` platform folder yet (this project
///    hasn't run `flutter create --platforms=ios` here), so the
///    equivalent `CFBundleURLTypes` entry in `Info.plist` still needs
///    adding once that folder exists — see flutter_web_auth_2's README.
///
/// **Verification status**: this environment has no real Spotify Client
/// ID and cannot complete an interactive OAuth browser round-trip, so
/// this flow is implemented against Spotify's published API docs and
/// exercised here only at the unit-testable layer (PKCE generation,
/// token-response parsing, expiry/refresh math) — treat the interactive
/// `connect()` call as unverified until you've registered a real app and
/// run it once yourself.
class SpotifyAuth {
  static const loopbackPort = 8888;
  static const mobileCallbackScheme = 'omnis';
  static const _scopes = 'playlist-read-private playlist-read-collaborative '
      'user-library-read user-read-playback-state user-modify-playback-state '
      'user-read-currently-playing';

  static const _clientIdKey = 'spotify_client_id';
  static const _accessTokenKey = 'spotify_access_token';
  static const _refreshTokenKey = 'spotify_refresh_token';
  static const _expiresAtKey = 'spotify_expires_at_ms';

  final PluginStorage storage;
  final http.Client client;

  SpotifyAuth({required this.storage, http.Client? client})
      : client = client ?? http.Client();

  String get clientId => storage.getString(_clientIdKey) ?? '';

  Future<void> setClientId(String id) => storage.setString(_clientIdKey, id.trim());

  bool get isConnected => (storage.getString(_accessTokenKey) ?? '').isNotEmpty;

  Future<void> disconnect() async {
    await storage.remove(_accessTokenKey);
    await storage.remove(_refreshTokenKey);
    await storage.remove(_expiresAtKey);
  }

  String _redirectUri() =>
      Platform.isAndroid || Platform.isIOS
          ? '$mobileCallbackScheme://callback'
          : 'http://127.0.0.1:$loopbackPort/callback';

  String _callbackUrlScheme() =>
      Platform.isAndroid || Platform.isIOS ? mobileCallbackScheme : 'http';

  static String _randomVerifier([int length = 64]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)])
        .join();
  }

  static String _challengeFor(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Runs the full interactive OAuth dance: opens the system browser (or a
  /// loopback listener on desktop) for the user to approve, then exchanges
  /// the resulting code for an access + refresh token via PKCE — no
  /// client secret involved. Returns `true` on success. Requires
  /// [clientId] to already be set.
  Future<bool> connect() async {
    if (clientId.isEmpty) return false;
    final verifier = _randomVerifier();
    final challenge = _challengeFor(verifier);
    final redirectUri = _redirectUri();

    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': _scopes,
    });

    try {
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl.toString(),
        callbackUrlScheme: _callbackUrlScheme(),
        options: const FlutterWebAuth2Options(useWebview: false),
      );
      final code = Uri.parse(result).queryParameters['code'];
      if (code == null) return false;
      return _exchangeCode(code, verifier, redirectUri);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _exchangeCode(
      String code, String verifier, String redirectUri) async {
    try {
      final resp = await client.post(
        Uri.https('accounts.spotify.com', '/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': verifier,
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return false;
      return _storeTokenResponse(jsonDecode(resp.body));
    } catch (_) {
      return false;
    }
  }

  Future<bool> _storeTokenResponse(dynamic json) async {
    if (json is! Map) return false;
    final accessToken = json['access_token']?.toString();
    if (accessToken == null) return false;
    final refreshToken = json['refresh_token']?.toString();
    final expiresIn = json['expires_in'];
    final expiresInSeconds = expiresIn is num ? expiresIn.toInt() : 3600;

    await storage.setString(_accessTokenKey, accessToken);
    if (refreshToken != null) {
      await storage.setString(_refreshTokenKey, refreshToken);
    }
    await storage.setInt(
      _expiresAtKey,
      DateTime.now()
          .add(Duration(seconds: expiresInSeconds))
          .millisecondsSinceEpoch,
    );
    return true;
  }

  /// A currently-valid access token, refreshing first if the stored one
  /// has expired (or is within 60s of expiring). Returns `null` if not
  /// connected or a refresh fails — callers should treat that as "not
  /// authenticated" and prompt to reconnect.
  Future<String?> validAccessToken() async {
    final token = storage.getString(_accessTokenKey);
    if (token == null || token.isEmpty) return null;

    final expiresAtMs = storage.getInt(_expiresAtKey) ?? 0;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
    if (DateTime.now().isBefore(expiresAt.subtract(const Duration(seconds: 60)))) {
      return token;
    }

    final refreshToken = storage.getString(_refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) return null;

    try {
      final resp = await client.post(
        Uri.https('accounts.spotify.com', '/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final ok = await _storeTokenResponse(jsonDecode(resp.body));
      return ok ? storage.getString(_accessTokenKey) : null;
    } catch (_) {
      return null;
    }
  }
}
