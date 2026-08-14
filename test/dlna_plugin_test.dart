import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/dlna_plugin.dart';
import 'package:xml/xml.dart';

/// A fake [SsdpTransport] returning fixed response strings — this is
/// what makes [DlnaPlugin.discoverServers] unit-testable at all without
/// a real UDP socket or a real DLNA server on the test network.
class _FakeSsdpTransport implements SsdpTransport {
  final List<String> responses;
  Duration? capturedTimeout;

  _FakeSsdpTransport(this.responses);

  @override
  Future<List<String>> discover({Duration timeout = const Duration(seconds: 3)}) async {
    capturedTimeout = timeout;
    return responses;
  }
}

String ssdpResponse(String location) => 'HTTP/1.1 200 OK\r\n'
    'CACHE-CONTROL: max-age=1800\r\n'
    'LOCATION: $location\r\n'
    'SERVER: TestServer/1.0 UPnP/1.0\r\n'
    'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
    'USN: uuid:test-device::urn:schemas-upnp-org:device:MediaServer:1\r\n'
    '\r\n';

String deviceDescription({
  String friendlyName = 'Test Media Server',
  String controlUrl = '/ContentDirectory/control',
  String? urlBase,
}) =>
    '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>$friendlyName</friendlyName>
    ${urlBase != null ? '<URLBase>$urlBase</URLBase>' : ''}
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId>
        <controlURL>$controlUrl</controlURL>
        <eventSubURL>/ContentDirectory/event</eventSubURL>
        <SCPDURL>/ContentDirectory/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/ConnectionManager/control</controlURL>
        <eventSubURL>/ConnectionManager/event</eventSubURL>
        <SCPDURL>/ConnectionManager/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
''';

String didlLite({
  List<String> containers = const [],
  List<String> items = const [],
}) =>
    '<DIDL-Lite '
    'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
    '${containers.join()}${items.join()}'
    '</DIDL-Lite>';

String didlContainer({String id = '1', String title = 'Music'}) =>
    '<container id="$id" parentID="0" restricted="1">'
    '<dc:title>$title</dc:title>'
    '<upnp:class>object.container.storageFolder</upnp:class>'
    '</container>';

String didlItem({
  String id = 't1',
  String title = 'Song One',
  String? artist = 'Artist',
  String? album = 'Album',
  String? genre = 'Rock',
  String? resUrl = 'http://192.168.1.5:8200/get?id=t1',
  String? duration = '0:03:30.000',
  String upnpClass = 'object.item.audioItem.musicTrack',
}) =>
    '<item id="$id" parentID="0" restricted="1">'
    '<dc:title>$title</dc:title>'
    '<upnp:class>$upnpClass</upnp:class>'
    '${artist != null ? '<upnp:artist>$artist</upnp:artist>' : ''}'
    '${album != null ? '<upnp:album>$album</upnp:album>' : ''}'
    '${genre != null ? '<upnp:genre>$genre</upnp:genre>' : ''}'
    '${resUrl != null ? '<res${duration != null ? ' duration="$duration"' : ''} protocolInfo="http-get:*:audio/mpeg:*">$resUrl</res>' : ''}'
    '</item>';

String soapBrowseResponse(String didlXml) {
  // The Result element's content is the DIDL-Lite XML string,
  // XML-escaped as text — the same double-encoding a real UPnP server
  // produces.
  final escaped = XmlText(didlXml).toXmlString();
  return '<?xml version="1.0"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body>'
      '<u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
      '<Result>$escaped</Result>'
      '<NumberReturned>1</NumberReturned>'
      '<TotalMatches>1</TotalMatches>'
      '<UpdateID>0</UpdateID>'
      '</u:BrowseResponse>'
      '</s:Body>'
      '</s:Envelope>';
}

void main() {
  group('discoverServers', () {
    test('parses LOCATION from SSDP responses and describes each '
        'responding server', () async {
      final transport = _FakeSsdpTransport([
        ssdpResponse('http://192.168.1.5:8200/description.xml'),
      ]);
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async {
          if (req.url.path == '/description.xml') {
            return http.Response(deviceDescription(), 200);
          }
          return http.Response('', 404);
        }),
      );

      final servers = await plugin.discoverServers();

      expect(servers, hasLength(1));
      expect(servers.single.name, 'Test Media Server');
      expect(servers.single.controlUrl.toString(),
          'http://192.168.1.5:8200/ContentDirectory/control');
      expect(plugin.lastError, isNull);
    });

    test('dedupes multiple SSDP responses pointing at the same LOCATION',
        () async {
      final location = 'http://192.168.1.5:8200/description.xml';
      final transport = _FakeSsdpTransport([
        ssdpResponse(location),
        ssdpResponse(location),
        ssdpResponse(location),
      ]);
      var describeCalls = 0;
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async {
          describeCalls++;
          return http.Response(deviceDescription(), 200);
        }),
      );

      final servers = await plugin.discoverServers();

      expect(servers, hasLength(1));
      expect(describeCalls, 1);
    });

    test('honors an explicit URLBase for resolving a relative '
        'controlURL, not the description document\'s own location',
        () async {
      final transport = _FakeSsdpTransport([
        ssdpResponse('http://192.168.1.5:8200/desc.xml'),
      ]);
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async => http.Response(
              deviceDescription(urlBase: 'http://192.168.1.5:9000/'),
              200,
            )),
      );

      final servers = await plugin.discoverServers();

      expect(servers.single.controlUrl.toString(),
          'http://192.168.1.5:9000/ContentDirectory/control');
    });

    test('sets lastError and returns an empty list when nothing responds',
        () async {
      final transport = _FakeSsdpTransport(const []);
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async {
          throw UnimplementedError('should not be called');
        }),
      );

      final servers = await plugin.discoverServers();

      expect(servers, isEmpty);
      expect(plugin.lastError, isNotNull);
    });

    test('a server whose description has no ContentDirectory service is '
        'skipped, not included as unusable', () async {
      final transport = _FakeSsdpTransport([
        ssdpResponse('http://192.168.1.5:8200/desc.xml'),
      ]);
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async => http.Response(
              '<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0">'
              '<device><friendlyName>No CD Service</friendlyName>'
              '<serviceList></serviceList></device></root>',
              200,
            )),
      );

      final servers = await plugin.discoverServers();

      expect(servers, isEmpty);
    });

    test('a server whose description fetch fails is skipped, not '
        'aborting discovery of the others', () async {
      final transport = _FakeSsdpTransport([
        ssdpResponse('http://192.168.1.5:8200/desc.xml'),
        ssdpResponse('http://192.168.1.6:8200/desc.xml'),
      ]);
      final plugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async {
          if (req.url.host == '192.168.1.5') {
            return http.Response('', 500);
          }
          return http.Response(deviceDescription(), 200);
        }),
      );

      final servers = await plugin.discoverServers();

      expect(servers, hasLength(1));
    });
  });

  group('browse', () {
    Future<DlnaServer> discoveredServer(http.Client client) async {
      final transport = _FakeSsdpTransport([
        ssdpResponse('http://192.168.1.5:8200/desc.xml'),
      ]);
      final describePlugin = DlnaPlugin(
        transport: transport,
        client: MockClient((req) async => http.Response(deviceDescription(), 200)),
      );
      final servers = await describePlugin.discoverServers();
      return servers.single;
    }

    test('parses folders and playable tracks from a real Browse/DIDL-Lite '
        'response', () async {
      final didl = didlLite(
        containers: [didlContainer(id: '1', title: 'Music')],
        items: [didlItem()],
      );
      final client = MockClient((req) async {
        if (req.url.path.contains('description') || req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didl), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.folders, hasLength(1));
      expect(result.folders.single.id, '1');
      expect(result.folders.single.title, 'Music');

      expect(result.tracks, hasLength(1));
      final track = result.tracks.single;
      expect(track.id, 'dlna:t1');
      expect(track.title, 'Song One');
      expect(track.type, TrackType.dlna);
      expect(track.artists, ['Artist']);
      expect(track.album, 'Album');
      expect(track.genres, ['Rock']);
      expect(track.streamUrl, 'http://192.168.1.5:8200/get?id=t1');
      expect(track.duration, 210); // 0:03:30 -> 210s
      expect(plugin.lastError, isNull);
    });

    test('sends the ObjectID/BrowseFlag SOAP request with the right '
        'SOAPAction header and containerId', () async {
      Map<String, String>? capturedHeaders;
      String? capturedBody;
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        capturedHeaders = req.headers;
        capturedBody = req.body;
        return http.Response(soapBrowseResponse(didlLite()), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      await plugin.browse(server, containerId: '42');

      expect(capturedHeaders!['SOAPAction'],
          '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"');
      expect(capturedBody, contains('<ObjectID>42</ObjectID>'));
      expect(capturedBody, contains('<BrowseFlag>BrowseDirectChildren</BrowseFlag>'));
    });

    test('a non-audioItem entry (e.g. a video/image item) is filtered '
        'out, not returned as a track', () async {
      final didl = didlLite(items: [
        didlItem(id: 'v1', upnpClass: 'object.item.videoItem'),
        didlItem(id: 'good-1'),
      ]);
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didl), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks, hasLength(1));
      expect(result.tracks.single.id, 'dlna:good-1');
    });

    test('an audioItem with no <res> (no playable file) is skipped '
        'rather than producing a track with no stream URL', () async {
      final didl = didlLite(items: [
        didlItem(id: 'no-res', resUrl: null),
        didlItem(id: 'good-1'),
      ]);
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didl), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks, hasLength(1));
      expect(result.tracks.single.id, 'dlna:good-1');
    });

    test('a track with no artist/album/genre falls back to "Unknown '
        'Artist"/"Unknown Album" and an empty genre list', () async {
      final didl = didlLite(items: [
        didlItem(artist: null, album: null, genre: null),
      ]);
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didl), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks.single.artists, ['Unknown Artist']);
      expect(result.tracks.single.album, 'Unknown Album');
      expect(result.tracks.single.genres, isEmpty);
    });

    test('a track with no duration attribute defaults to 0, not a '
        'crash', () async {
      final didl = didlLite(items: [didlItem(duration: null)]);
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didl), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks.single.duration, 0);
    });

    test('an empty Result (no matches) returns an empty browse result, '
        'not an error', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response(soapBrowseResponse(didlLite()), 200);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.folders, isEmpty);
      expect(result.tracks, isEmpty);
      expect(plugin.lastError, isNull);
    });

    test('returns an empty result and sets lastError on a non-200 '
        'response', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        return http.Response('', 500);
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks, isEmpty);
      expect(result.folders, isEmpty);
      expect(plugin.lastError, contains('500'));
    });

    test('returns an empty result, never throws, when the http call '
        'itself throws', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('desc')) {
          return http.Response(deviceDescription(), 200);
        }
        throw Exception('network unreachable');
      });
      final server = await discoveredServer(client);
      final plugin = DlnaPlugin(client: client);

      final result = await plugin.browse(server);

      expect(result.tracks, isEmpty);
      expect(plugin.lastError, contains('Network error'));
    });
  });

  test('plugin metadata is well-formed', () {
    final plugin = DlnaPlugin();
    expect(plugin.id, 'dlna');
    expect(plugin.usesNetwork, isTrue);
  });
}
