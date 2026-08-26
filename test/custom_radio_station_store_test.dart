import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/custom_radio_station_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  final String tempDir;
  _FakePathProvider(this.tempDir);

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDir;

  setUpAll(() async {
    tempDir = (await Directory.systemTemp
            .createTemp('omnis_custom_radio_test'))
        .path;
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  tearDown(() async {
    await CustomRadioStationStore.instance.save([]);
  });

  test('load() returns empty when nothing has ever been saved', () async {
    expect(await CustomRadioStationStore.instance.load(), isEmpty);
  });

  test('add() persists a new station and returns the updated list',
      () async {
    final result = await CustomRadioStationStore.instance
        .add('My Jazz Station', 'https://stream.example.com/jazz');

    expect(result, hasLength(1));
    expect(result.single.name, 'My Jazz Station');
    expect(result.single.streamUrl, 'https://stream.example.com/jazz');

    final loaded = await CustomRadioStationStore.instance.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.name, 'My Jazz Station');
  });

  test('adding a second station preserves the first, in order', () async {
    await CustomRadioStationStore.instance
        .add('First', 'https://a.example.com/stream');
    final result = await CustomRadioStationStore.instance
        .add('Second', 'https://b.example.com/stream');

    expect(result.map((s) => s.name), ['First', 'Second']);
  });

  test('delete() removes exactly the given station, leaving the rest',
      () async {
    await CustomRadioStationStore.instance
        .add('Keep Me', 'https://a.example.com/stream');
    final entries = await CustomRadioStationStore.instance
        .add('Delete Me', 'https://b.example.com/stream');
    final toDelete = entries.firstWhere((s) => s.name == 'Delete Me');

    final result = await CustomRadioStationStore.instance.delete(toDelete.id);

    expect(result.map((s) => s.name), ['Keep Me']);
  });

  test('delete() for an unknown id is a harmless no-op', () async {
    await CustomRadioStationStore.instance
        .add('Keep Me', 'https://a.example.com/stream');

    final result =
        await CustomRadioStationStore.instance.delete('does-not-exist');

    expect(result, hasLength(1));
  });

  test('toTrack() produces a real radio BaseTrack with the exact stream '
      'URL, playable with zero special-casing', () {
    final station = CustomRadioStation(
      id: 'radio:custom:1',
      name: 'My Station',
      streamUrl: 'https://stream.example.com/live',
      createdAt: DateTime(2025),
    );

    final track = station.toTrack();

    expect(track.id, 'radio:custom:1');
    expect(track.title, 'My Station');
    expect(track.type, TrackType.radio);
    expect(track.streamUrl, 'https://stream.example.com/live');
  });

  test('tolerates corrupt JSON', () async {
    final f = File('$tempDir/omnis_custom_radio_stations.json');
    await f.writeAsString('not valid json {{{');

    expect(await CustomRadioStationStore.instance.load(), isEmpty);
  });

  test('a single malformed record among many valid ones is skipped, not '
      'fatal to the rest', () async {
    final f = File('$tempDir/omnis_custom_radio_stations.json');
    await f.writeAsString(jsonEncode({
      'schemaVersion': 1,
      'data': [
        {
          'id': 'radio:custom:1',
          'name': 'Good One',
          'streamUrl': 'https://a.example.com/stream',
          'createdAt': DateTime(2025).toIso8601String(),
        },
        <String, dynamic>{},
        {
          'id': 'radio:custom:2',
          'name': 'Good Two',
          'streamUrl': 'https://b.example.com/stream',
          'createdAt': DateTime(2025).toIso8601String(),
        },
      ],
    }));

    final loaded = await CustomRadioStationStore.instance.load();

    expect(loaded.map((s) => s.name).toSet(), {'Good One', 'Good Two'});
  });

  test('save() writes atomically — no leftover .tmp file', () async {
    await CustomRadioStationStore.instance
        .add('My Station', 'https://a.example.com/stream');

    final tmp = File('$tempDir/omnis_custom_radio_stations.json.tmp');
    expect(await tmp.exists(), isFalse);
    final real = File('$tempDir/omnis_custom_radio_stations.json');
    expect(await real.exists(), isTrue);
  });
}
