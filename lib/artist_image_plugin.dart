import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Looks up a real artist photo via Deezer's public search API
/// (`api.deezer.com/search/artist`) — free, unauthenticated, no account or
/// key needed, the same "no credential required" tier
/// `MetadataEnrichmentPlugin`'s MusicBrainz lookup sits at. Deezer is used
/// here purely as an image index (a `picture_medium` URL per artist), not
/// for playback or any Deezer-catalog feature.
///
/// A found URL is cached in memory for the life of the plugin instance, so
/// scrolling a long Artists list doesn't re-query the same name on every
/// rebuild — the same reasoning `ArtworkProvider` (Omnis's local track-art
/// cache) already applies, just for a network lookup instead of a file
/// read. Concurrent lookups for the same artist share one in-flight
/// request rather than firing duplicates, via caching the `Future` itself.
class ArtistImagePlugin extends MusicPlugin implements IArtistImageProvider {
  final http.Client _client;
  final Map<String, Future<String?>> _cache = {};

  ArtistImagePlugin({http.Client? client}) : _client = client ?? http.Client();

  @override
  bool get isAvailable => true;

  @override
  Future<String?> imageUrlFor(String artistName) {
    if (artistName.isEmpty || artistName == 'Unknown Artist') {
      return Future.value(null);
    }
    return _cache.putIfAbsent(artistName, () => _lookup(artistName));
  }

  Future<String?> _lookup(String artistName) async {
    final uri = Uri.https('api.deezer.com', '/search/artist', {
      'q': artistName,
      'limit': '1',
    });
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = json['data'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;
      final first = results.first as Map<String, dynamic>;
      final url = first['picture_medium'] as String?;
      return (url != null && url.isNotEmpty) ? url : null;
    } catch (e) {
      return null;
    }
  }

  /// Drop a cached lookup — e.g. if a first attempt failed while offline
  /// and the caller wants a fresh try later, rather than the negative
  /// result sticking for the rest of the session.
  void invalidate(String artistName) => _cache.remove(artistName);

  @override
  String get id => 'artist_image';

  @override
  String get name => 'Artist Photos';

  @override
  String get description =>
      'Shows a real artist photo (via Deezer\'s public search API) next '
      'to each artist in the Library.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {
    context?.services.register(IArtistImageProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> enable() async {
    context?.services.register(IArtistImageProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IArtistImageProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IArtistImageProvider, this);
    _client.close();
  }
}
