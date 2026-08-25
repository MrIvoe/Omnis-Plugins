import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/track_artwork.dart';

BaseTrack _track(String id) => BaseTrack(
      id: id,
      title: 'Track $id',
      artists: const ['Artist'],
      album: 'Album',
      duration: 200,
      type: TrackType.local,
    );

void main() {
  testWidgets(
      'TrackArtwork reuses the same artwork Future across a rebuild with '
      'the same track — task 3 fix round 2: ArtworkProvider.forTrack() '
      'deliberately does not cache (a process-global cache there was the '
      'original staleness bug), so without this the widget would build a '
      'brand new Future on every routine rebuild (playback ticks, '
      'favorite toggles, scan-debounce reloads), resetting FutureBuilder '
      'to ConnectionState.waiting and flickering back to the placeholder. '
      'A genuinely different track must still get a fresh lookup.',
      (tester) async {
    final trackA = _track('a');
    final trackB = _track('b');
    var currentTrack = trackA;
    late StateSetter setState;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setter) {
        setState = setter;
        return TrackArtwork(track: currentTrack);
      }),
    ));

    Future<Uint8List?> currentFuture() => tester
        .widget<FutureBuilder<Uint8List?>>(
            find.byType(FutureBuilder<Uint8List?>))
        .future!;

    final firstFuture = currentFuture();

    // An unrelated rebuild with the *same* track — e.g. a parent's
    // setState from a playback tick, favorite toggle, or scan-debounce
    // reload — must reuse the exact same Future instance, not construct
    // a new one.
    setState(() {});
    await tester.pump();
    expect(currentFuture(), same(firstFuture));

    // Rebuilding with the same track a second time must still reuse it.
    setState(() {});
    await tester.pump();
    expect(currentFuture(), same(firstFuture));

    // A genuinely different track must get a fresh lookup, not the stale
    // Future from the track that used to be displayed.
    setState(() => currentTrack = trackB);
    await tester.pump();
    expect(currentFuture(), isNot(same(firstFuture)));
  });
}
