import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugins/cover_art_archive.dart';

void main() {
  group('frontCoverUrl', () {
    test('builds the full-resolution URL when no size is given', () {
      final uri = CoverArtArchive.frontCoverUrl('abc-123');

      expect(uri.toString(), 'https://coverartarchive.org/release/abc-123/front');
    });

    test('builds a thumbnail URL when a size is given', () {
      final uri = CoverArtArchive.frontCoverUrl('abc-123', size: 500);

      expect(uri.toString(),
          'https://coverartarchive.org/release/abc-123/front-500');
    });

    test('the mbid is embedded verbatim, not URL-mangled for a normal '
        'UUID-shaped id', () {
      const mbid = '11111111-2222-3333-4444-555555555555';
      final uri = CoverArtArchive.frontCoverUrl(mbid);

      expect(uri.path, '/release/$mbid/front');
    });
  });

  group('fetchFrontCover', () {
    test('returns the image bytes on a 200 response', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final client = MockClient((req) async {
        expect(req.url.host, 'coverartarchive.org');
        return http.Response.bytes(bytes, 200);
      });

      final result =
          await CoverArtArchive.fetchFrontCover(client, 'abc-123');

      expect(result, bytes);
    });

    test('returns null on a 404 — no archived art for this release, an '
        'expected outcome, not an error', () async {
      final client = MockClient((req) async => http.Response('', 404));

      final result =
          await CoverArtArchive.fetchFrontCover(client, 'abc-123');

      expect(result, isNull);
    });

    test('returns null on any other non-200 response', () async {
      final client = MockClient((req) async => http.Response('', 500));

      final result =
          await CoverArtArchive.fetchFrontCover(client, 'abc-123');

      expect(result, isNull);
    });

    test('returns null rather than throwing when the client itself '
        'throws', () async {
      final client = MockClient((req) async => throw Exception('offline'));

      final result =
          await CoverArtArchive.fetchFrontCover(client, 'abc-123');

      expect(result, isNull);
    });

    test('requests the size-specific URL when size is passed through',
        () async {
      Uri? requested;
      final client = MockClient((req) async {
        requested = req.url;
        return http.Response.bytes([1], 200);
      });

      await CoverArtArchive.fetchFrontCover(client, 'abc-123', size: 250);

      expect(requested?.path, '/release/abc-123/front-250');
    });
  });
}
