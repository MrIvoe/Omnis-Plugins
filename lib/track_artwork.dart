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
/// Deliberately **not cached** here — unlike the app's own copy, whose
/// process-global cache the app's own `ArtworkProvider.invalidate` calls
/// (`tag_editor_dialog.dart`, `library_page.dart`, after every artwork
/// write) keep correct. A cache in *this* copy would be a second,
/// independent one those calls can never reach — since the two
/// `ArtworkProvider` classes live in different packages, invalidating one
/// does nothing to the other, and Home would show stale cover art for the
/// rest of the process after any edit. Per-lookup memoization instead
/// lives on [TrackArtwork] itself — see that class's own doc comment for
/// why a bare no-cache-at-all approach (this class's first fix-round
/// attempt) was itself a regression.
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
///
/// A `StatefulWidget` (not stateless, despite having no user-visible
/// interaction of its own) purely to memoize the in-flight
/// `Future<Uint8List?>` per displayed track — see task 3's fix-round-2
/// finding for why. `ArtworkProvider.forTrack()` deliberately doesn't
/// cache (a process-global cache there was the *original* staleness bug
/// this class's own artwork-provider doc comment explains), so calling it
/// straight from `build()` produced a brand new `Future` on every
/// rebuild, resetting the `FutureBuilder` to `ConnectionState.waiting` —
/// flickering back to the placeholder icon and re-issuing the MediaStore
/// query / tag read on every rebuild, including the routine ones
/// `HomeDashboardPageState` triggers via its track-change/favorite-
/// change/scan-debounce listeners during ordinary playback. Storing the
/// `Future` in `State` and only recomputing it in [didUpdateWidget] when
/// [track]'s id actually changes gets both properties at once: same-track
/// rebuilds reuse the stored `Future` (no flicker, no redundant I/O), a
/// genuinely different track always gets a fresh lookup (no staleness).
class TrackArtwork extends StatefulWidget {
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
  State<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends State<TrackArtwork> {
  late String _trackId;
  late Future<Uint8List?> _artworkFuture;

  @override
  void initState() {
    super.initState();
    _trackId = widget.track.id;
    _artworkFuture = ArtworkProvider.forTrack(widget.track);
  }

  @override
  void didUpdateWidget(TrackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only a genuinely different track re-triggers the lookup — every
    // other rebuild (a parent's unrelated setState, a different track's
    // favorite/scan/playback event) reuses the same in-flight/completed
    // Future, so FutureBuilder never resets to ConnectionState.waiting
    // for a track whose artwork is already showing or already loading.
    if (widget.track.id != _trackId) {
      _trackId = widget.track.id;
      _artworkFuture = ArtworkProvider.forTrack(widget.track);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final child = FutureBuilder<Uint8List?>(
      future: _artworkFuture,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => _placeholder(theme),
          );
        }
        return _placeholder(theme);
      },
    );

    if (widget.borderRadius == null) return child;
    return ClipRRect(borderRadius: widget.borderRadius!, child: child);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      width: widget.width,
      height: widget.height,
      color: widget.backgroundColor ?? theme.colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(Icons.music_note,
          size: widget.iconSize,
          color: theme.colorScheme.onPrimaryContainer),
    );
  }
}
