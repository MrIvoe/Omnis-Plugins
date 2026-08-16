import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The [Cover Art Archive](https://coverartarchive.org) — a free,
/// keyless image host keyed by MusicBrainz release MBID, the same
/// canonical id `MetadataEnrichmentPlugin._queryMusicBrainz` already
/// resolves but previously discarded. Item 12/spec §47's "no artwork-
/// provider framework (Cover Art Archive/Fanart.tv lookup)" gap.
///
/// A separate, tiny module (not folded into `metadata_enrichment_plugin
/// .dart`) so the URL-building logic — the part worth unit-testing —
/// stays free of the HTTP client, `PluginStorage`, and every other
/// concern that file already carries.
class CoverArtArchive {
  const CoverArtArchive._();

  /// The direct image URL for [mbid]'s front cover. [size] is one of
  /// Cover Art Archive's own thumbnail sizes (`250`, `500`, `1200`) or
  /// `null` for the full-resolution original — matches the archive's
  /// own `/release/{mbid}/front[-{size}]` convention exactly.
  static Uri frontCoverUrl(String mbid, {int? size}) {
    final suffix = size == null ? 'front' : 'front-$size';
    return Uri.https('coverartarchive.org', '/release/$mbid/$suffix');
  }

  /// Fetches the front-cover image bytes for [mbid], or `null` if this
  /// release has no art archived (a 404 is common and expected, not an
  /// error), the request fails, or times out. Never throws.
  static Future<Uint8List?> fetchFrontCover(
    http.Client client,
    String mbid, {
    int? size,
  }) async {
    try {
      final resp = await client
          .get(frontCoverUrl(mbid, size: size))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      return resp.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}
