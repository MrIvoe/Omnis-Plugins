import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/service_registry.dart';
import 'package:omnis_plugins/metadata_enrichment_plugin.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only `services` is stubbed — lifecycle (initialize/enable/disable)
/// is all this plugin ever touches on its context, same "stub only what's
/// used" shape `replay_gain_plugin_test.dart`'s `_FakeContext` already
/// establishes. A single retained `ServiceRegistry` (not a fresh one per
/// call) so registration state can actually be inspected after the fact.
class _FakeContext implements PluginContext {
  final ServiceRegistry servicesRegistry = ServiceRegistry();

  @override
  ServiceRegistry get services => servicesRegistry;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} not stubbed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  BaseTrack track({
    String title = 'Song One',
    List<String> artists = const ['Artist One'],
  }) =>
      BaseTrack(
        id: 't1',
        title: title,
        artists: artists,
        album: 'Album',
        duration: 200,
        type: TrackType.local,
      );

  Future<MetadataEnrichmentPlugin> configuredPlugin({
    required http.Client client,
    String? lastfmKey,
    String? discogsToken,
    String? musicbrainzContact,
  }) async {
    final plugin = MetadataEnrichmentPlugin(client: client);
    if (lastfmKey != null) await plugin.setLastfmApiKey(lastfmKey);
    if (discogsToken != null) await plugin.setDiscogsToken(discogsToken);
    if (musicbrainzContact != null) {
      await plugin.setMusicbrainzContact(musicbrainzContact);
    }
    return plugin;
  }

  http.Client neverCalledClient() => MockClient((req) async {
        throw UnimplementedError('should not be called: ${req.url}');
      });

  Map<String, dynamic> mbRecording({
    String? title = 'Song One',
    List<Map<String, dynamic>>? artistCredit,
    List<Map<String, dynamic>>? releases,
  }) =>
      {
        'title': title,
        if (artistCredit != null) 'artist-credit': artistCredit,
        if (releases != null) 'releases': releases,
      };

  Map<String, dynamic> mbResponse(List<Map<String, dynamic>> recordings) =>
      {'recordings': recordings};

  /// A `MockClient` that answers MusicBrainz normally (one match, minimal
  /// shape) and throws if anything else (Last.fm/Discogs) is hit — used by
  /// tests that only care about Last.fm/Discogs gating.
  http.Client mbOnlyClient({List<Map<String, dynamic>>? recordings}) =>
      MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode(mbResponse(recordings ?? [mbRecording()])),
            200,
          );
        }
        throw UnimplementedError('should not be called: ${req.url}');
      });

  group('credential gating', () {
    test('hasLastfmKey/hasDiscogsToken/hasAnyCredential reflect storage',
        () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      expect(plugin.hasLastfmKey, isFalse);
      expect(plugin.hasDiscogsToken, isFalse);
      expect(plugin.hasAnyCredential, isFalse);

      await plugin.setLastfmApiKey('key123');
      expect(plugin.hasLastfmKey, isTrue);
      expect(plugin.hasAnyCredential, isTrue);
      expect(plugin.hasDiscogsToken, isFalse);

      await plugin.setDiscogsToken('token456');
      expect(plugin.hasDiscogsToken, isTrue);
    });

    test('keys are trimmed on write', () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      await plugin.setLastfmApiKey('  key123  ');
      expect(plugin.lastfmApiKey, 'key123');
    });

    test('isAvailable is always true regardless of credentials', () {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      expect(plugin.isAvailable, isTrue);
    });
  });

  group('enrichTrack — empty artist/title guard', () {
    test('empty artist returns an empty result without any network call',
        () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      final result = await plugin.enrichTrack(track(artists: const []));
      expect(result.isEmpty, isTrue);
      expect(result.sourcesUsed, isEmpty);
    });

    test('empty title returns an empty result without any network call',
        () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      final result = await plugin.enrichTrack(track(title: ''));
      expect(result.isEmpty, isTrue);
    });
  });

  group('MusicBrainz — request shape', () {
    test('User-Agent includes the configured contact', () async {
      String? capturedUserAgent;
      final plugin = await configuredPlugin(
        musicbrainzContact: 'me@example.com',
        client: MockClient((req) async {
          capturedUserAgent = req.headers['User-Agent'];
          return http.Response(jsonEncode(mbResponse(const [])), 200);
        }),
      );
      await plugin.enrichTrack(track());
      expect(capturedUserAgent, 'Omnis/0.1.0 ( me@example.com )');
    });

    test('User-Agent falls back to a placeholder when no contact is set',
        () async {
      String? capturedUserAgent;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUserAgent = req.headers['User-Agent'];
          return http.Response(jsonEncode(mbResponse(const [])), 200);
        }),
      );
      await plugin.enrichTrack(track());
      expect(capturedUserAgent, 'Omnis/0.1.0 ( no contact configured )');
    });

    test('query params include a Lucene query, fmt, limit=1, and '
        'inc=release-groups', () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(jsonEncode(mbResponse(const [])), 200);
        }),
      );
      await plugin.enrichTrack(track(title: 'My Song', artists: const ['My Artist']));

      expect(capturedUri, isNotNull);
      expect(capturedUri!.host, 'musicbrainz.org');
      expect(capturedUri!.path, '/ws/2/recording/');
      expect(
        capturedUri!.queryParameters['query'],
        'recording:"My Song" AND artist:"My Artist"',
      );
      expect(capturedUri!.queryParameters['fmt'], 'json');
      expect(capturedUri!.queryParameters['limit'], '1');
      expect(capturedUri!.queryParameters['inc'], 'release-groups');
    });

    test('embedded double quotes in title/artist are Lucene-escaped',
        () async {
      Uri? capturedUri;
      final plugin = await configuredPlugin(
        client: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(jsonEncode(mbResponse(const [])), 200);
        }),
      );
      await plugin.enrichTrack(
        track(title: 'The "Best" Song', artists: const ['A "B" C']),
      );

      expect(
        capturedUri!.queryParameters['query'],
        r'recording:"The \"Best\" Song" AND artist:"A \"B\" C"',
      );
    });
  });

  group('MusicBrainz — response parsing', () {
    test('full match: recording artist-credit, release title/date/type, '
        "release's own artist-credit as albumArtist", () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(
            title: 'Song One',
            artistCredit: [
              {'name': 'Recording Artist'},
            ],
            releases: [
              {
                'title': 'The Album',
                'date': '1999-05-12',
                'artist-credit': [
                  {'name': 'Various Artists'},
                ],
                'release-group': {'primary-type': 'Album'},
              },
            ],
          ),
        ]),
      );

      final result = await plugin.enrichTrack(track());

      expect(result.canonicalTitle, 'Song One');
      expect(result.canonicalArtist, 'Recording Artist');
      expect(result.canonicalAlbum, 'The Album');
      expect(result.year, 1999);
      expect(result.releaseDate, DateTime(1999, 5, 12));
      expect(result.albumArtist, 'Various Artists');
      expect(result.releaseType, ReleaseType.album);
      expect(result.sourcesUsed, contains('MusicBrainz'));
    });

    test('albumArtist falls back to the recording artist when the release '
        'has no artist-credit of its own', () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(
            artistCredit: [
              {'name': 'Recording Artist'},
            ],
            releases: [
              {'title': 'The Album'},
            ],
          ),
        ]),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.albumArtist, 'Recording Artist');
    });

    test('a bare year date sets year but not releaseDate', () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(releases: [
            {'title': 'The Album', 'date': '1999'},
          ]),
        ]),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.year, 1999);
      expect(result.releaseDate, isNull);
    });

    test('a year-month date sets year but not releaseDate', () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(releases: [
            {'title': 'The Album', 'date': '1999-05'},
          ]),
        ]),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.year, 1999);
      expect(result.releaseDate, isNull);
    });

    test('no releases at all leaves album/year/albumArtist/releaseType/'
        'releaseDate null but keeps recording title/artist', () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(
            title: 'Song One',
            artistCredit: [
              {'name': 'Recording Artist'},
            ],
          ),
        ]),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.canonicalTitle, 'Song One');
      expect(result.canonicalArtist, 'Recording Artist');
      expect(result.canonicalAlbum, isNull);
      expect(result.year, isNull);
      expect(result.albumArtist, isNull);
      expect(result.releaseType, isNull);
      expect(result.releaseDate, isNull);
    });

    test('empty recordings list: no MusicBrainz match, not in sourcesUsed',
        () async {
      final plugin = await configuredPlugin(client: mbOnlyClient(recordings: []));
      final result = await plugin.enrichTrack(track());
      expect(result.canonicalTitle, isNull);
      expect(result.sourcesUsed, isNot(contains('MusicBrainz')));
    });

    test('non-200 status: treated as no match, does not throw', () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('', 503)),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.canonicalTitle, isNull);
      expect(result.sourcesUsed, isEmpty);
    });

    test('malformed JSON body: caught, treated as no match, does not throw',
        () async {
      final plugin = await configuredPlugin(
        client: MockClient((req) async => http.Response('not json', 200)),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.canonicalTitle, isNull);
      expect(result.isEmpty, isTrue);
    });

    test('release-group primary-type maps Single/EP/Compilation, and an '
        'unrecognized type (e.g. Broadcast) maps to null rather than a '
        'wrong guess', () async {
      Future<ReleaseType?> typeFor(String primaryType) async {
        final plugin = await configuredPlugin(
          client: mbOnlyClient(recordings: [
            mbRecording(releases: [
              {
                'title': 'X',
                'release-group': {'primary-type': primaryType},
              },
            ]),
          ]),
        );
        return (await plugin.enrichTrack(track())).releaseType;
      }

      expect(await typeFor('Single'), ReleaseType.single);
      expect(await typeFor('EP'), ReleaseType.ep);
      expect(await typeFor('Compilation'), ReleaseType.compilation);
      expect(await typeFor('Broadcast'), isNull);
    });
  });

  group('Last.fm', () {
    Map<String, dynamic> tagsResponse(List<String?> names) => {
          'toptags': {
            'tag': names.map((n) => {'name': n}).toList(),
          },
        };

    test('skipped entirely when no key is configured — no network call',
        () async {
      final plugin = await configuredPlugin(client: mbOnlyClient());
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
      expect(result.sourcesUsed, isNot(contains('Last.fm')));
    });

    test('tags become genres, capped at 5 even when more are returned',
        () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode(tagsResponse(
              ['rock', 'pop', 'live', 'guitar', '90s', 'favorite', 'extra'],
            )),
            200,
          );
        }),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.genres.length, 5);
      expect(result.genres, ['rock', 'pop', 'live', 'guitar', '90s']);
      expect(result.sourcesUsed, contains('Last.fm'));
    });

    test('mood is the first tag (in order) that is a known mood word, '
        'even if a later tag is also a mood word', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode(tagsResponse(['rock', 'chill', 'dark'])),
            200,
          );
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.mood, 'chill');
    });

    test('mood match is case-insensitive against the mood-word list',
        () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode(tagsResponse(['Rock', 'CHILL'])),
            200,
          );
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.mood, 'CHILL');
    });

    test('no mood word among tags leaves mood null', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(jsonEncode(tagsResponse(['rock', 'indie'])), 200);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.mood, isNull);
    });

    test('null/empty tag names are filtered out rather than becoming '
        'empty-string genres', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(jsonEncode(tagsResponse([null, '', 'rock'])), 200);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, ['rock']);
    });

    test('empty tag list: not in sourcesUsed, genres unaffected', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(jsonEncode(tagsResponse(const [])), 200);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
      expect(result.sourcesUsed, isNot(contains('Last.fm')));
    });

    test('non-200 status degrades to empty tags, not a thrown error',
        () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response('', 500);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
    });

    test('a non-list "tag" field degrades to empty tags rather than a cast '
        'error', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode({
              'toptags': {'tag': 'not-a-list'},
            }),
            200,
          );
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
    });
  });

  group('Discogs', () {
    test('skipped entirely when no token is configured — no network call',
        () async {
      final plugin = await configuredPlugin(client: mbOnlyClient());
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
      expect(result.sourcesUsed, isNot(contains('Discogs')));
    });

    test('genre and style fields are concatenated, genre first', () async {
      final plugin = await configuredPlugin(
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'genre': ['Rock'],
                  'style': ['Blues Rock', 'Hard Rock'],
                },
              ],
            }),
            200,
          );
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, ['Rock', 'Blues Rock', 'Hard Rock']);
      expect(result.sourcesUsed, contains('Discogs'));
    });

    test('missing genre/style fields degrade to an empty list, not a '
        'thrown error', () async {
      final plugin = await configuredPlugin(
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(
            jsonEncode({
              'results': [<String, dynamic>{}],
            }),
            200,
          );
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
      expect(result.sourcesUsed, isNot(contains('Discogs')));
    });

    test('empty results list: not in sourcesUsed', () async {
      final plugin = await configuredPlugin(
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response(jsonEncode({'results': []}), 200);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.sourcesUsed, isNot(contains('Discogs')));
    });

    test('non-200 status degrades to no genres, not a thrown error',
        () async {
      final plugin = await configuredPlugin(
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          return http.Response('', 401);
        }),
      );
      final result = await plugin.enrichTrack(track());
      expect(result.genres, isEmpty);
    });
  });

  group('multi-source merge', () {
    test('genres from Last.fm and Discogs merge into one set; sourcesUsed '
        'lists only sources that actually contributed, MusicBrainz first',
        () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(
              jsonEncode(mbResponse([mbRecording()])),
              200,
            );
          }
          if (req.url.host == 'ws.audioscrobbler.com') {
            return http.Response(
              jsonEncode({
                'toptags': {
                  'tag': [
                    {'name': 'rock'},
                  ],
                },
              }),
              200,
            );
          }
          if (req.url.host == 'api.discogs.com') {
            return http.Response(
              jsonEncode({
                'results': [
                  {
                    'genre': ['Pop'],
                  },
                ],
              }),
              200,
            );
          }
          throw UnimplementedError('unexpected host: ${req.url.host}');
        }),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.sourcesUsed, ['MusicBrainz', 'Last.fm', 'Discogs']);
      expect(result.genres.toSet(), {'rock', 'Pop'});
    });

    test('exact-duplicate genre strings across sources collapse via the '
        'underlying Set (case-sensitive — differently-cased duplicates do '
        'not collapse)', () async {
      final plugin = await configuredPlugin(
        lastfmKey: 'key123',
        discogsToken: 'tok123',
        client: MockClient((req) async {
          if (req.url.host == 'musicbrainz.org') {
            return http.Response(jsonEncode(mbResponse(const [])), 200);
          }
          if (req.url.host == 'ws.audioscrobbler.com') {
            return http.Response(
              jsonEncode({
                'toptags': {
                  'tag': [
                    {'name': 'Rock'},
                  ],
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'genre': ['Rock', 'rock'],
                },
              ],
            }),
            200,
          );
        }),
      );

      final result = await plugin.enrichTrack(track());
      expect(result.genres.toSet(), {'Rock', 'rock'});
    });
  });

  group('enrich() delegates to enrichTrack()', () {
    test('produces the same result as calling enrichTrack directly',
        () async {
      final plugin = await configuredPlugin(
        client: mbOnlyClient(recordings: [
          mbRecording(
            artistCredit: [
              {'name': 'Recording Artist'},
            ],
          ),
        ]),
      );
      final viaEnrich = await plugin.enrich(track());
      expect(viaEnrich.canonicalTitle, 'Song One');
      expect(viaEnrich.canonicalArtist, 'Recording Artist');
    });
  });

  group('lifecycle', () {
    test('initialize registers IMetadataProvider; dispose unregisters it',
        () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      final ctx = _FakeContext();
      plugin.attach(ctx);

      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isFalse);
      await plugin.initialize();
      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isTrue);
      expect(ctx.servicesRegistry.get<IMetadataProvider>(), same(plugin));

      await plugin.dispose();
      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isFalse);
    });

    test('disable unregisters; enable re-registers', () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      final ctx = _FakeContext();
      plugin.attach(ctx);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isTrue);

      await plugin.disable();
      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isFalse);

      await plugin.enable();
      expect(ctx.servicesRegistry.has<IMetadataProvider>(), isTrue);
    });

    test('initialize/enable/disable/dispose are no-ops without an attached '
        'context (unit-test-constructed plugin)', () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      await plugin.initialize();
      await plugin.enable();
      await plugin.disable();
      await plugin.dispose();
      // Reaching here without a thrown error is the assertion.
    });

    test('MetadataEnrichmentPlugin satisfies IMetadataProvider', () {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      expect(plugin, isA<IMetadataProvider>());
    });
  });

  group('lookupArtwork (item 12, spec §47)', () {
    test('resolves a release MBID via MusicBrainz then fetches its cover '
        'from the Cover Art Archive', () async {
      final imageBytes = [1, 2, 3, 4];
      final client = MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode(mbResponse([
              mbRecording(releases: [
                {'id': 'release-mbid-123', 'title': 'The Album'},
              ]),
            ])),
            200,
          );
        }
        if (req.url.host == 'coverartarchive.org') {
          expect(req.url.path, '/release/release-mbid-123/front');
          return http.Response.bytes(imageBytes, 200);
        }
        throw UnimplementedError('should not be called: ${req.url}');
      });
      final plugin = MetadataEnrichmentPlugin(client: client);

      final result = await plugin.lookupArtwork(track());

      expect(result, imageBytes);
    });

    test('returns null when no MusicBrainz release matches at all',
        () async {
      final client = MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return http.Response(jsonEncode(mbResponse(const [])), 200);
        }
        throw UnimplementedError('should not be called: ${req.url}');
      });
      final plugin = MetadataEnrichmentPlugin(client: client);

      final result = await plugin.lookupArtwork(track());

      expect(result, isNull);
    });

    test('returns null when the matched release has no MBID, without '
        'ever calling the Cover Art Archive', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode(mbResponse([
              mbRecording(releases: [
                {'title': 'The Album'}, // no 'id'
              ]),
            ])),
            200,
          );
        }
        throw UnimplementedError('should not be called: ${req.url}');
      });
      final plugin = MetadataEnrichmentPlugin(client: client);

      final result = await plugin.lookupArtwork(track());

      expect(result, isNull);
    });

    test('returns null when the archive has no art for this release '
        '(a 404) — an expected outcome, not an error', () async {
      final client = MockClient((req) async {
        if (req.url.host == 'musicbrainz.org') {
          return http.Response(
            jsonEncode(mbResponse([
              mbRecording(releases: [
                {'id': 'release-mbid-123', 'title': 'The Album'},
              ]),
            ])),
            200,
          );
        }
        if (req.url.host == 'coverartarchive.org') {
          return http.Response('', 404);
        }
        throw UnimplementedError('should not be called: ${req.url}');
      });
      final plugin = MetadataEnrichmentPlugin(client: client);

      final result = await plugin.lookupArtwork(track());

      expect(result, isNull);
    });

    test('returns null for a track with no title/artist, without making '
        'any request at all', () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());

      final result = await plugin.lookupArtwork(track(artists: const []));

      expect(result, isNull);
    });
  });

  group('description', () {
    test('mentions credential setup when none are configured', () {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      expect(plugin.description, contains('Last.fm'));
    });

    test('describes lookup capability once a credential is present',
        () async {
      final plugin = MetadataEnrichmentPlugin(client: neverCalledClient());
      await plugin.setLastfmApiKey('key123');
      expect(plugin.description, contains('canonical track info'));
    });
  });
}
