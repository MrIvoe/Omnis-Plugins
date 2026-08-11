import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/plugin_storage.dart';

/// Shared Authorization Code + PKCE flow against Google's OAuth 2.0
/// endpoints, used by `YouTubeMusicImportPlugin` for a user's own private
/// playlists/library (public playlist search only needs an API key, no
/// OAuth — see that plugin).
///
/// Same shape and same redirect-URI story as `SpotifyAuth` — see that
/// class's doc comment for the full desktop-vs-mobile explanation, PKCE
/// rationale, and verification status (unverified here too: no real
/// Google Cloud OAuth client exists in this environment to test against).
/// Duplicated rather than shared through a common base class: the two are
/// genuinely different services with different endpoints/scopes/response
/// shapes, and forcing them through one abstraction for ~150 lines of
/// near-identical-but-not-quite HTTP plumbing was judged not worth the
/// indirection — three similar files beat a premature shared one here.
///
/// Unlike Spotify, a Google "Desktop app" OAuth client commonly still
/// issues a client *secret* even for a PKCE flow (Google's own docs treat
/// it as optional-but-often-present for that client type), so this
/// accepts one — safe to leave blank if your Google Cloud OAuth client is
/// configured as a public client without one.
class YoutubeAuth {
  static const loopbackPort = 8889;
  static const mobileCallbackScheme = 'omnis';
  static const _scope = 'https://www.googleapis.com/auth/youtube.readonly';

  static const _clientIdKey = 'youtube_client_id';
  static const _clientSecretKey = 'youtube_client_secret';
  static const _accessTokenKey = 'youtube_access_token';
  static const _refreshTokenKey = 'youtube_refresh_token';
  static const _expiresAtKey = 'youtube_expires_at_ms';

  final PluginStorage storage;
  final http.Client client;

  YoutubeAuth({required this.storage, http.Client? client})
      : client = client ?? http.Client();

  /// See `SpotifyAuth._cachedAccessToken`'s doc comment — same reasoning,
  /// same pattern.
  String? _cachedAccessToken;

  String get clientId => storage.getString(_clientIdKey) ?? '';
  Future<void> setClientId(String id) => storage.setString(_clientIdKey, id.trim());

  String get clientSecret => storage.getString(_clientSecretKey) ?? '';
  Future<void> setClientSecret(String secret) =>
      storage.setString(_clientSecretKey, secret.trim());

  bool get isConnected => (_cachedAccessToken ?? '').isNotEmpty;

  /// See `SpotifyAuth.warmUp`'s doc comment — same reasoning, same
  /// pattern.
  Future<void> warmUp() async {
    _cachedAccessToken = await storage.getSecureString(_accessTokenKey);
  }

  Future<void> disconnect() async {
    await storage.removeSecure(_accessTokenKey);
    await storage.removeSecure(_refreshTokenKey);
    await storage.remove(_expiresAtKey);
    _cachedAccessToken = null;
  }

  String _redirectUri() => Platform.isAndroid || Platform.isIOS
      ? '$mobileCallbackScheme://callback'
      : 'http://127.0.0.1:$loopbackPort/callback';

  String _callbackUrlScheme() =>
      Platform.isAndroid || Platform.isIOS ? mobileCallbackScheme : 'http';

  static String _randomVerifier([int length = 64]) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rand = Random.secure();
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  static String _challengeFor(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  Future<bool> connect() async {
    if (clientId.isEmpty) return false;
    final verifier = _randomVerifier();
    final challenge = _challengeFor(verifier);
    final redirectUri = _redirectUri();

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': _scope,
      'access_type': 'offline',
      'prompt': 'consent',
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

  Future<bool> _exchangeCode(String code, String verifier, String redirectUri) async {
    try {
      final resp = await client.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
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

    await storage.setSecureString(_accessTokenKey, accessToken);
    _cachedAccessToken = accessToken;
    if (refreshToken != null) {
      await storage.setSecureString(_refreshTokenKey, refreshToken);
    }
    await storage.setInt(
      _expiresAtKey,
      DateTime.now().add(Duration(seconds: expiresInSeconds)).millisecondsSinceEpoch,
    );
    return true;
  }

  /// A currently-valid access token, refreshing first if needed. `null`
  /// when not connected or a refresh fails.
  Future<String?> validAccessToken() async {
    final token = await storage.getSecureString(_accessTokenKey);
    if (token == null || token.isEmpty) return null;

    final expiresAtMs = storage.getInt(_expiresAtKey) ?? 0;
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtMs);
    if (DateTime.now().isBefore(expiresAt.subtract(const Duration(seconds: 60)))) {
      return token;
    }

    final refreshToken = await storage.getSecureString(_refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) return null;

    try {
      final resp = await client.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
        },
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final ok = await _storeTokenResponse(jsonDecode(resp.body));
      return ok ? _cachedAccessToken : null;
    } catch (_) {
      return null;
    }
  }
}
