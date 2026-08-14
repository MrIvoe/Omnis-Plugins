import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:xml/xml.dart';

/// Discovers and browses DLNA/UPnP media servers on the local network.
///
/// Fundamentally a different *kind* of protocol from `OpenSubsonicPlugin`/
/// `JellyfinPlugin`/`PlexPlugin`: no JSON REST API, no username/token —
/// discovery is SSDP (a UDP multicast `M-SEARCH`, UPnP's HTTP-over-UDP
/// variant), and browsing is a SOAP action (`ContentDirectory#Browse`)
/// whose response embeds DIDL-Lite XML as escaped text inside another
/// XML document. Real media servers on a trusted local network typically
/// need **no authentication at all**, unlike every self-hosted provider
/// this session added before it.
///
/// Each track's [BaseTrack.streamUrl] is the real `<res>` URL a `Browse`
/// response points at — directly playable through the same
/// `AudioEngine.uriFor` path every other `streamUrl`-bearing track type
/// uses, zero special-casing.
///
/// **A real, documented platform caveat this session cannot verify
/// end-to-end**: Android filters incoming WiFi multicast packets by
/// default, and receiving UDP multicast traffic (what SSDP discovery
/// needs) normally requires the app to hold a
/// `WifiManager.MulticastLock` — acquired via a platform channel this
/// plugin does not implement. Without it, [discoverServers] may find
/// nothing on some real Android devices even with a real DLNA server
/// present and reachable, despite the SSDP/SOAP/DIDL-Lite protocol logic
/// itself being genuine and fully tested below (with an injected
/// [SsdpTransport], not a real socket). This is a real, separate gap,
/// not a hidden one — see `OMNIS_2_0_MISSED_DEEP_PHASE.md`.
class DlnaPlugin extends MusicPlugin {
  final http.Client _client;
  final SsdpTransport _transport;

  String? lastError;

  DlnaPlugin({http.Client? client, SsdpTransport? transport})
      : _client = client ?? http.Client(),
        _transport = transport ?? const UdpSsdpTransport();

  /// Sends an SSDP `M-SEARCH` for UPnP media servers and describes each
  /// one that responds. Never throws — a total failure (no network, no
  /// responses) sets [lastError] and returns an empty list.
  Future<List<DlnaServer>> discoverServers({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final responses = await _transport.discover(timeout: timeout);
    final locations = <String>{};
    for (final response in responses) {
      final location = _header(response, 'LOCATION');
      if (location != null && location.isNotEmpty) locations.add(location);
    }
    final servers = <DlnaServer>[];
    for (final location in locations) {
      try {
        final server = await _describeServer(location);
        if (server != null) servers.add(server);
      } catch (_) {
        continue;
      }
    }
    lastError =
        servers.isEmpty ? 'No DLNA/UPnP media servers found on this network.' : null;
    return servers;
  }

  Future<DlnaServer?> _describeServer(String location) async {
    final locationUri = Uri.tryParse(location);
    if (locationUri == null) return null;
    final resp = await _client.get(locationUri).timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return null;

    final doc = XmlDocument.parse(resp.body);
    // friendlyName/URLBase sit under <root><device>, not as direct
    // children of <root> itself — findAllElements searches the whole
    // document (matching by local name, ignoring namespace prefix),
    // which is what actually reaches them.
    final friendlyName = doc.findAllElements('friendlyName').isNotEmpty
        ? doc.findAllElements('friendlyName').first.innerText.trim()
        : null;

    // Deprecated in UPnP 1.1 (relative URLs should resolve against the
    // description document's own URL instead), but some real servers
    // still emit it, and honoring it when present is the correct thing
    // to do regardless of which UPnP version wrote it.
    final urlBase = doc.findAllElements('URLBase').isNotEmpty
        ? doc.findAllElements('URLBase').first.innerText.trim()
        : null;
    final baseUri = (urlBase != null && urlBase.isNotEmpty)
        ? (Uri.tryParse(urlBase) ?? locationUri)
        : locationUri;

    String? controlUrl;
    for (final service in doc.findAllElements('service')) {
      final serviceType = _firstChildTextByLocalName(service, 'serviceType');
      if (serviceType != null && serviceType.contains('ContentDirectory')) {
        controlUrl = _firstChildTextByLocalName(service, 'controlURL');
        break;
      }
    }
    if (controlUrl == null || controlUrl.isEmpty) return null;

    return DlnaServer(
      name: (friendlyName != null && friendlyName.isNotEmpty)
          ? friendlyName
          : locationUri.host,
      controlUrl: baseUri.resolve(controlUrl),
    );
  }

  /// Browses [server]'s content directory starting at [containerId]
  /// (`"0"` is the UPnP-standard root). Returns the folders and playable
  /// tracks found directly inside it — never throws; a failure sets
  /// [lastError] and returns an empty result.
  Future<DlnaBrowseResult> browse(
    DlnaServer server, {
    String containerId = '0',
  }) async {
    const empty = DlnaBrowseResult(folders: [], tracks: []);
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">'
        '<ObjectID>$containerId</ObjectID>'
        '<BrowseFlag>BrowseDirectChildren</BrowseFlag>'
        '<Filter>*</Filter>'
        '<StartingIndex>0</StartingIndex>'
        '<RequestedCount>200</RequestedCount>'
        '<SortCriteria></SortCriteria>'
        '</u:Browse>'
        '</s:Body>'
        '</s:Envelope>';
    try {
      final resp = await _client
          .post(
            server.controlUrl,
            headers: {
              'Content-Type': 'text/xml; charset="utf-8"',
              'SOAPAction':
                  '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        lastError = 'Server returned HTTP ${resp.statusCode}.';
        return empty;
      }

      final envelope = XmlDocument.parse(resp.body);
      final resultElements = envelope.findAllElements('Result');
      if (resultElements.isEmpty) {
        lastError = null;
        return empty;
      }
      // The Result element's text is XML-escaped DIDL-Lite — real XML
      // content encoded as a string, not raw child elements. Decoding
      // entities happens automatically when reading .innerText; parsing
      // that decoded string as its own XmlDocument is what actually
      // reaches the real <container>/<item> elements.
      final didlText = resultElements.first.innerText;
      if (didlText.isEmpty) {
        lastError = null;
        return empty;
      }
      final didl = XmlDocument.parse(didlText);

      final folders = <DlnaFolder>[];
      final tracks = <BaseTrack>[];
      // Per-entry defensive decoding — one malformed container/item must
      // not wipe the rest of the browse result, the same contract every
      // other network-backed plugin in this repo follows.
      for (final element in didl.rootElement.childElements) {
        try {
          if (element.name.local == 'container') {
            final folder = _containerToFolder(element);
            if (folder != null) folders.add(folder);
          } else if (element.name.local == 'item') {
            final track = _itemToTrack(element);
            if (track != null) tracks.add(track);
          }
        } catch (_) {
          continue;
        }
      }
      lastError = null;
      return DlnaBrowseResult(folders: folders, tracks: tracks);
    } catch (e) {
      lastError = 'Network error: $e';
      return empty;
    }
  }

  DlnaFolder? _containerToFolder(XmlElement container) {
    final id = container.getAttribute('id');
    final title = _firstChildTextByLocalName(container, 'title')?.trim();
    if (id == null || id.isEmpty || title == null || title.isEmpty) {
      return null;
    }
    return DlnaFolder(id: id, title: title);
  }

  BaseTrack? _itemToTrack(XmlElement item) {
    final id = item.getAttribute('id');
    final title = _firstChildTextByLocalName(item, 'title')?.trim();
    final className = _firstChildTextByLocalName(item, 'class') ?? '';
    if (id == null ||
        id.isEmpty ||
        title == null ||
        title.isEmpty ||
        !className.contains('audioItem')) {
      return null;
    }
    final resElement = _firstChildByLocalName(item, 'res');
    final streamUrl = resElement?.innerText.trim();
    if (streamUrl == null || streamUrl.isEmpty) return null;

    final artist = _firstChildTextByLocalName(item, 'artist')?.trim();
    final album = _firstChildTextByLocalName(item, 'album')?.trim();
    final genre = _firstChildTextByLocalName(item, 'genre')?.trim();
    final duration = _parseDidlDuration(resElement?.getAttribute('duration'));

    return BaseTrack(
      id: 'dlna:$id',
      title: title,
      artists: [
        (artist != null && artist.isNotEmpty) ? artist : 'Unknown Artist',
      ],
      album: (album != null && album.isNotEmpty) ? album : 'Unknown Album',
      duration: duration ?? 0,
      genres: (genre != null && genre.isNotEmpty) ? [genre] : const [],
      type: TrackType.dlna,
      streamUrl: streamUrl,
    );
  }

  /// Finds a direct child by local name only (ignoring namespace prefix)
  /// — DIDL-Lite/device-description XML mixes prefixed (`dc:title`,
  /// `upnp:class`) and unprefixed elements depending on server and
  /// document, and matching by local name is what makes this robust to
  /// either.
  static XmlElement? _firstChildByLocalName(XmlElement parent, String localName) {
    for (final child in parent.childElements) {
      if (child.name.local == localName) return child;
    }
    return null;
  }

  static String? _firstChildTextByLocalName(XmlElement parent, String localName) =>
      _firstChildByLocalName(parent, localName)?.innerText;

  /// Parses a DIDL-Lite `res` element's `duration` attribute
  /// (`H+:MM:SS[.mmm]`, per the UPnP ContentDirectory spec) into whole
  /// seconds. Returns `null` (not 0) for a missing/malformed value, so
  /// callers can tell "genuinely unknown" apart from "zero seconds."
  static int? _parseDidlDuration(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length != 3) return null;
    try {
      final hours = int.parse(parts[0]);
      final minutes = int.parse(parts[1]);
      final seconds = int.parse(parts[2].split('.').first);
      return hours * 3600 + minutes * 60 + seconds;
    } catch (_) {
      return null;
    }
  }

  static String? _header(String response, String name) {
    final prefix = '${name.toLowerCase()}:';
    for (final line in response.split('\r\n')) {
      if (line.toLowerCase().startsWith(prefix)) {
        return line.substring(line.indexOf(':') + 1).trim();
      }
    }
    return null;
  }

  @override
  String get id => 'dlna';

  @override
  String get name => 'DLNA / UPnP';

  @override
  String get description =>
      'Discover and stream from DLNA/UPnP media servers on your local '
      'network.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _DlnaSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

/// A discovered DLNA/UPnP media server.
class DlnaServer {
  final String name;
  final Uri controlUrl;

  const DlnaServer({required this.name, required this.controlUrl});
}

/// One browsable folder (a UPnP `container`) inside a server's content
/// directory.
class DlnaFolder {
  final String id;
  final String title;

  const DlnaFolder({required this.id, required this.title});
}

/// The direct children of one browsed container — the folders to
/// navigate into and the playable tracks found there.
class DlnaBrowseResult {
  final List<DlnaFolder> folders;
  final List<BaseTrack> tracks;

  const DlnaBrowseResult({required this.folders, required this.tracks});
}

/// The transport SSDP discovery runs over — abstracted so
/// [DlnaPlugin.discoverServers] is fully unit-testable against a fake
/// set of response strings, without a test needing a real UDP socket
/// (or a real network with a real DLNA server on it, which no CI/test
/// environment can assume).
abstract class SsdpTransport {
  Future<List<String>> discover({Duration timeout});
}

/// The real transport: a UDP multicast `M-SEARCH` per the SSDP spec,
/// collecting whatever responses arrive within [timeout].
///
/// See [DlnaPlugin]'s class doc for the real, documented Android
/// multicast-filtering caveat this can hit on a real device.
class UdpSsdpTransport implements SsdpTransport {
  const UdpSsdpTransport();

  @override
  Future<List<String>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final responses = <String>[];
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      const message = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
          '\r\n';
      socket.send(
        utf8.encode(message),
        InternetAddress('239.255.255.250'),
        1900,
      );

      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final packet = socket!.receive();
        if (packet != null) {
          responses.add(utf8.decode(packet.data, allowMalformed: true));
        }
      });
      await Future<void>.delayed(timeout);
      await sub.cancel();
    } catch (_) {
      // No network, no socket permission, etc. — degrade to "found
      // nothing," the same fail-soft contract every other network-backed
      // plugin in this repo follows, rather than throwing out of
      // discoverServers.
    } finally {
      socket?.close();
    }
    return responses;
  }
}

class _DlnaSettings extends StatefulWidget {
  final DlnaPlugin plugin;

  const _DlnaSettings({required this.plugin});

  @override
  State<_DlnaSettings> createState() => _DlnaSettingsState();
}

class _DlnaSettingsState extends State<_DlnaSettings> {
  bool _discovering = false;
  bool _browsing = false;
  List<DlnaServer> _servers = const [];
  DlnaServer? _selectedServer;
  final List<String> _containerStack = ['0'];
  DlnaBrowseResult _current = const DlnaBrowseResult(folders: [], tracks: []);

  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _selectedServer = null;
      _current = const DlnaBrowseResult(folders: [], tracks: []);
    });
    final servers = await widget.plugin.discoverServers();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _discovering = false;
    });
  }

  Future<void> _openServer(DlnaServer server) async {
    setState(() {
      _selectedServer = server;
      _containerStack
        ..clear()
        ..add('0');
    });
    await _browseCurrent();
  }

  Future<void> _openFolder(DlnaFolder folder) async {
    setState(() => _containerStack.add(folder.id));
    await _browseCurrent();
  }

  Future<void> _goBack() async {
    if (_containerStack.length <= 1) {
      setState(() {
        _selectedServer = null;
        _current = const DlnaBrowseResult(folders: [], tracks: []);
      });
      return;
    }
    setState(() => _containerStack.removeLast());
    await _browseCurrent();
  }

  Future<void> _browseCurrent() async {
    final server = _selectedServer;
    if (server == null) return;
    setState(() => _browsing = true);
    final result =
        await widget.plugin.browse(server, containerId: _containerStack.last);
    if (!mounted) return;
    setState(() {
      _current = result;
      _browsing = false;
    });
  }

  Future<void> _play(int index) async {
    final context = widget.plugin.context;
    if (context == null) return;
    await context.setQueue(_current.tracks, startIndex: index);
    await context.play();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Finds DLNA/UPnP media servers on your local network — no '
          'account or password needed for most servers.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _discovering ? null : _discover,
              icon: _discovering
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_find),
              label: Text(_discovering ? 'Searching…' : 'Discover servers'),
            ),
            if (_selectedServer != null) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _browsing ? null : _goBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Back'),
              ),
            ],
          ],
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 12),
        if (_browsing)
          const Center(child: CircularProgressIndicator())
        else if (_selectedServer == null) ...[
          for (final server in _servers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.dns_outlined),
              title: Text(server.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openServer(server),
            ),
        ] else ...[
          for (final folder in _current.folders)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: Text(folder.title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openFolder(folder),
            ),
          for (var i = 0; i < _current.tracks.length; i++)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: Text(_current.tracks[i].title),
              subtitle: Text(_current.tracks[i].artists.join(', ')),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => _play(i),
            ),
        ],
      ],
    );
  }
}
