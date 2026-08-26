import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/custom_radio_station_store.dart';

/// A bundled Internet Radio plugin: search and browse live streaming
/// stations via the [Radio Browser](https://www.radio-browser.info)
/// community directory — a free, keyless public API (tens of thousands
/// of real Icecast/Shoutcast stations), unlike `MetadataEnrichmentPlugin`
/// which needs user-supplied API keys for most of its sources.
///
/// Every station comes back as an ordinary [BaseTrack]
/// (`type: TrackType.radio`, `streamUrl` set to the station's real
/// stream) — playback needs no special-casing anywhere: `AudioEngine`
/// already plays any track with a `streamUrl` set (see
/// `AudioEngine.uriFor`), the same path `youtube`/`spotify` tracks use.
/// `duration` is always `0` (a live stream has none).
///
/// Talks to a single fixed mirror (`de1.api.radio-browser.info`) rather
/// than resolving the full server list via the DNS round-robin the
/// Radio Browser docs recommend for production-scale traffic — that
/// round-robin exists to spread load across the project's volunteer
/// mirrors, which a single music app's search traffic doesn't come
/// close to needing. If that one mirror is ever retired, this needs a
/// new hostname, not a redesign.
///
/// Also implements [ICustomRadioStationProvider] (added for a Tier 2
/// task 5 fix round) — the read side of `CustomRadioStationStore`'s
/// user-added stations, needed by two Omnis-app call sites
/// (`MainCore._checkPlaybackSchedules`, `PlaybackSchedulePage`) for
/// scheduled playback. `RadioPlugin`, not `OnlinePlugin`, owns this
/// registration: custom stations are only ever addable/manageable
/// through `RadioBody`, which itself only renders once [IRadioProvider]
/// (this same plugin) is registered — see `RadioBody.build`'s own "The
/// Internet Radio plugin is disabled in Settings" fallback — so gating
/// scheduled custom-station playback behind this plugin's own
/// enabled/disabled state matches the existing "no Radio plugin, no way
/// to touch custom stations at all" UI behavior exactly, rather than
/// tying it to `OnlinePlugin`'s unrelated tab-shell lifecycle.
class RadioPlugin extends MusicPlugin
    implements IRadioProvider, ICustomRadioStationProvider {
  static const _host = 'de1.api.radio-browser.info';
  static const _userAgent = 'Omnis/0.1.0 (github.com/MrIvoe/Omnis)';

  final http.Client _client;

  RadioPlugin({http.Client? client}) : _client = client ?? http.Client();

  /// Stations matching [query] by name, ranked by community vote count.
  /// Returns an empty list (never throws) for a blank query, a network
  /// failure, a non-200 response, or an unparseable body — the same
  /// fail-soft contract every network-backed plugin in this repo follows.
  @override
  Future<List<BaseTrack>> searchStations(String query, {int limit = 30}) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value(const []);
    final uri = Uri.https(_host, '/json/stations/search', {
      'name': trimmed,
      'limit': '$limit',
      'hidebroken': 'true',
      'order': 'votes',
      'reverse': 'true',
    });
    return _fetchStations(uri);
  }

  /// The [limit] most-voted stations overall — a reasonable browsing
  /// default before the user has searched for anything.
  @override
  Future<List<BaseTrack>> topStations({int limit = 30}) {
    final uri = Uri.https(_host, '/json/stations/topvote/$limit', {
      'hidebroken': 'true',
    });
    return _fetchStations(uri);
  }

  /// Stations tagged with [tag] (e.g. "jazz", "80s", "news"), ranked by
  /// vote count.
  Future<List<BaseTrack>> stationsByTag(String tag, {int limit = 30}) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) return Future.value(const []);
    final uri = Uri.https(
      // Uri.https's path argument is *unencoded* — it does its own
      // percent-encoding of the path segments, so pre-encoding [trimmed]
      // here would double-encode it (a space would become "%2520").
      _host,
      '/json/stations/bytag/$trimmed',
      {'limit': '$limit', 'hidebroken': 'true', 'order': 'votes', 'reverse': 'true'},
    );
    return _fetchStations(uri);
  }

  Future<List<BaseTrack>> _fetchStations(Uri uri) async {
    try {
      final resp = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final decoded = jsonDecode(resp.body);
      if (decoded is! List) return const [];
      final stations = <BaseTrack>[];
      // Per-entry defensive decoding — the same "one bad entry must
      // never wipe the whole result" contract every store/scanner in
      // this codebase follows, not just a bulk .map() that would let one
      // malformed station entry take down the entire search result.
      for (final entry in decoded) {
        if (entry is! Map) continue;
        try {
          final track = _stationToTrack(Map<String, dynamic>.from(entry));
          if (track != null) stations.add(track);
        } catch (_) {
          continue;
        }
      }
      return stations;
    } catch (_) {
      return const [];
    }
  }

  BaseTrack? _stationToTrack(Map<String, dynamic> json) {
    final uuid = (json['stationuuid'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    final resolvedUrl = (json['url_resolved'] as String?)?.trim();
    final rawUrl = (json['url'] as String?)?.trim();
    final streamUrl = (resolvedUrl != null && resolvedUrl.isNotEmpty)
        ? resolvedUrl
        : rawUrl;
    if (uuid == null ||
        uuid.isEmpty ||
        name == null ||
        name.isEmpty ||
        streamUrl == null ||
        streamUrl.isEmpty) {
      return null;
    }
    final country = (json['country'] as String?)?.trim();
    final tagsRaw = (json['tags'] as String?)?.trim();
    final genres = (tagsRaw != null && tagsRaw.isNotEmpty)
        ? tagsRaw
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList()
        : const <String>[];
    final codec = (json['codec'] as String?)?.trim();
    final bitrate = json['bitrate'];
    final favicon = (json['favicon'] as String?)?.trim();

    return BaseTrack(
      id: 'radio:$uuid',
      title: name,
      artists: [
        (country != null && country.isNotEmpty) ? country : 'Internet Radio',
      ],
      album: 'Internet Radio',
      duration: 0,
      genres: genres,
      type: TrackType.radio,
      streamUrl: streamUrl,
      coverArt: (favicon != null && favicon.isNotEmpty) ? favicon : null,
      codec: (codec != null && codec.isNotEmpty) ? codec.toUpperCase() : null,
      bitrateKbps: (bitrate is int && bitrate > 0) ? bitrate : null,
    );
  }

  /// See [ICustomRadioStationProvider.customStationSummaries].
  @override
  Future<List<(String id, String name)>> customStationSummaries() async {
    final stations = await CustomRadioStationStore.instance.load();
    return [for (final s in stations) (s.id, s.name)];
  }

  /// See [ICustomRadioStationProvider.trackForCustomStation].
  @override
  Future<BaseTrack?> trackForCustomStation(String stationId) async {
    final stations = await CustomRadioStationStore.instance.load();
    for (final s in stations) {
      if (s.id == stationId) return s.toTrack();
    }
    return null;
  }

  @override
  String get id => 'radio';

  @override
  String get name => 'Internet Radio';

  @override
  String get description =>
      'Search and play live internet radio stations from the free Radio '
      'Browser directory.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {
    context?.services.register(IRadioProvider, this);
    context?.services.register(ICustomRadioStationProvider, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(IRadioProvider, this);
    context?.services.register(ICustomRadioStationProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IRadioProvider, this);
    context?.services.unregister(ICustomRadioStationProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> dispose() async {
    context?.services.unregister(IRadioProvider, this);
    context?.services.unregister(ICustomRadioStationProvider, this);
  }
}
