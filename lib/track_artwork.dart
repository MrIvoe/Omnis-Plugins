import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/tag_editor_plugin.dart';

/// Resolves and caches real artwork bytes for a track, regardless of
/// where they actually live: the Android MediaStore (`coverArt` holds a
/// `mediastore://<id>` marker written by `MediaScanner`) or an embedded
/// ID3 picture frame on desktop (read straight from `track.localPath` via
/// [TagEditorPlugin]).
///
/// A duplicate of the Omnis app's own `lib/ui/widgets/track_artwork.dart`
/// — not a move, since a dozen other app-side pages/widgets still use
/// that original directly and can't reach into `omnis_plugins`. This
/// copy exists purely so `HomeDashboardPlugin`'s extracted
/// `HomeDashboardPage` (which can no longer import anything under
/// `package:omnis/`) keeps rendering real album art exactly as it did
/// before the extraction, instead of degrading to a permanent
/// placeholder icon.
///
/// Every lookup is cached in memory by track id — [TrackArtwork] rebuilds
/// on every position tick in Now Playing, and without this a file would be
/// re-read (or the platform channel re-queried) many times a second.
/// Nothing here is persisted to disk or to `BaseTrack`/`LibraryStore`:
/// decoded picture bytes are exactly the kind of data that would bloat the
/// library JSON for no benefit, so they're only ever held for what's
/// actually been asked for on screen.
class ArtworkProvider {
  ArtworkProvider._();

  static final Map<String, Future<Uint8List?>> _cache = {};
  static final OnAudioQuery _audioQuery = OnAudioQuery();

  static Future<Uint8List?> forTrack(BaseTrack track) {
    return _cache.putIfAbsent(track.id, () => _load(track));
  }

  /// Drop a track's cached artwork — call after writing new artwork via
  /// the tag editor so the next lookup reflects the change instead of the
  /// stale cached bytes (or cached "no artwork").
  static void invalidate(String trackId) => _cache.remove(trackId);

  static Future<Uint8List?> _load(BaseTrack track) async {
    final cover = track.coverArt;
    if (!kIsWeb &&
        Platform.isAndroid &&
        cover != null &&
        cover.startsWith('mediastore://')) {
      final id = int.tryParse(cover.substring('mediastore://'.length));
      if (id == null) return null;
      try {
        return await _audioQuery.queryArtwork(
          id,
          ArtworkType.AUDIO,
          format: ArtworkFormat.JPEG,
          size: 400,
        );
      } catch (_) {
        return null;
      }
    }

    final path = track.localPath;
    if (path != null && path.isNotEmpty) {
      final tags = await TagEditorPlugin().readTags(path);
      return tags.artwork;
    }
    return null;
  }
}

/// Renders a track's real album art, falling back to a generic music-note
/// icon while it loads or when none is embedded — never a permanent blank
/// box the way the old placeholder-only widget was.
class TrackArtwork extends StatelessWidget {
  final BaseTrack track;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final double iconSize;
  final Color? backgroundColor;

  const TrackArtwork({
    super.key,
    required this.track,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.iconSize = 32,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = FutureBuilder<Uint8List?>(
      future: ArtworkProvider.forTrack(track),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            bytes,
            width: width,
            height: height,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => _placeholder(theme),
          );
        }
        return _placeholder(theme);
      },
    );

    if (borderRadius == null) return child;
    return ClipRRect(borderRadius: borderRadius!, child: child);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      width: width,
      height: height,
      color: backgroundColor ?? theme.colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(Icons.music_note,
          size: iconSize, color: theme.colorScheme.onPrimaryContainer),
    );
  }
}
