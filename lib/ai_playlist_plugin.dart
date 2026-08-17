import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// The first two real slices of the spec's §21 "AI subsystem" — natural
/// language playlist creation ("make me a two-hour workout playlist")
/// and natural language *search* ("upbeat songs from the 90s I haven't
/// played in a while" — item 43's own named gap), both backed by a real
/// cloud LLM (Anthropic's Messages API) using a user-supplied API key,
/// matching the same "user brings their own credential" pattern
/// `MetadataEnrichmentPlugin`'s Last.fm/Discogs keys already
/// established — this app ships no embedded key of its own. The two
/// differ only in what's asked of the model (a curated listening order
/// vs. an unordered set of genuine matches) — see [_queryModel], the
/// shared request/response machinery both build on.
///
/// The model never invents tracks: it's given a compact JSON summary of
/// the real library (id/title/artist/genres/mood/bpm/duration for each
/// track — nothing fabricated, only fields [BaseTrack] actually has) and
/// asked to respond with *only* a JSON array of track ids picked from
/// that list. Every returned id is checked against the library before
/// use; an id the model invented or one that isn't in what it was shown
/// is silently dropped, never surfaced as a broken track. This is what
/// keeps the feature honest — a "hallucinated" track title can't end up
/// in the queue, at worst the queue is just shorter than requested.
///
/// The library sample sent to the model is capped ([_maxLibrarySample])
/// to keep the request a bounded, reasonable size regardless of how
/// large the user's real library is — a real, documented limitation: a
/// prompt like "find me the deep cuts" has no way to consider a track
/// that didn't make the sample. Not attempted here: streaming the whole
/// library through multiple requests, or a proper retrieval step
/// (embeddings/vector search) that would pick a *relevant* sample
/// instead of an arbitrary prefix — real, separate work.
///
/// This has not been exercised against the real Anthropic API in this
/// environment — what's verified is protocol-level request/response
/// handling against a mocked HTTP client (see this class's tests), not
/// a live call with real spend attached.
class AIPlaylistPlugin extends MusicPlugin implements IAIProvider {
  static const _apiKeyKey = 'anthropic_api_key';
  static const _modelKey = 'model';
  static const _defaultModel = 'claude-3-5-haiku-20241022';
  static const _maxLibrarySample = 300;

  final http.Client _client;

  String? lastError;

  AIPlaylistPlugin({http.Client? client}) : _client = client ?? http.Client();

  String get apiKey => storage.getString(_apiKeyKey) ?? '';
  Future<void> setApiKey(String value) =>
      storage.setString(_apiKeyKey, value.trim());

  String get model => storage.getString(_modelKey) ?? _defaultModel;
  Future<void> setModel(String value) {
    final trimmed = value.trim();
    return storage.setString(_modelKey, trimmed.isEmpty ? _defaultModel : trimmed);
  }

  @override
  bool get isAvailable => apiKey.isNotEmpty;

  @override
  Future<List<BaseTrack>> buildPlaylistFromPrompt(
    String prompt,
    List<BaseTrack> library,
  ) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) return const [];
    if (!isAvailable) {
      lastError = 'No Anthropic API key configured.';
      return const [];
    }
    if (library.isEmpty) {
      lastError = 'Your library is empty — nothing to build a playlist from.';
      return const [];
    }

    return _queryModel(
      library: library,
      systemPrompt: 'You are a music playlist assistant for a local '
          'music library. You will be given a JSON array of '
          'tracks (each with an "id") and a listener\'s request. '
          'Reply with ONLY a JSON array of the "id" strings of '
          'tracks from the given list that best fit the request, '
          'in a good listening order, and nothing else — no '
          'prose, no markdown, no explanation. Only use ids that '
          'appear in the given list; never invent one.',
      userMessagePrefix: 'Request: $trimmedPrompt',
    );
  }

  @override
  Future<List<BaseTrack>> searchLibrary(
    String query,
    List<BaseTrack> library,
  ) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return const [];
    if (!isAvailable) {
      lastError = 'No Anthropic API key configured.';
      return const [];
    }
    if (library.isEmpty) {
      lastError = 'Your library is empty — nothing to search.';
      return const [];
    }

    return _queryModel(
      library: library,
      systemPrompt: 'You are a natural-language search assistant for a '
          'local music library. You will be given a JSON array of '
          'tracks (each with an "id") and a listener\'s search query — '
          'which may describe mood, genre, era, tempo, or listening '
          'history, not just literal title/artist text. Reply with '
          'ONLY a JSON array of the "id" strings of tracks from the '
          'given list that genuinely match the query — order does not '
          'matter, and nothing else — no prose, no markdown, no '
          'explanation. Only use ids that appear in the given list; '
          'never invent one. If nothing matches, reply with an empty '
          'JSON array.',
      userMessagePrefix: 'Search: $trimmedQuery',
    );
  }

  /// Shared by [buildPlaylistFromPrompt]/[searchLibrary] — both send a
  /// capped, real-fields-only sample of [library] plus a task-specific
  /// [systemPrompt]/[userMessagePrefix] to the same Anthropic Messages
  /// API, and both need the identical response handling: a non-200
  /// status, an unparseable envelope, a markdown-fenced reply, and (the
  /// "never invents a track" guarantee) filtering the model's returned
  /// ids down to only ones that actually exist in the sample it was
  /// shown. Only the *reason* for the request differs between the two
  /// callers, not how the request/response is handled.
  Future<List<BaseTrack>> _queryModel({
    required List<BaseTrack> library,
    required String systemPrompt,
    required String userMessagePrefix,
  }) async {
    final sample = library.take(_maxLibrarySample).toList();
    final byId = {for (final t in sample) t.id: t};
    final catalog = sample
        .map((t) => {
              'id': t.id,
              'title': t.title,
              'artist': t.artists.join(', '),
              'genres': t.genres,
              if (t.mood != null) 'mood': t.mood,
              if (t.bpm != null) 'bpm': t.bpm,
              'durationSec': t.duration,
            })
        .toList();

    try {
      final resp = await _client
          .post(
            Uri.https('api.anthropic.com', '/v1/messages'),
            headers: {
              'x-api-key': apiKey,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': 1024,
              'system': systemPrompt,
              'messages': [
                {
                  'role': 'user',
                  'content': '$userMessagePrefix\n\n'
                      'Tracks: ${jsonEncode(catalog)}',
                }
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode != 200) {
        lastError = _apiErrorMessage(resp.body) ??
            'Server returned HTTP ${resp.statusCode}.';
        return const [];
      }

      final decoded = jsonDecode(resp.body);
      final content = decoded is Map ? decoded['content'] : null;
      if (content is! List || content.isEmpty) {
        lastError = 'Unrecognized response from the AI provider.';
        return const [];
      }
      final firstBlock = content.first;
      final text = firstBlock is Map ? firstBlock['text']?.toString() : null;
      if (text == null) {
        lastError = 'Unrecognized response from the AI provider.';
        return const [];
      }

      final ids = _extractIdList(text);
      if (ids == null) {
        lastError = 'Could not understand the AI provider\'s reply.';
        return const [];
      }

      lastError = null;
      // Only ids that actually exist in the sample survive — this is
      // what makes the "never invents a track" guarantee real, not just
      // a doc-comment claim.
      return [
        for (final id in ids)
          if (byId[id] != null) byId[id]!,
      ];
    } catch (e) {
      lastError = 'Network error: $e';
      return const [];
    }
  }

  /// The model is instructed to reply with *only* a JSON array, but LLMs
  /// routinely wrap output in a markdown code fence anyway — stripped
  /// defensively here before parsing, rather than trusting instructions
  /// alone. Returns `null` (not an empty list) when the text genuinely
  /// isn't a JSON array of strings, so callers can tell "the model
  /// picked nothing" apart from "the response was unparseable."
  List<String>? _extractIdList(String text) {
    var cleaned = text.trim();
    if (cleaned.startsWith('```')) {
      final firstNewline = cleaned.indexOf('\n');
      if (firstNewline != -1) cleaned = cleaned.substring(firstNewline + 1);
      final fenceEnd = cleaned.lastIndexOf('```');
      if (fenceEnd != -1) cleaned = cleaned.substring(0, fenceEnd);
      cleaned = cleaned.trim();
    }
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is! List) return null;
      return decoded.whereType<String>().toList();
    } catch (_) {
      return null;
    }
  }

  String? _apiErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      return error is Map ? error['message']?.toString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  String get id => 'ai_playlist';

  @override
  String get name => 'AI Playlists & Search';

  @override
  String get description =>
      'Describe a playlist or search your library in plain language, '
      'using your own Anthropic API key.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {
    context?.services.register(IAIProvider, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(IAIProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IAIProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _AIPlaylistSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    _client.close();
  }
}

class _AIPlaylistSettings extends StatefulWidget {
  final AIPlaylistPlugin plugin;

  const _AIPlaylistSettings({required this.plugin});

  @override
  State<_AIPlaylistSettings> createState() => _AIPlaylistSettingsState();
}

class _AIPlaylistSettingsState extends State<_AIPlaylistSettings> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  final _promptController = TextEditingController();
  final _searchController = TextEditingController();

  bool _generating = false;
  List<BaseTrack> _results = const [];

  bool _searching = false;
  List<BaseTrack> _searchResults = const [];

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.plugin.apiKey);
    _modelController = TextEditingController(text: widget.plugin.model);
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    _promptController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final prompt = _promptController.text;
    if (prompt.trim().isEmpty) return;
    await widget.plugin.setApiKey(_apiKeyController.text);
    await widget.plugin.setModel(_modelController.text);

    final pluginContext = widget.plugin.context;
    if (pluginContext == null) return;
    setState(() => _generating = true);
    final library = await pluginContext.loadLibraryTracks();
    final results =
        await widget.plugin.buildPlaylistFromPrompt(prompt, library);
    if (!mounted) return;
    setState(() {
      _results = results;
      _generating = false;
    });
  }

  Future<void> _play() async {
    final pluginContext = widget.plugin.context;
    if (pluginContext == null || _results.isEmpty) return;
    await pluginContext.setQueue(_results, startIndex: 0);
    await pluginContext.play();
  }

  /// Item 43's "natural language search" gap — a separate action/result
  /// set from [_generate]/[_results]: a search finds matches, it doesn't
  /// build a curated listening order, so it gets its own "Play" (queues
  /// whatever matched, in whatever order the model returned) rather
  /// than being folded into the playlist-generation flow above.
  Future<void> _search() async {
    final query = _searchController.text;
    if (query.trim().isEmpty) return;
    await widget.plugin.setApiKey(_apiKeyController.text);
    await widget.plugin.setModel(_modelController.text);

    final pluginContext = widget.plugin.context;
    if (pluginContext == null) return;
    setState(() => _searching = true);
    final library = await pluginContext.loadLibraryTracks();
    final results = await widget.plugin.searchLibrary(query, library);
    if (!mounted) return;
    setState(() {
      _searchResults = results;
      _searching = false;
    });
  }

  Future<void> _playSearchResults() async {
    final pluginContext = widget.plugin.context;
    if (pluginContext == null || _searchResults.isEmpty) return;
    await pluginContext.setQueue(_searchResults, startIndex: 0);
    await pluginContext.play();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Needs your own Anthropic API key — console.anthropic.com. '
          'Never required for normal use of Omnis.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKeyController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Anthropic API key',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.memory_outlined),
          ),
        ),
        const SizedBox(height: 20),
        Text('Describe a playlist', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _promptController,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'e.g. "a two-hour workout playlist"',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.auto_awesome_outlined),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _generating ? null : _generate,
          icon: _generating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: Text(_generating ? 'Thinking…' : 'Generate'),
        ),
        if (plugin.lastError != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastError!,
              style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_results.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Text('${_results.length} track(s)',
                  style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: _play,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              ),
            ],
          ),
          for (final track in _results)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: Text(track.title),
              subtitle: Text(track.artists.join(', ')),
            ),
        ],
        const SizedBox(height: 20),
        Text('Search your library', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Describe what you\'re looking for — mood, genre, era, tempo, '
          'not just exact title/artist text.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'e.g. "upbeat 90s songs I haven\'t played in a while"',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _searching ? null : _search,
          icon: _searching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search),
          label: Text(_searching ? 'Searching…' : 'Search'),
        ),
        if (_searchResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Text('${_searchResults.length} match(es)',
                  style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: _playSearchResults,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play'),
              ),
            ],
          ),
          for (final track in _searchResults)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.music_note),
              title: Text(track.title),
              subtitle: Text(track.artists.join(', ')),
            ),
        ],
      ],
    );
  }
}
