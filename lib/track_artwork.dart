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
/// — not a move. The app *can* already reach `omnis_plugins` (its own
/// `track_artwork.dart` even imports `package:omnis_plugins/
/// tag_editor_plugin.dart`), so that's not the reason; the real reason is
/// this plan's own Global Constraint deferring every cross-repo
/// `omnis_plugins` pin bump to Tier 2 task 6 — the app is pinned to
/// `omnis_plugins` tag `v0.50.0`, which predates this file's existence, so
/// there's no tagged release yet for `HomeDashboardPlugin`'s extracted
/// `HomeDashboardPage` to import it from. Once task 6 bumps that pin,
/// this and the app's copy become candidates for consolidation into one
/// shared copy — not done here, just flagged.
///
/// Deliberately **not cached** — unlike the app's own copy, which caches
/// by track id because its `TrackArtwork` rebuilds on every position tick
/// in Now Playing. Home dashboard cards rebuild far less often, and a
/// cache here would be a second, independent one the app's own
/// `ArtworkProvider.invalidate` calls (`tag_editor_dialog.dart`,
/// `library_page.dart`, after every artwork write) can never reach —
/// since the two `ArtworkProvider` classes live in different packages,
/// invalidating one's cache does nothing to the other's, and Home would
/// show stale cover art for the rest of the process after any edit. Not
/// caching trades a small amount of redundant I/O (infrequent — Home's
/// artwork requests aren't triggered by a position-tick rebuild loop the
/// way Now Playing's are) for never showing stale art, without needing a
/// cross-repo invalidation path that doesn't exist yet.
class ArtworkProvider {
  ArtworkProvider._();

  static final OnAudioQuery _audioQuery = OnAudioQuery();

  static Future<Uint8List?> forTrack(BaseTrack track) => _load(track);

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
