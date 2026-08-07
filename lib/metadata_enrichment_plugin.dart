import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/enrichment_result.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Curated set of words that read as a mood rather than a genre, used to
/// pick [EnrichmentResult.mood] out of a Last.fm tag list.
const _moodWords = {
  'happy', 'sad', 'chill', 'chillout', 'relaxing', 'relax', 'calm',
  'energetic', 'aggressive', 'angry', 'dark', 'melancholic', 'melancholy',
  'uplifting', 'romantic', 'sexy', 'sentimental', 'sleepy', 'dreamy',
  'epic', 'intense', 'mellow', 'peaceful', 'upbeat', 'moody', 'nostalgic',
  'party', 'workout', 'focus', 'feel good',
};

/// A bundled metadata enrichment plugin: canonical track structure from
/// MusicBrainz, and community genre/mood tags from Last.fm and Discogs.
///
/// All three are real HTTP calls against the real public APIs. What's
/// missing is credentials, deliberately: MusicBrainz needs no key beyond a
/// descriptive `User-Agent` ([musicbrainzContact]), but Last.fm and
/// Discogs both require a free account and a user-obtained key/token
/// ([lastfmApiKey], [discogsToken]). This plugin never ships or assumes a
/// key — it reads whatever the user entered in its own settings (tap
/// "Metadata Enrichment" in Plugins) and skips a source entirely when its
/// credential is blank, rather than failing the whole lookup.
///
/// ### Why this instead of Essentia
///
/// Essentia is a C++ library — genuine BPM/key/mood *audio* analysis needs
/// a compiled native binary per platform (`.so` / `.dll` / `.framework`)
/// built with a real native toolchain, then bound via `dart:ffi`. That is
/// a multi-hour native build this environment cannot produce or verify,
/// and shipping `dart:ffi` bindings against a library that doesn't exist
/// in the repo would compile fine and then crash the first time a plugin
/// tried to call it — worse than not having the feature. Last.fm's
/// community tags give real per-track mood/genre data today, driven
/// entirely by a user-supplied key, and feed straight into
/// [BaseTrack.genres] / `mood`, which `SmartPlaylistPlugin` already
/// matches against. A real Essentia integration is a legitimate follow-up
/// project, but it's a native-build effort, not something addable in a
/// single Dart source pass.
class MetadataEnrichmentPlugin extends MusicPlugin implements IMetadataProvider {
  static const _lastfmKeyStorageKey = 'lastfm_api_key';
  static const _discogsTokenStorageKey = 'discogs_token';
  static const _musicbrainzContactStorageKey = 'musicbrainz_contact';

  final http.Client _client;

  MetadataEnrichmentPlugin({http.Client? client})
      : _client = client ?? http.Client();

  /// User-supplied Last.fm API key (free, from last.fm/api/account/create).
  /// Never shipped or defaulted — Last.fm is skipped entirely while blank.
  String get lastfmApiKey => storage.getString(_lastfmKeyStorageKey) ?? '';

  Future<void> setLastfmApiKey(String value) =>
      storage.setString(_lastfmKeyStorageKey, value.trim());

  /// User-supplied Discogs personal access token
  /// (discogs.com/settings/developers).
  String get discogsToken => storage.getString(_discogsTokenStorageKey) ?? '';

  Future<void> setDiscogsToken(String value) =>
      storage.setString(_discogsTokenStorageKey, value.trim());

  /// Contact info (email or app URL) MusicBrainz's API etiquette asks
  /// every client to send in its User-Agent header. MusicBrainz itself
  /// needs no API key, just this.
  String get musicbrainzContact =>
      storage.getString(_musicbrainzContactStorageKey) ?? '';

  Future<void> setMusicbrainzContact(String value) =>
      storage.setString(_musicbrainzContactStorageKey, value.trim());

  bool get hasLastfmKey => lastfmApiKey.isNotEmpty;

  bool get hasDiscogsToken => discogsToken.isNotEmpty;

  /// Whether any enrichment source can run right now. MusicBrainz always
  /// can (no credential needed); this reports whether Last.fm/Discogs add
  /// anything beyond that.
  bool get hasAnyCredential => hasLastfmKey || hasDiscogsToken;

  /// [IMetadataProvider.isAvailable] — always `true`: MusicBrainz needs no
  /// credential, so this plugin is never fully inert the way
  /// `AudioAnalysisPlugin` is before a service URL is configured.
  /// [hasAnyCredential] is the separate, plugin-specific detail UI uses to
  /// hint that Last.fm/Discogs would add genre/mood data.
  @override
  bool get isAvailable => true;

  @override
  Future<EnrichmentResult> enrich(BaseTrack track) => enrichTrack(track);

  /// Look up [track] against every source with a configured credential.
  /// MusicBrainz always runs. Never throws — a failed or unreachable
  /// source is skipped, not fatal; callers still get whatever the other
  /// sources found.
  Future<EnrichmentResult> enrichTrack(BaseTrack track) async {
    final artist = track.artists.isNotEmpty ? track.artists.first : '';
    final title = track.title;
    if (artist.isEmpty || title.isEmpty) return const EnrichmentResult();

    final sources = <String>[];
    final mb = await _queryMusicBrainz(artist, title);
    if (mb != null) sources.add('MusicBrainz');

    final genres = <String>{};
    String? mood;

    if (hasLastfmKey) {
      final tags = await _queryLastfmTags(artist, title);
      if (tags.isNotEmpty) {
        genres.addAll(tags);
        for (final tag in tags) {
          if (_moodWords.contains(tag.toLowerCase())) {
            mood = tag;
            break;
          }
        }
        sources.add('Last.fm');
      }
    }

    if (hasDiscogsToken) {
      final discogsGenres = await _queryDiscogs(artist, title);
      if (discogsGenres.isNotEmpty) {
        genres.addAll(discogsGenres);
        sources.add('Discogs');
      }
    }

    return EnrichmentResult(
      canonicalTitle: mb?.title,
      canonicalArtist: mb?.artist,
      canonicalAlbum: mb?.album,
      year: mb?.year,
      albumArtist: mb?.albumArtist,
      releaseType: mb?.releaseType,
      releaseDate: mb?.releaseDate,
      genres: genres.toList(),
      mood: mood,
      sourcesUsed: sources,
    );
  }

  Future<_MusicBrainzMatch?> _queryMusicBrainz(
    String artist,
    String title,
  ) async {
    final contact = musicbrainzContact;
    // MusicBrainz's API etiquette requires a descriptive User-Agent with
    // real contact info; requests without one are rate-limited harder or
    // rejected. The placeholder here is honest about being a placeholder.
    final userAgent = contact.isNotEmpty
        ? 'Omnis/0.1.0 ( $contact )'
        : 'Omnis/0.1.0 ( no contact configured )';
    final query =
        'recording:"${_escapeLucene(title)}" AND artist:"${_escapeLucene(artist)}"';
    final uri = Uri.https('musicbrainz.org', '/ws/2/recording/', {
      'query': query,
      'fmt': 'json',
      'limit': '1',
      // release-groups nests release-group.primary-type (album / single /
      // EP / compilation) under each release, and the release's own
      // artist-credit (distinct from the recording's) — neither is
      // present in the default response.
      'inc': 'release-groups',
    });
    try {
      final resp = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final recordings = json['recordings'] as List<dynamic>?;
      if (recordings == null || recordings.isEmpty) return null;
      final rec = recordings.first as Map<String, dynamic>;
      final artistCredit = rec['artist-credit'] as List<dynamic>?;
      final artistName =
          (artistCredit != null && artistCredit.isNotEmpty)
              ? (artistCredit.first as Map<String, dynamic>)['name']
                  as String?
              : null;
      final releases = rec['releases'] as List<dynamic>?;
      String? album;
      int? year;
      String? albumArtist;
      ReleaseType? releaseType;
      DateTime? releaseDate;
      if (releases != null && releases.isNotEmpty) {
        final release = releases.first as Map<String, dynamic>;
        album = release['title'] as String?;
        final date = release['date'] as String?;
        if (date != null && date.length >= 4) {
          year = int.tryParse(date.substring(0, 4));
        }
        // Only a full YYYY-MM-DD date parses as a DateTime — MusicBrainz
        // also returns bare-year or year-month partial dates, which
        // DateTime.tryParse correctly rejects rather than guessing a day.
        if (date != null) releaseDate = DateTime.tryParse(date);

        final releaseArtistCredit = release['artist-credit'] as List<dynamic>?;
        albumArtist =
            (releaseArtistCredit != null && releaseArtistCredit.isNotEmpty)
                ? (releaseArtistCredit.first as Map<String, dynamic>)['name']
                    as String?
                : artistName;

        final releaseGroup = release['release-group'] as Map<String, dynamic>?;
        releaseType = _releaseTypeFromMusicBrainz(
          releaseGroup?['primary-type'] as String?,
        );
      }
      return _MusicBrainzMatch(
        title: rec['title'] as String?,
        artist: artistName,
        album: album,
        year: year,
        albumArtist: albumArtist,
        releaseType: releaseType,
        releaseDate: releaseDate,
      );
    } catch (e) {
      return null;
    }
  }

  Future<List<String>> _queryLastfmTags(String artist, String title) async {
    final key = lastfmApiKey;
    if (key.isEmpty) return const [];
    final uri = Uri.https('ws.audioscrobbler.com', '/2.0/', {
      'method': 'track.gettoptags',
      'artist': artist,
      'track': title,
      'api_key': key,
      'format': 'json',
    });
    try {
      final resp = await _client.get(uri).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final topTags = json['toptags'] as Map<String, dynamic>?;
      final tagList = topTags?['tag'];
      if (tagList is! List) return const [];
      return tagList
          .map((t) => (t as Map<String, dynamic>)['name']?.toString())
          .whereType<String>()
          .where((t) => t.isNotEmpty)
          .take(5)
          .toList();
    } catch (e) {
      return const [];
    }
  }

  Future<List<String>> _queryDiscogs(String artist, String title) async {
    final token = discogsToken;
    if (token.isEmpty) return const [];
    final uri = Uri.https('api.discogs.com', '/database/search', {
      'q': '$artist $title',
      'type': 'release',
      'token': token,
    });
    try {
      final resp = await _client
          .get(uri, headers: {'User-Agent': 'Omnis/0.1.0'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final results = json['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return const [];
      final first = results.first as Map<String, dynamic>;
      final genres = <String>[];
      for (final field in const ['genre', 'style']) {
        final list = first[field];
        if (list is List) {
          genres.addAll(list.map((e) => e.toString()));
        }
      }
      return genres;
    } catch (e) {
      return const [];
    }
  }

  static String _escapeLucene(String input) => input.replaceAll('"', r'\"');

  @override
  String get id => 'metadata_enrichment';

  @override
  String get name => 'Metadata Enrichment';

  @override
  String get description => hasAnyCredential
      ? 'Looks up canonical track info and community genre/mood tags.'
      : 'Add a Last.fm key or Discogs token in this plugin\'s settings to '
          'enable genre/mood lookups; MusicBrainz structure lookup works '
          'without one.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IMetadataProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => locationID == 'plugin_settings'
      ? _MetadataEnrichmentSettings(plugin: this)
      : null;

  @override
  Future<void> enable() async {
    context?.services.register(IMetadataProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IMetadataProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IMetadataProvider, this);
    _client.close();
  }
}

class _MusicBrainzMatch {
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final String? albumArtist;
  final ReleaseType? releaseType;
  final DateTime? releaseDate;

  const _MusicBrainzMatch({
    this.title,
    this.artist,
    this.album,
    this.year,
    this.albumArtist,
    this.releaseType,
    this.releaseDate,
  });
}

/// Maps MusicBrainz's `release-group.primary-type` string to
/// [ReleaseType]. MusicBrainz's vocabulary is wider than ours (it also
/// has "Broadcast", "Other", etc.) — anything not in our four values
/// comes back `null` rather than a wrong guess.
ReleaseType? _releaseTypeFromMusicBrainz(String? primaryType) {
  switch (primaryType) {
    case 'Album':
      return ReleaseType.album;
    case 'Single':
      return ReleaseType.single;
    case 'EP':
      return ReleaseType.ep;
    case 'Compilation':
      return ReleaseType.compilation;
    default:
      return null;
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins list,
/// not embedded in the app-wide Settings page. Previously these three
/// fields lived in `settings_page.dart` as `_MetadataCredentialsSection`,
/// which meant Settings had to know this plugin exists; now the plugin
/// owns its own configuration UI end to end.
class _MetadataEnrichmentSettings extends StatefulWidget {
  final MetadataEnrichmentPlugin plugin;

  const _MetadataEnrichmentSettings({required this.plugin});

  @override
  State<_MetadataEnrichmentSettings> createState() =>
      _MetadataEnrichmentSettingsState();
}

class _MetadataEnrichmentSettingsState
    extends State<_MetadataEnrichmentSettings> {
  late final TextEditingController _lastfm;
  late final TextEditingController _discogs;
  late final TextEditingController _musicbrainz;

  @override
  void initState() {
    super.initState();
    _lastfm = TextEditingController(text: widget.plugin.lastfmApiKey);
    _discogs = TextEditingController(text: widget.plugin.discogsToken);
    _musicbrainz =
        TextEditingController(text: widget.plugin.musicbrainzContact);
  }

  @override
  void dispose() {
    _lastfm.dispose();
    _discogs.dispose();
    _musicbrainz.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _lastfm,
          decoration: const InputDecoration(
            labelText: 'Last.fm API key',
            hintText: 'Free at last.fm/api/account/create',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.tag),
          ),
          onChanged: widget.plugin.setLastfmApiKey,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _discogs,
          decoration: const InputDecoration(
            labelText: 'Discogs personal access token',
            hintText: 'Free at discogs.com/settings/developers',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.album),
          ),
          onChanged: widget.plugin.setDiscogsToken,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _musicbrainz,
          decoration: const InputDecoration(
            labelText: 'MusicBrainz contact (optional)',
            hintText: 'Not a key — MusicBrainz lookups work without this; '
                'it just makes them more polite',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.public),
          ),
          onChanged: widget.plugin.setMusicbrainzContact,
        ),
      ],
    );
  }
}
