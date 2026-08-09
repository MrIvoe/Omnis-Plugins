import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/audio_analysis_result.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// A bundled plugin that sends a local track's audio to a self-hosted
/// Essentia analysis service and returns real BPM/key/mood data.
///
/// ### Why a service instead of running Essentia on-device
///
/// Essentia is a C++ library. Its own official tutorials only support
/// running via Python on Linux (a prebuilt `essentia-tensorflow` pip
/// wheel) or macOS (source build) — there is no supported path to run it
/// inside a Windows desktop app or a mobile (Android/iOS) Flutter binary
/// at all, official or otherwise. Building one from scratch means
/// compiling Essentia and its TensorFlow dependency from source for every
/// target platform (Android NDK, Windows MSVC, iOS/macOS toolchains) and
/// binding the result via `dart:ffi` — a native-build project measured in
/// days, not something addable in a source-editing session, and not
/// something that can be verified without the resulting binary actually
/// running on each target device.
///
/// So instead: this plugin is a thin, fully real HTTP client — the same
/// shape as [MetadataEnrichmentPlugin] — that talks to a small companion
/// service (`tools/essentia_service/`) running real, unmodified Essentia.
/// You deploy that service yourself (Docker, a Linux box, a NAS — see its
/// README) and point this plugin's own settings (tap it in the Plugins
/// list) at it; it never assumes or ships a default endpoint, and does
/// nothing at all while the setting is blank.
///
/// **Verification status**: this client is unit-tested against mocked
/// HTTP responses (`test/audio_analysis_plugin_test.dart`). The companion
/// service has separately been built, run via Docker, and verified
/// end-to-end against a real request/response round trip — see its own
/// README for what that confirmed. Still worth a sanity check on your own
/// library before trusting it broadly (a single synthetic test tone
/// doesn't cover real music's variety), but this is a working pipeline,
/// not just a well-researched one.
class AudioAnalysisPlugin extends MusicPlugin implements IAudioAnalysisProvider {
  static const _serviceUrlStorageKey = 'essentia_service_url';

  final http.Client _client;

  AudioAnalysisPlugin({http.Client? client}) : _client = client ?? http.Client();

  /// Base URL of a self-hosted Essentia analysis service (see
  /// `tools/essentia_service/`), e.g. `http://192.168.1.20:8686`. Blank by
  /// default — no analysis service ships with the app, and this plugin
  /// skips analysis entirely while blank rather than guessing at a
  /// default.
  String get serviceUrl => storage.getString(_serviceUrlStorageKey) ?? '';

  Future<void> setServiceUrl(String value) =>
      storage.setString(_serviceUrlStorageKey, value.trim());

  bool get isConfigured => serviceUrl.isNotEmpty;

  /// [IAudioAnalysisProvider.isAvailable] — unlike
  /// `MetadataEnrichmentPlugin`, this plugin genuinely is inert until a
  /// service URL is configured, so `isAvailable` and [isConfigured] mean
  /// the same thing here.
  @override
  bool get isAvailable => isConfigured;

  @override
  Future<AudioAnalysisResult> analyze(BaseTrack track) => analyzeTrack(track);

  /// Analyze [track]'s audio. Only works for a track with a real local
  /// file (`track.localPath`) — there's no path yet for streaming tracks,
  /// which would need the service to fetch the URL itself. Returns an
  /// empty result (never throws) when the service isn't configured,
  /// unreachable, or returns something unparseable.
  Future<AudioAnalysisResult> analyzeTrack(BaseTrack track) async {
    final baseUrl = serviceUrl;
    final path = track.localPath;
    if (baseUrl.isEmpty || path == null || path.isEmpty) {
      return const AudioAnalysisResult();
    }
    if (!await File(path).exists()) {
      return const AudioAnalysisResult();
    }

    try {
      final uri = Uri.parse('${_trimTrailingSlash(baseUrl)}/analyze');
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('audio', path));
      final streamed = await _client.send(request).timeout(
            const Duration(seconds: 60),
          );
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode != 200) {
        return const AudioAnalysisResult();
      }
      final json = jsonDecode(response.body);
      if (json is! Map) return const AudioAnalysisResult();

      final bpm = json['bpm'];
      final genresRaw = json['genres'];
      return AudioAnalysisResult(
        bpm: bpm is num ? bpm.toDouble() : null,
        key: json['key']?.toString(),
        scale: json['scale']?.toString(),
        mood: json['mood']?.toString(),
        genres: genresRaw is List
            ? genresRaw.map((g) => g.toString()).toList()
            : const [],
      );
    } catch (e) {
      return const AudioAnalysisResult();
    }
  }

  static String _trimTrailingSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  @override
  String get id => 'audio_analysis';

  @override
  String get name => 'Audio Analysis (Essentia)';

  @override
  String get description => isConfigured
      ? 'Real BPM/key/mood analysis via your self-hosted Essentia service.'
      : 'Set an Essentia service URL in this plugin\'s settings to enable '
          'BPM/key/mood analysis.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {
    context?.services.register(IAudioAnalysisProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _AudioAnalysisSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    context?.services.register(IAudioAnalysisProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IAudioAnalysisProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IAudioAnalysisProvider, this);
    _client.close();
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. A single field is enough — unlike the metadata sources, there's
/// only one endpoint, and it has no separate auth token (deploy-your-own
/// means the service itself decides whether it wants one).
class _AudioAnalysisSettings extends StatefulWidget {
  final AudioAnalysisPlugin plugin;

  const _AudioAnalysisSettings({required this.plugin});

  @override
  State<_AudioAnalysisSettings> createState() =>
      _AudioAnalysisSettingsState();
}

class _AudioAnalysisSettingsState extends State<_AudioAnalysisSettings> {
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.plugin.serviceUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _url,
      decoration: const InputDecoration(
        labelText: 'Essentia service URL',
        hintText: 'e.g. http://192.168.1.20:8686',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.podcasts),
      ),
      onChanged: widget.plugin.setServiceUrl,
    );
  }
}
