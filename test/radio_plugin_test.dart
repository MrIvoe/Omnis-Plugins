import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/radio_plugin.dart';

void main() {
  Map<String, dynamic> station({
    String uuid = 'abc-123',
    String name = 'Test FM',
    String? urlResolved = 'https://stream.example.com/test.mp3',
    String? url,
    String? country = 'Germany',
    String? tags = 'jazz, chill',
    String? codec = 'mp3',
    Object? bitrate = 128,
    String? favicon = 'https://example.com/favicon.ico',
  }) =>
      {
        'stationuuid': uuid,
        'name': name,
        'url_resolved': urlResolved,
        'url': url,
        'country': country,
        'tags': tags,
        'codec': codec,
        'bitrate': bitrate,
        'favicon': favicon,
      };

  group('searchStations', () {
    test('returns an empty list without calling the network for a blank '
        'query', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('[]', 200);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('   ');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('hits the real Radio Browser search endpoint with the trimmed '
        'query and a descriptive User-Agent', () async {
      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final client = MockClient((req) async {
        capturedUri = req.url;
        capturedHeaders = req.headers;
        return http.Response(jsonEncode([station()]), 200);
      });
      final plugin = RadioPlugin(client: client);

      await plugin.searchStations('  jazz fm  ');

      expect(capturedUri!.host, 'de1.api.radio-browser.info');
      expect(capturedUri!.path, '/json/stations/search');
      expect(capturedUri!.queryParameters['name'], 'jazz fm');
      expect(capturedHeaders!['User-Agent'], contains('Omnis'));
    });

    test('parses a real station response into a playable BaseTrack',
        () async {
      final client = MockClient((req) async {
        return http.Response(jsonEncode([station()]), 200);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, hasLength(1));
      final track = result.single;
      expect(track.id, 'radio:abc-123');
      expect(track.title, 'Test FM');
      expect(track.type, TrackType.radio);
      expect(track.streamUrl, 'https://stream.example.com/test.mp3');
      expect(track.duration, 0);
      expect(track.artists, ['Germany']);
      expect(track.genres, ['jazz', 'chill']);
      expect(track.codec, 'MP3');
      expect(track.bitrateKbps, 128);
      expect(track.coverArt, 'https://example.com/favicon.ico');
    });

    test('falls back to the raw url when url_resolved is blank', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([
            station(urlResolved: '', url: 'https://raw.example.com/s.mp3'),
          ]),
          200,
        );
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result.single.streamUrl, 'https://raw.example.com/s.mp3');
    });

    test('skips a station with no usable stream URL instead of returning a '
        'broken track', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([station(urlResolved: '', url: null), station()]),
          200,
        );
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, hasLength(1));
      expect(result.single.id, 'radio:abc-123');
    });

    test('one malformed entry in the response does not wipe the whole '
        'result — the other stations still come back', () async {
      final client = MockClient((req) async {
        return http.Response(
          jsonEncode([
            {'stationuuid': 123, 'name': null}, // garbage entry
            station(uuid: 'good-1', name: 'Good Station'),
          ]),
          200,
        );
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, hasLength(1));
      expect(result.single.id, 'radio:good-1');
    });

    test('degrades to an empty list on a non-200 response', () async {
      final client = MockClient((req) async {
        return http.Response('Internal Server Error', 500);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, isEmpty);
    });

    test('degrades to an empty list when the response body is not valid '
        'JSON', () async {
      final client = MockClient((req) async {
        return http.Response('not json', 200);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, isEmpty);
    });

    test('degrades to an empty list when the http call itself throws',
        () async {
      final client = MockClient((req) async {
        throw Exception('network unreachable');
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.searchStations('test');

      expect(result, isEmpty);
    });
  });

  group('topStations', () {
    test('hits the topvote endpoint with the requested limit', () async {
      Uri? capturedUri;
      final client = MockClient((req) async {
        capturedUri = req.url;
        return http.Response(jsonEncode([station()]), 200);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.topStations(limit: 15);

      expect(capturedUri!.path, '/json/stations/topvote/15');
      expect(result, hasLength(1));
    });
  });

  group('stationsByTag', () {
    test('returns an empty list without calling the network for a blank '
        'tag', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('[]', 200);
      });
      final plugin = RadioPlugin(client: client);

      final result = await plugin.stationsByTag('');

      expect(result, isEmpty);
      expect(called, isFalse);
    });

    test('hits the bytag endpoint with the tag as the final path segment '
        '(correctly encoded, not double-encoded)', () async {
      Uri? capturedUri;
      final client = MockClient((req) async {
        capturedUri = req.url;
        return http.Response(jsonEncode([station()]), 200);
      });
      final plugin = RadioPlugin(client: client);

      await plugin.stationsByTag('80s hits');

      expect(capturedUri!.pathSegments.take(2), ['json', 'stations']);
      expect(capturedUri!.pathSegments[2], 'bytag');
      // Uri.pathSegments decodes each segment — this fails if the tag
      // was ever run through Uri.encodeComponent before being handed to
      // Uri.https (which itself encodes the unencoded path it's given),
      // which would double-encode the space into a literal "%2520".
      expect(capturedUri!.pathSegments[3], '80s hits');
    });
  });

  test('plugin metadata is well-formed', () {
    final plugin = RadioPlugin();
    expect(plugin.id, 'radio');
    expect(plugin.usesNetwork, isTrue);
  });
}
