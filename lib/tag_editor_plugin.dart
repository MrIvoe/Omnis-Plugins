import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:id3_codec/id3_codec.dart';
import 'package:id3_codec/id3_constant.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/track_tags.dart';
import 'package:permission_handler/permission_handler.dart';

/// Reads and writes ID3 tags — every standard frame on read, the four
/// most structurally-supported ones (title/artist/album/artwork) as real
/// native ID3v2.3 frames on write, everything else as custom `TXXX`
/// frames.
///
/// ### Why the write side is split like that
///
/// The only maintained pure-Dart (no native build, works identically on
/// every platform) ID3 read/write library found, `id3_codec`, reads the
/// full standard ID3v2.2/2.3/2.4 frame set but only *writes*
/// title/artist/album/artwork as their real named frames — everything
/// else has to go through its `userDefines` (custom `TXXX`) mechanism.
/// Hand-writing the missing native frames (TCON, TYER, TRCK, TBPM, ...)
/// directly at the byte level was considered and rejected: it would mean
/// binary ID3 frame construction this project cannot verify against real
/// third-party players, with file corruption as the failure mode if a
/// size or encoding byte were wrong. Custom `TXXX` frames are the
/// library's own supported, exercised write path, so anything written
/// through it is only as risky as using the library normally — verified
/// safe via `test/id3_codec_safety_test.dart` and this plugin's own
/// round-trip tests, not merely assumed.
///
/// ### Three real bugs/gaps in id3_codec worked around here
///
/// 1. Its "no existing tag" write path throws on a file with no ID3v2
///    header at all (a fixed-length `List` where the package needs a
///    growable one) — [_ensureId3v2Header] guarantees a header is always
///    present before encoding, so only the library's "edit existing tag"
///    path (which doesn't have this bug) is ever used.
/// 2. `File.readAsBytes()` returns a fixed-length `Uint8List`, and the
///    encoder mutates its input in place — [_readGrowableBytes] converts
///    to a growable `List<int>` first.
/// 3. `ID3MetataInfo.toTagMap()`'s APIC (artwork) entry is decorative
///    only — the package's own `_APICDecoder` computes the picture's
///    base64 and then discards it, replacing it with the literal string
///    `'<Has Picture Data>'` (confirmed by reading
///    `content_decoder.dart`, not assumed). There is no way to retrieve
///    real artwork bytes through the package's public decode API. This
///    plugin's own [_extractEmbeddedArtwork] parses the APIC frame
///    directly from the raw tag bytes instead — read-only, so the
///    failure mode of a parsing mistake is "no artwork found," never
///    file corruption, unlike the write-side frame construction that was
///    ruled out above. Verified via a real round-trip test that writes
///    artwork through id3_codec's (trustworthy) encoder and confirms
///    this extractor reads back the exact original bytes.
class TagEditorPlugin extends MusicPlugin implements IFileTagWriter, ITagWriter {
  static const _autoTaggedTrackIdsKey = 'auto_tagged_track_ids';

  /// Item 17's "no undo/backup/restore for tag edits" gap — a bad batch
  /// auto-tag/re-tag run (`library_page.dart`'s bulk actions) was
  /// previously unrecoverable. Persists, per file path, the tag field
  /// values as they stood *immediately before* [writeTags]'s most recent
  /// call for that file — a small JSON blob of strings, not a full-file
  /// byte backup: a whole-file copy per edited track would scale with
  /// library size (potentially thousands of multi-megabyte files in one
  /// batch run) the way [PluginInstaller.backupPluginDirectory] can
  /// afford to for a single plugin directory but this genuinely can't
  /// for a library-wide operation. Deliberately holds only the *most
  /// recent* snapshot per file, not a full history — undoing twice in a
  /// row restores to the state one edit before the last undo, not an
  /// arbitrary number of steps back, matching the "undo last edit," not
  /// "full version history," scope this item actually asks for.
  static const _undoSnapshotsKey = 'tag_edit_undo_snapshots';

  Map<String, Map<String, String?>> _loadUndoSnapshots() {
    final raw = storage.getString(_undoSnapshotsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final snapshots = <String, Map<String, String?>>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! Map) continue;
        snapshots[key] = value.map((k, v) => MapEntry(k.toString(), v?.toString()));
      }
      return snapshots;
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistUndoSnapshots(
          Map<String, Map<String, String?>> snapshots) =>
      storage.setString(_undoSnapshotsKey, jsonEncode(snapshots));

  Map<String, String?> _fieldsOf(TrackTags tags) => {
        'title': tags.title,
        'artist': tags.artist,
        'album': tags.album,
        'albumArtist': tags.albumArtist,
        'genre': tags.genre,
        'year': tags.year,
        'track': tags.track,
        'disc': tags.disc,
        'composer': tags.composer,
        'comment': tags.comment,
        'bpm': tags.bpm,
        'initialKey': tags.initialKey,
        'mood': tags.mood,
      };

  /// Whether [filePath] has an undo snapshot available right now — the
  /// UI uses this to enable/disable an "Undo last edit" action.
  bool hasUndoSnapshot(String filePath) =>
      _loadUndoSnapshots().containsKey(filePath);

  /// Restores [filePath]'s tags to what they were immediately before its
  /// most recent [writeTags] call. Returns `false` (a no-op) when there
  /// is no snapshot for this file — nothing has been written to it since
  /// this plugin last started, or a later real write has already
  /// superseded it. Native title/artist/album fall back to an empty
  /// string, not `null`, when the snapshot recorded no prior value —
  /// unlike a `null` custom field (`writeTags` skips a `TXXX` frame
  /// entirely when given `null`, correctly leaving an untouched one
  /// alone), title/artist/album are *always* written through to the
  /// encoder every call, so an empty string is what genuinely clears the
  /// frame back to "the edit that added a title/artist/album where none
  /// existed before" being fully undone, not left half-reverted.
  ///
  /// Deliberately does **not** clear its own restored state's snapshot
  /// afterward: the [writeTags] call this makes is a real write like any
  /// other, so it naturally creates a fresh snapshot of whatever was on
  /// disk *before* the undo (the just-undone edit) — leaving that in
  /// place is what makes calling [undoLastEdit] a second time toggle
  /// back to the edit rather than becoming a permanent dead end.
  Future<bool> undoLastEdit(String filePath) async {
    final snapshot = _loadUndoSnapshots()[filePath];
    if (snapshot == null) return false;
    return writeTags(
      filePath,
      title: snapshot['title'] ?? '',
      artist: snapshot['artist'] ?? '',
      album: snapshot['album'] ?? '',
      albumArtist: snapshot['albumArtist'],
      genre: snapshot['genre'],
      year: snapshot['year'],
      track: snapshot['track'],
      disc: snapshot['disc'],
      composer: snapshot['composer'],
      comment: snapshot['comment'],
      bpm: snapshot['bpm'],
      initialKey: snapshot['initialKey'],
      mood: snapshot['mood'],
    );
  }

  /// [IFileTagWriter.writeLyrics] — writes [lyrics] as a `TXXX:LYRICS`
  /// custom frame, same mechanism [writeTags]'s `extraFields` uses for
  /// anything id3_codec can't write as a native frame. Used by
  /// `LyricsPlugin`'s "write to file metadata" setting for auto-fetched
  /// lyrics — looked up through this interface, not a concrete
  /// `TagEditorPlugin` dependency.
  @override
  Future<bool> writeLyrics(String filePath, String lyrics) =>
      writeTags(filePath, extraFields: {CustomTagKeys.lyrics: lyrics});

  /// Read every recognised ID3 frame from a local file. Never throws —
  /// an unreadable or untagged file returns [TrackTags.isEmpty].
  ///
  /// [includeArtwork] defaults to `true`; pass `false` for bulk/scan
  /// callers (e.g. `MediaScanner`) that need text fields for many files
  /// quickly and don't want to hold decoded picture bytes for every track
  /// in memory — artwork is read lazily and cached per-file by
  /// `TrackArtwork` instead, only for what's actually visible on screen.
  Future<TrackTags> readTags(String filePath, {bool includeArtwork = true}) async {
    try {
      final bytes = await File(filePath).readAsBytes();
      return _tagsFromBytes(bytes, includeArtwork: includeArtwork);
    } catch (_) {
      return const TrackTags([]);
    }
  }

  TrackTags _tagsFromBytes(List<int> bytes, {bool includeArtwork = true}) {
    if (bytes.isEmpty) return const TrackTags([]);
    final frames = <TagFrame>[];

    try {
      final metadatas = ID3Decoder(bytes).decodeSync();
      for (final metadata in metadatas) {
        final map = metadata.toTagMap();
        final rawFrames = map['Frames'];
        if (rawFrames is! List) continue;
        for (final raw in rawFrames) {
          if (raw is! Map) continue;
          final id = raw['Frame ID']?.toString();
          if (id == null || id == 'APIC') continue; // real bytes below
          final content = raw['Content'];
          if (content is! Map) continue;
          final parsed = _parseFrame(id, content);
          if (parsed != null) frames.add(parsed);
        }
      }
    } catch (_) {
      // A text-frame decode failure shouldn't also suppress artwork —
      // fall through and still attempt the artwork extraction below.
    }

    if (includeArtwork) {
      final artwork = _extractEmbeddedArtwork(bytes);
      if (artwork != null) {
        frames.add(TagFrame(id: 'APIC', label: 'Artwork', artworkBytes: artwork));
      }
    }

    return TrackTags(frames);
  }

  TagFrame? _parseFrame(String id, Map content) {
    if (id == 'TXXX') {
      final desc = content['Description']?.toString();
      final value = content['Information'] ?? content['Value'];
      if (desc == null || value == null) return null;
      return TagFrame(id: 'TXXX:$desc', label: desc, value: value.toString());
    }

    final info = content['Information'] ?? content['Text'];
    if (info != null) {
      return TagFrame(id: id, label: frameV2p3Map[id] ?? id, value: info.toString());
    }
    // A frame type this plugin doesn't have a specific unwrap rule for
    // (e.g. COMM's structure differs slightly) — show *something* rather
    // than silently omitting a frame the user can see exists.
    return TagFrame(id: id, label: frameV2p3Map[id] ?? id, value: content.toString());
  }

  /// Whether this plugin can currently write to an arbitrary file path on
  /// Android. Scoped storage (Android 10+) blocks a raw file write to a
  /// path the app didn't create itself unless "All files access"
  /// (`MANAGE_EXTERNAL_STORAGE`) is granted — checks the already-granted
  /// case cheaply first (a plain `permission_handler` status check, no
  /// `context` needed), only routing to the system Settings screen (via
  /// `context.requestStorageWritePermission()`) if it isn't. This is the
  /// concrete, most likely reason a tag/lyrics write can silently fail on
  /// a real device with no in-app explanation.
  Future<bool> _hasWritePermission() async {
    try {
      final status = await Permission.manageExternalStorage.status;
      if (status.isGranted) return true;
    } catch (_) {
      // Permission doesn't exist on this Android version (pre-scoped
      // storage) — plain filesystem writes already work there.
      return true;
    }
    return await context?.requestStorageWritePermission() ?? false;
  }

  /// Write tags to a local file. Only the fields you pass are touched —
  /// everything else already in the file (including frames this plugin
  /// can't write natively) is left exactly as-is, verified by
  /// `test/id3_codec_safety_test.dart`.
  ///
  /// Title/artist/album/artwork are written as real native ID3v2.3
  /// frames; every other named field here is written as a custom `TXXX`
  /// frame under its [CustomTagKeys] name (see class doc for why) — the
  /// same constant [TrackTags]'s getters check on read, so this always
  /// round-trips through Omnis regardless of the native-frame limitation.
  /// `extraFields` is the escape hatch for anything with no dedicated
  /// parameter; its keys go straight into `TXXX:<key>` and are readable
  /// back via `TagFrame.id` in [readTags]'s flattened list.
  ///
  /// Returns `true` on success. Never throws — a failure (unreadable
  /// file, unwritable path, permission denied) returns `false`.
  Future<bool> writeTags(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? genre,
    String? year,
    String? track,
    String? disc,
    String? composer,
    String? comment,
    String? bpm,
    String? initialKey,
    String? mood,
    Uint8List? artworkBytes,
    Map<String, String>? extraFields,
  }) async {
    try {
      if (!kIsWeb && Platform.isAndroid && !await _hasWritePermission()) {
        return false;
      }
      final file = File(filePath);
      final original = await _readGrowableBytes(file);
      final seeded = _ensureId3v2Header(original);

      final userDefines = <String, String>{
        ...?extraFields,
        if (albumArtist != null) CustomTagKeys.albumArtist: albumArtist,
        if (genre != null) CustomTagKeys.genre: genre,
        if (year != null) CustomTagKeys.year: year,
        if (track != null) CustomTagKeys.track: track,
        if (disc != null) CustomTagKeys.disc: disc,
        if (composer != null) CustomTagKeys.composer: composer,
        if (comment != null) CustomTagKeys.comment: comment,
        if (bpm != null) CustomTagKeys.bpm: bpm,
        if (initialKey != null) CustomTagKeys.initialKey: initialKey,
        if (mood != null) CustomTagKeys.mood: mood,
      };

      final updated = ID3Encoder(seeded).encodeSync(MetadataV2p3Body(
        title: title,
        artist: artist,
        album: album,
        imageBytes: artworkBytes,
        userDefines: userDefines.isEmpty ? null : userDefines,
      ));

      await file.writeAsBytes(updated, flush: true);

      // Snapshot the *pre-write* tags for undoLastEdit, decoded from
      // `original` (already in memory, no second disk read needed) —
      // only recorded once the write has actually succeeded, so a
      // failed write never leaves a stale/misleading undo point behind.
      final beforeTags = _tagsFromBytes(original, includeArtwork: false);
      final snapshots = _loadUndoSnapshots();
      snapshots[filePath] = _fieldsOf(beforeTags);
      await _persistUndoSnapshots(snapshots);

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> _readGrowableBytes(File file) async {
    final bytes = await file.readAsBytes();
    // Uint8List (what readAsBytes returns) is fixed-length; id3_codec
    // mutates its input as it resizes the tag and throws on a
    // fixed-length list. See test/id3_codec_safety_test.dart.
    return bytes.toList(growable: true);
  }

  /// Guarantees the byte list starts with at least a minimal, valid,
  /// empty ID3v2.3 header, so id3_codec's buggy "create a tag from
  /// nothing" path is never exercised — see class doc.
  List<int> _ensureId3v2Header(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return bytes;
    }
    return <int>[
      0x49, 0x44, 0x33, // 'ID3'
      0x03, 0x00, // version 2.3.0
      0x00, // flags
      0x00, 0x00, 0x00, 0x00, // size = 0 (synchsafe), grown on encode
      ...bytes,
    ];
  }

  /// Reads the raw APIC (attached picture) frame straight out of the
  /// ID3v2 tag bytes, bypassing `toTagMap()`'s lossy decode entirely (see
  /// class doc, point 3). Read-only and defensive throughout: any
  /// malformed or unsupported structure returns `null` rather than
  /// throwing or returning wrong bytes. Deliberately does not attempt to
  /// handle the "unsynchronisation" tag flag (rare in practice for files
  /// written by modern taggers) — a tag using it fails closed to `null`
  /// here rather than risk misinterpreting byte-stuffed content as image
  /// data.
  Uint8List? _extractEmbeddedArtwork(List<int> bytes) {
    try {
      if (bytes.length < 10 ||
          bytes[0] != 0x49 ||
          bytes[1] != 0x44 ||
          bytes[2] != 0x33) {
        return null; // no 'ID3' header
      }
      final major = bytes[3];
      if (major != 3 && major != 4) return null; // only v2.3/v2.4 handled
      final flags = bytes[5];
      final unsynchronised = (flags & 0x80) != 0;
      if (unsynchronised) return null;
      final hasExtendedHeader = (flags & 0x40) != 0;

      final tagSize = ByteUtil.calH0Size(bytes.sublist(6, 10));
      var pos = 10;
      final tagEnd = (10 + tagSize).clamp(0, bytes.length);

      if (hasExtendedHeader) {
        if (pos + 4 > tagEnd) return null;
        // Treat the extended header size as this version's normal frame
        // size encoding and skip past it; malformed input safely falls
        // through to "no frame ID matched" below rather than misreading
        // frame data as more header.
        final extSize = major == 4
            ? ByteUtil.calH0Size(bytes.sublist(pos, pos + 4))
            : ByteUtil.calH1Size(bytes.sublist(pos, pos + 4));
        pos += 4 + extSize;
      }

      while (pos + 10 <= tagEnd) {
        final frameId = _asciiFrameId(bytes, pos);
        if (frameId == null) break; // padding or corrupt — stop safely
        final sizeBytes = bytes.sublist(pos + 4, pos + 8);
        final frameSize = major == 4
            ? ByteUtil.calH0Size(sizeBytes)
            : ByteUtil.calH1Size(sizeBytes);
        final payloadStart = pos + 10;
        final payloadEnd = payloadStart + frameSize;
        if (frameSize < 0 || payloadEnd > tagEnd) break;

        if (frameId == 'APIC') {
          return _parseApicPayload(bytes.sublist(payloadStart, payloadEnd));
        }
        pos = payloadEnd;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Reads a 4-byte frame id as ASCII, or `null` if it doesn't look like
  /// one (padding is zero-filled; a real frame id is 4 uppercase
  /// letters/digits).
  String? _asciiFrameId(List<int> bytes, int start) {
    if (start + 4 > bytes.length) return null;
    final chars = <int>[];
    for (var i = start; i < start + 4; i++) {
      final b = bytes[i];
      final isValid =
          (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39); // A-Z, 0-9
      if (!isValid) return null;
      chars.add(b);
    }
    return String.fromCharCodes(chars);
  }

  /// Parses an APIC frame's payload per the ID3v2.3/2.4 spec:
  /// `encoding(1) + MIME + \0 + pictureType(1) + description + terminator
  /// + pictureData`. The MIME string is always single-null-terminated
  /// regardless of the encoding byte; the description's terminator is
  /// double-null only for the UTF-16 encodings.
  Uint8List? _parseApicPayload(List<int> payload) {
    if (payload.isEmpty) return null;
    final encoding = payload[0];
    var i = 1;

    final mimeEnd = _indexOfTerminator(payload, i, wide: false);
    if (mimeEnd == null) return null;
    i = mimeEnd + 1;

    if (i >= payload.length) return null;
    i += 1; // picture type byte

    final wide = encoding == 0x01 || encoding == 0x02;
    final descEnd = _indexOfTerminator(payload, i, wide: wide);
    if (descEnd == null) return null;
    i = wide ? descEnd + 2 : descEnd + 1;

    if (i > payload.length) return null;
    final data = payload.sublist(i);
    return data.isEmpty ? null : Uint8List.fromList(data);
  }

  /// Index of the first null terminator (single 0x00, or the first byte
  /// of an aligned 0x00 0x00 pair when [wide]) at or after [start].
  int? _indexOfTerminator(List<int> bytes, int start, {required bool wide}) {
    if (!wide) {
      for (var i = start; i < bytes.length; i++) {
        if (bytes[i] == 0x00) return i;
      }
      return null;
    }
    for (var i = start; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0x00 && bytes[i + 1] == 0x00) return i;
    }
    return null;
  }

  // --- Smart re-tag tracking ---
  //
  // "Automatic" tagging (Library → Analyze/tag whole library) must not
  // silently redo work on every pass — a track already auto-tagged is
  // skipped unless the user explicitly asks to redo it. Persisted via
  // this plugin's own storage (plugin-private state), not a shared
  // app-settings singleton.

  Set<String> _readAutoTaggedIds() =>
      (storage.getStringList(_autoTaggedTrackIdsKey) ?? const <String>[])
          .toSet();

  bool wasAutoTagged(String trackId) =>
      _readAutoTaggedIds().contains(trackId);

  Future<void> markAutoTagged(String trackId) async {
    final ids = _readAutoTaggedIds();
    if (ids.add(trackId)) {
      await storage.setStringList(_autoTaggedTrackIdsKey, ids.toList());
    }
  }

  /// Forget that a track was auto-tagged, so the next automatic pass
  /// processes it again — the "unless asked" escape hatch.
  Future<void> clearAutoTagged(String trackId) async {
    final ids = _readAutoTaggedIds();
    if (ids.remove(trackId)) {
      await storage.setStringList(_autoTaggedTrackIdsKey, ids.toList());
    }
  }

  Future<void> clearAllAutoTagged() =>
      storage.setStringList(_autoTaggedTrackIdsKey, const []);

  // --- Artist/title cleanup ---
  //
  // User-configurable: some libraries carry a featured artist baked into
  // the artist field ("Artist1 feat. Artist2") or, worse, into the title
  // field ("Song Title (feat. Artist2)") instead of as a separate artist.
  // [artistSeparators] is user-editable (via this plugin's own settings,
  // tap it in the Plugins list) so this isn't a fixed guess at every
  // naming convention in the wild.

  static const _artistSeparatorsStorageKey = 'artist_separators';
  static const _defaultArtistSeparators = [
    'feat.',
    'feat',
    'ft.',
    'ft',
    'featuring',
  ];

  /// User-editable list of separators that mark a featured artist inside
  /// an artist or title field (`"Artist1 feat. Artist2"`,
  /// `"Song (ft. Artist2)"`). Order matters: the first match wins, so put
  /// more specific separators first if they overlap.
  List<String> get artistSeparators =>
      storage.getStringList(_artistSeparatorsStorageKey) ??
      _defaultArtistSeparators;

  Future<void> setArtistSeparators(List<String> separators) => storage
      .setStringList(_artistSeparatorsStorageKey, separators);

  /// Splits a raw artist string on the first separator found, returning
  /// every segment trimmed and with empties dropped. `"Artist1 ft.
  /// Artist2"` → `['Artist1', 'Artist2']`. Returns `[raw]` unchanged when
  /// no separator matches — this never *removes* information, only
  /// restructures it. Critically, "unchanged" means exactly that: a plain
  /// multi-word name with no separator (`"Solo Artist"`) must come back
  /// as one element, not word-split — the final `.split(' ')` below only
  /// runs when a separator's replacement actually introduced the spaces
  /// being split on, tracked via [matched].
  List<String> splitArtists(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    final separators = artistSeparators;
    var working = trimmed;
    var matched = false;
    for (final sep in separators) {
      if (sep.isEmpty) continue;
      final pattern = RegExp(RegExp.escape(sep), caseSensitive: false);
      if (pattern.hasMatch(working)) {
        matched = true;
        working = working.replaceAll(pattern, ' ');
      }
    }
    if (!matched) return [trimmed];
    return working
        .split(' ')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Detects a featured-artist suffix living inside a *title* (a common
  /// tagging mistake — `"Song (feat. Artist2)"`) and separates it out.
  /// Returns the cleaned title and the extracted artist name, or the
  /// title unchanged and `null` when no separator matches.
  ({String title, String? featuredArtist}) extractFeaturedArtistFromTitle(
    String rawTitle,
  ) {
    final separators = artistSeparators;
    for (final sep in separators) {
      if (sep.isEmpty) continue;
      // Matches "... (feat. X)", "... [ft. X]", or a bare "... feat. X"
      // tail, so this works whether or not the source wrapped it in
      // brackets.
      final pattern = RegExp(
        r'[\(\[]?\s*' + RegExp.escape(sep) + r'\s*([^)\]]+)[\)\]]?\s*$',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(rawTitle);
      if (match != null) {
        final featured = match.group(1)?.trim();
        final cleaned = rawTitle.substring(0, match.start).trim();
        if (featured != null && featured.isNotEmpty && cleaned.isNotEmpty) {
          return (title: cleaned, featuredArtist: featured);
        }
      }
    }
    return (title: rawTitle, featuredArtist: null);
  }

  /// Applies [splitArtists]/[extractFeaturedArtistFromTitle] to a track
  /// and returns the cleaned-up field values, or `null` if nothing would
  /// change. Pure — does not touch the file or `_tracks`; the caller
  /// (Library page) decides whether/how to apply and persist the result.
  ({String title, List<String> artists})? cleanArtistFields(BaseTrack track) {
    var title = track.title;
    final artists = <String>{...track.artists};
    var changed = false;

    final extracted = extractFeaturedArtistFromTitle(title);
    if (extracted.featuredArtist != null) {
      title = extracted.title;
      if (artists.add(extracted.featuredArtist!)) changed = true;
      changed = true;
    }

    if (track.artists.length == 1) {
      final split = splitArtists(track.artists.first);
      if (split.length > 1) {
        artists
          ..clear()
          ..addAll(split);
        changed = true;
      }
    }

    if (!changed) return null;
    return (title: title, artists: artists.toList());
  }

  @override
  String get id => 'tag_editor';

  @override
  String get name => 'Tag Editor';

  @override
  String get description =>
      'Read and edit ID3 tags — every standard frame, plus custom fields.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IFileTagWriter, this);
    context?.services.register(ITagWriter, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _TagEditorSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    context?.services.register(IFileTagWriter, this);
    context?.services.register(ITagWriter, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IFileTagWriter, this);
    context?.services.unregister(ITagWriter, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IFileTagWriter, this);
    context?.services.unregister(ITagWriter, this);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. Previously `_ArtistSeparatorsSection` lived directly in
/// `settings_page.dart`; a fixed guess at every featured-artist
/// convention in the wild would inevitably miss someone's library, so
/// this stays user-editable, just owned by the plugin now instead of the
/// Core Settings page.
class _TagEditorSettings extends StatefulWidget {
  final TagEditorPlugin plugin;

  const _TagEditorSettings({required this.plugin});

  @override
  State<_TagEditorSettings> createState() => _TagEditorSettingsState();
}

class _TagEditorSettingsState extends State<_TagEditorSettings> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    final current = widget.plugin.artistSeparators;
    if (current.contains(value)) {
      _controller.clear();
      return;
    }
    await widget.plugin.setArtistSeparators([...current, value]);
    _controller.clear();
    if (mounted) setState(() {});
  }

  Future<void> _remove(String separator) async {
    final current = widget.plugin.artistSeparators;
    await widget.plugin
        .setArtistSeparators(current.where((s) => s != separator).toList());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final separators = widget.plugin.artistSeparators;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Featured-artist separators',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final separator in separators)
              Chip(
                label: Text(separator),
                onDeleted: () => _remove(separator),
              ),
            if (separators.isEmpty)
              const Text('No separators configured — featured-artist '
                  'splitting is off.'),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: 'Add a separator',
                  hintText: 'e.g. "feat.", "ft.", "x", "with"',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _add, child: const Text('Add')),
          ],
        ),
      ],
    );
  }
}
