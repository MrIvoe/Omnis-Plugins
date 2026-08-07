import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

class LyricLine {
  const LyricLine({required this.timestamp, required this.text});

  final Duration timestamp;
  final String text;
}

/// Where auto-fetched lyrics come from. Deliberately an enum with one
/// real entry today rather than a free-text field or a `ServiceRegistry`
/// interface: lyrics sources are a closed, curated set a user picks
/// *between*, not something a third-party plugin would want to add its
/// own implementation of the way `IQueueBuilder`/`IMetadataProvider` are.
/// Adding a second source means adding an enum value and a fetch
/// function, both in this file — see [LyricsPlugin._fetchFromLrclib] for
/// the shape a new one would follow.
enum LyricsSource {
  /// lrclib.net — free, keyless, open-source, purpose-built for
  /// time-synced lyrics. The only implemented source today.
  lrclib('LRCLIB (free, no key required)');

  final String label;
  const LyricsSource(this.label);
}

/// Result of a lyrics lookup — a track can have plain lyrics, time-synced
/// lyrics, both, or (a track lrclib knows is instrumental) neither.
class LyricsFetchResult {
  final String? plainLyrics;
  final List<LyricLine> syncedLyrics;
  final bool instrumental;

  const LyricsFetchResult({
    this.plainLyrics,
    this.syncedLyrics = const [],
    this.instrumental = false,
  });

  bool get isEmpty =>
      !instrumental &&
      (plainLyrics == null || plainLyrics!.trim().isEmpty) &&
      syncedLyrics.isEmpty;
}

/// Parses LRC-format synced lyrics (`[mm:ss.xx]text` per line, optionally
/// several timestamps on one line) into [LyricLine]s. Metadata lines
/// (`[ar:Artist]`, `[ti:Title]`, ...) don't match the digit-timestamp
/// pattern and are silently skipped, not misparsed.
List<LyricLine> parseLrc(String lrc) {
  final pattern = RegExp(r'\[(\d{2}):(\d{2})(?:\.(\d{1,3}))?\]');
  final lines = <LyricLine>[];
  for (final rawLine in lrc.split('\n')) {
    final matches = pattern.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;
    final text = rawLine.substring(matches.last.end).trim();
    if (text.isEmpty) continue;
    for (final m in matches) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final fraction = m.group(3);
      final millis = fraction == null ? 0 : int.parse(fraction.padRight(3, '0'));
      lines.add(LyricLine(
        timestamp:
            Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
        text: text,
      ));
    }
  }
  lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return lines;
}

/// A bundled lyrics plugin that stores simple or timed lyric lines per
/// track ID.
///
/// Plain lyrics persist via this plugin's own [MusicPlugin.storage]
/// (plugin-private state — `storage` also works before this plugin is
/// attached to a `PluginManager`, unlike `context`, which keeps it usable
/// standalone in tests) and can be entered through [LyricEditDialog] —
/// previously nothing in the UI ever called [setLyric], so this plugin's
/// actual purpose (storing and showing lyrics) was unreachable by a user
/// no matter how the karaoke/lyrics settings were configured. Timed
/// lyrics ([setTimedLyric]) still have no entry UI — writing a
/// synced-lyric editor (per-line timestamps) is a separate, larger
/// feature — but [currentLyricFor] already uses them correctly whenever a
/// caller sets them programmatically.
///
/// Implements [ILyricsProvider] and registers itself under that interface
/// so the *display* path (Now Playing's lyrics panel) can ask for "the"
/// lyrics provider without knowing it's this plugin specifically — a
/// future alternate source (LRCLIB, embedded LRC) could register
/// alongside or instead of it. Editing lyrics is a capability specific to
/// this plugin's own storage format, not part of the generic interface,
/// so [LyricEditDialog] still takes the concrete `LyricsPlugin`.
class LyricsPlugin extends MusicPlugin implements ILyricsProvider {
  static const _autoFetchKey = 'auto_fetch_enabled';
  static const _writeToMetadataKey = 'write_to_metadata';
  static const _sourceKey = 'source';
  static const _storedLyricsKey = 'stored_lyrics';

  final Map<String, String> _lyrics = {};
  final Map<String, List<LyricLine>> _timedLyrics = {};
  final http.Client _client;

  /// Last fetch outcome, for the settings page's "Fetch now" feedback —
  /// not persisted, purely a this-session status message.
  String? lastFetchStatus;

  LyricsPlugin({http.Client? client}) : _client = client ?? http.Client();

  /// Automatically look up lyrics for a track when it starts playing, if
  /// nothing is stored for it yet. Off by default — an automatic network
  /// call on every track start is worth opting into, not assuming.
  bool get autoFetchEnabled => storage.getBool(_autoFetchKey) ?? false;

  Future<void> setAutoFetchEnabled(bool value) =>
      storage.setBool(_autoFetchKey, value);

  /// Whether a successful fetch also gets written into the track's own
  /// file tags (via `IFileTagWriter`, local files only) — so the lyrics
  /// travel with the file itself, readable by any other player, not just
  /// stored inside Omnis.
  bool get writeToMetadataEnabled => storage.getBool(_writeToMetadataKey) ?? false;

  Future<void> setWriteToMetadataEnabled(bool value) =>
      storage.setBool(_writeToMetadataKey, value);

  LyricsSource get source {
    final raw = storage.getString(_sourceKey);
    return LyricsSource.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => LyricsSource.lrclib,
    );
  }

  Future<void> setSource(LyricsSource value) =>
      storage.setString(_sourceKey, value.name);

  Map<String, String> _readStoredLyrics() {
    final raw = storage.getString(_storedLyricsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  /// Whether [track] already has lyrics stored (plain or timed) — the
  /// check auto-fetch uses so it never overwrites something already
  /// there, manually entered or previously fetched.
  bool hasLyrics(BaseTrack track) =>
      _lyrics.containsKey(track.id) || timedLyricFor(track).isNotEmpty;

  /// Looks up lyrics for [track] from [source] and stores whatever comes
  /// back (plain and/or synced). When [writeToMetadataEnabled] is on and
  /// the track has a local file, also embeds the plain lyrics into the
  /// file's own tags via `IFileTagWriter`. Never throws — a network
  /// failure, no-match, or instrumental track all resolve to a result
  /// with nothing in it, not an exception; [lastFetchStatus] carries a
  /// human-readable outcome either way.
  Future<LyricsFetchResult> fetchLyrics(BaseTrack track, {bool auto = false}) async {
    final result = await _fetchFromLrclib(track);

    if (result.instrumental) {
      lastFetchStatus = 'Marked instrumental — no lyrics to fetch.';
      return result;
    }
    if (result.isEmpty) {
      lastFetchStatus = auto
          ? null // stay quiet on a background miss — nothing to show
          : 'No lyrics found for this track.';
      return result;
    }

    if (result.syncedLyrics.isNotEmpty) {
      setTimedLyric(track.id, result.syncedLyrics);
    }
    if (result.plainLyrics != null && result.plainLyrics!.trim().isNotEmpty) {
      setLyric(track.id, result.plainLyrics!);
    }
    lastFetchStatus = 'Fetched lyrics from ${source.label}.';

    final path = track.localPath;
    if (writeToMetadataEnabled &&
        path != null &&
        path.isNotEmpty &&
        result.plainLyrics != null) {
      final writer = context?.services.get<IFileTagWriter>();
      final wrote = await writer?.writeLyrics(path, result.plainLyrics!);
      if (wrote == true) {
        lastFetchStatus = '${lastFetchStatus!} Written into the file\'s tags.';
      } else if (writer != null) {
        lastFetchStatus = '${lastFetchStatus!} Could not write into the file.';
      }
    }

    return result;
  }

  /// Queries lrclib.net: an exact match first (`/api/get`, needs
  /// track/artist/duration), falling back to a fuzzy search (`/api/search`)
  /// and taking its first result if the exact lookup 404s. Free, no API
  /// key — see docs/PLUGIN_GUIDE.md's testing section for why every
  /// network call in this codebase fails soft instead of throwing.
  Future<LyricsFetchResult> _fetchFromLrclib(BaseTrack track) async {
    final artist = track.artists.isNotEmpty ? track.artists.first : '';
    final title = track.title;
    if (artist.isEmpty || title.isEmpty) return const LyricsFetchResult();

    try {
      final exactUri = Uri.https('lrclib.net', '/api/get', {
        'track_name': title,
        'artist_name': artist,
        if (track.album.isNotEmpty) 'album_name': track.album,
        if (track.duration > 0) 'duration': '${track.duration}',
      });
      final exactResp =
          await _client.get(exactUri).timeout(const Duration(seconds: 8));
      if (exactResp.statusCode == 200) {
        final parsed = _parseLrclibEntry(jsonDecode(exactResp.body));
        if (parsed != null) return parsed;
      }

      final searchUri = Uri.https('lrclib.net', '/api/search', {
        'track_name': title,
        'artist_name': artist,
      });
      final searchResp =
          await _client.get(searchUri).timeout(const Duration(seconds: 8));
      if (searchResp.statusCode != 200) return const LyricsFetchResult();
      final results = jsonDecode(searchResp.body);
      if (results is! List || results.isEmpty) return const LyricsFetchResult();
      return _parseLrclibEntry(results.first) ?? const LyricsFetchResult();
    } catch (_) {
      return const LyricsFetchResult();
    }
  }

  LyricsFetchResult? _parseLrclibEntry(dynamic json) {
    if (json is! Map) return null;
    final instrumental = json['instrumental'] == true;
    final plain = json['plainLyrics']?.toString();
    final synced = json['syncedLyrics']?.toString();
    return LyricsFetchResult(
      instrumental: instrumental,
      plainLyrics: (plain != null && plain.isNotEmpty) ? plain : null,
      syncedLyrics: (synced != null && synced.isNotEmpty) ? parseLrc(synced) : const [],
    );
  }

  String? lyricFor(BaseTrack track) => _lyrics[track.id];

  List<LyricLine> timedLyricFor(BaseTrack track) {
    final lyrics = _timedLyrics[track.id];
    if (lyrics == null || lyrics.isEmpty) {
      return [];
    }
    return List.unmodifiable(lyrics);
  }

  void setLyric(String trackId, String lyric) {
    if (lyric.trim().isEmpty) {
      _lyrics.remove(trackId);
    } else {
      _lyrics[trackId] = lyric;
    }
    // ignore: unawaited_futures
    storage.setString(_storedLyricsKey, jsonEncode(_lyrics));
  }

  void setTimedLyric(String trackId, List<LyricLine> lyrics) {
    _timedLyrics[trackId] = List.unmodifiable(lyrics);
  }

  /// The line to show for [track] at [position]: the last timed line at or
  /// before it if timed lyrics exist, else the plain stored lyric, else a
  /// message saying there is nothing stored yet. Always non-null.
  @override
  String currentLyricFor(BaseTrack track, Duration position) {
    final timedLines = timedLyricFor(track);
    if (timedLines.isNotEmpty) {
      final match = timedLines.lastWhere(
        (line) => line.timestamp <= position,
        orElse: () => timedLines.first,
      );
      return match.text;
    }

    return lyricFor(track) ?? 'No lyrics added for this track yet.';
  }

  @override
  String get id => 'lyrics';

  @override
  String get name => 'Lyrics';

  @override
  String get description => 'Adds lightweight track-specific lyrics for the player screen.';

  @override
  String get version => '1.1.0';

  @override
  String get author => 'Omnis Team';

  @override
  bool get usesNetwork => true;

  @override
  Future<void> initialize() async {
    _lyrics
      ..clear()
      ..addAll(_readStoredLyrics());
    context?.services.register(ILyricsProvider, this);
  }

  @override
  Future<void> enable() async {
    context?.services.register(ILyricsProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(ILyricsProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {
    if (!autoFetchEnabled || hasLyrics(track)) return;
    await fetchLyrics(track, auto: true);
  }

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _LyricsSettings(plugin: this) : null;

  @override
  Future<void> dispose() async {
    context?.services.unregister(ILyricsProvider, this);
    _client.close();
  }
}

/// Dialog for adding or editing a track's plain-text lyrics.
class LyricEditDialog extends StatefulWidget {
  final LyricsPlugin plugin;
  final BaseTrack track;

  const LyricEditDialog({super.key, required this.plugin, required this.track});

  /// Show the dialog and save on confirm. Returns true if lyrics changed.
  static Future<bool> show(
    BuildContext context, {
    required LyricsPlugin plugin,
    required BaseTrack track,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => LyricEditDialog(plugin: plugin, track: track),
    );
    return result ?? false;
  }

  @override
  State<LyricEditDialog> createState() => _LyricEditDialogState();
}

class _LyricEditDialogState extends State<LyricEditDialog> {
  late final TextEditingController _controller;
  late bool _writeToFile;
  bool _saving = false;
  String? _error;

  bool get _hasLocalFile =>
      widget.track.localPath != null && widget.track.localPath!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.plugin.lyricFor(widget.track) ?? '',
    );
    // Defaults to this plugin's general "write to file tags" setting, but
    // stays editable per-save — someone might want this one track's
    // lyrics kept in-app only, or vice versa.
    _writeToFile = widget.plugin.writeToMetadataEnabled && _hasLocalFile;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    widget.plugin.setLyric(widget.track.id, _controller.text);

    if (_writeToFile && _hasLocalFile && _controller.text.trim().isNotEmpty) {
      final writer = widget.plugin.context?.services.get<IFileTagWriter>();
      if (writer == null) {
        // The Tag Editor plugin is what actually implements
        // IFileTagWriter — if it's disabled, writing into the file isn't
        // possible, but the in-app copy above still saved successfully.
        if (mounted) {
          setState(() {
            _saving = false;
            _error = 'Saved in Omnis, but couldn\'t write to the file — '
                'the Tag Editor plugin is disabled.';
          });
        }
        return;
      }
      final wrote = await writer.writeLyrics(widget.track.localPath!, _controller.text);
      if (!mounted) return;
      if (!wrote) {
        setState(() {
          _saving = false;
          _error = 'Saved in Omnis, but writing to the file failed — it '
              'may be read-only or the app may need storage permission.';
        });
        return;
      }
    }

    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Lyrics — ${widget.track.title}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              maxLines: 10,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: 'Paste or type the lyrics for this track…',
                border: OutlineInputBorder(),
              ),
            ),
            if (_hasLocalFile)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Also write into the file\'s own tags'),
                subtitle: const Text(
                    'So other players can read these lyrics too, not just Omnis'),
                value: _writeToFile,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _writeToFile = value ?? false),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'This track has no local file, so lyrics are only saved '
                  'in Omnis.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. Auto-fetch, source selection, and the write-to-file-tags option
/// all live here; editing a specific track's lyrics by hand stays on
/// [LyricEditDialog], reached from Now Playing, since that's a per-track
/// action, not a setting.
class _LyricsSettings extends StatefulWidget {
  final LyricsPlugin plugin;

  const _LyricsSettings({required this.plugin});

  @override
  State<_LyricsSettings> createState() => _LyricsSettingsState();
}

class _LyricsSettingsState extends State<_LyricsSettings> {
  bool _fetching = false;

  Future<void> _fetchNow() async {
    final track = widget.plugin.context?.currentTrack;
    if (track == null) {
      setState(() => widget.plugin.lastFetchStatus =
          'Nothing is playing right now.');
      return;
    }
    setState(() => _fetching = true);
    await widget.plugin.fetchLyrics(track);
    if (mounted) setState(() => _fetching = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-fetch lyrics'),
          subtitle: const Text(
              'Look up lyrics automatically when a track starts playing, '
              'if none are stored for it yet'),
          value: plugin.autoFetchEnabled,
          onChanged: (value) async {
            await plugin.setAutoFetchEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Write into file tags'),
          subtitle: const Text(
              'Also embed fetched lyrics into the track\'s own file '
              '(local files only), so they travel with it in other '
              'players too'),
          value: plugin.writeToMetadataEnabled,
          onChanged: (value) async {
            await plugin.setWriteToMetadataEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lyrics source'),
          trailing: DropdownButton<LyricsSource>(
            value: plugin.source,
            items: [
              for (final source in LyricsSource.values)
                DropdownMenuItem(value: source, child: Text(source.label)),
            ],
            onChanged: (value) async {
              if (value == null) return;
              await plugin.setSource(value);
              if (mounted) setState(() {});
            },
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _fetching ? null : _fetchNow,
              icon: _fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download),
              label: Text(_fetching ? 'Fetching…' : 'Fetch now'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Looks up the currently playing track',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        if (plugin.lastFetchStatus != null) ...[
          const SizedBox(height: 8),
          Text(plugin.lastFetchStatus!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}
