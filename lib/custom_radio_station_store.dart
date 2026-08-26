import 'dart:convert';
import 'dart:io';

import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugins/schema_versioning.dart';
import 'package:path_provider/path_provider.dart';

/// This store's current on-disk shape version — see `schema_versioning.dart`.
const _currentSchemaVersion = 1;
const _migrations = <int, SchemaMigration>{};

/// A user-entered internet radio stream — item 41's "no custom/manually-
/// added stream URL entry" gap, the one thing left in Radio still
/// scoped to Radio Browser's own directory. Converts to an ordinary
/// [BaseTrack] the same shape `RadioPlugin`'s own station conversion
/// already produces (`type: TrackType.radio`, a real `streamUrl`), so
/// favoriting/queueing/play-history all work identically to a fetched
/// station with zero special-casing anywhere else in the app — those
/// features key off [BaseTrack.id] generically, not off which source
/// produced the track.
///
/// Moved here from the Omnis app's own `lib/core/custom_radio_station_store.dart`
/// (Tier 2 task 5, alongside `RadioBody`/`OnlinePage`) — byte-for-byte
/// identical apart from its imports, so an existing install's saved
/// custom stations survive the move untouched (same on-disk filename,
/// same versioned-envelope shape).
class CustomRadioStation {
  final String id;
  final String name;
  final String streamUrl;
  final DateTime createdAt;

  const CustomRadioStation({
    required this.id,
    required this.name,
    required this.streamUrl,
    required this.createdAt,
  });

  BaseTrack toTrack() => BaseTrack(
        id: id,
        title: name,
        artists: const ['Custom Station'],
        album: 'Internet Radio',
        duration: 0,
        type: TrackType.radio,
        streamUrl: streamUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'streamUrl': streamUrl,
        'createdAt': createdAt.toIso8601String(),
      };

  factory CustomRadioStation.fromJson(Map<String, dynamic> json) =>
      CustomRadioStation(
        id: json['id'] as String,
        name: json['name'] as String,
        streamUrl: json['streamUrl'] as String,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Persists user-added custom radio stations. Same atomic-write +
/// schema-versioned-envelope shape every other store in this app
/// already uses.
class CustomRadioStationStore {
  CustomRadioStationStore._();

  static final CustomRadioStationStore instance = CustomRadioStationStore._();

  File? _file;

  Future<File> _getFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/omnis_custom_radio_stations.json');
    return _file!;
  }

  /// Load persisted stations, in the order they were added. Returns an
  /// empty list if none exist or the file is corrupt — each entry is
  /// decoded independently, so one malformed record can't wipe the
  /// rest.
  Future<List<CustomRadioStation>> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      final unwrapped = unwrapVersioned(decoded);
      final migrated = runMigrations(unwrapped.data, unwrapped.version,
          _currentSchemaVersion, _migrations);
      if (migrated is! List) return [];
      final stations = <CustomRadioStation>[];
      for (final entry in migrated) {
        if (entry is! Map) continue;
        try {
          stations.add(
              CustomRadioStation.fromJson(Map<String, dynamic>.from(entry)));
        } catch (_) {
          continue;
        }
      }
      return stations;
    } catch (e) {
      return [];
    }
  }

  /// Persist [stations] to disk. Writes to a sibling `.tmp` file and
  /// renames it over the real path — atomic on the filesystems this app
  /// targets, the same crash-safety every other store's `save` already
  /// has.
  Future<void> save(List<CustomRadioStation> stations) async {
    try {
      final file = await _getFile();
      final json = jsonEncode(wrapVersioned(
          stations.map((s) => s.toJson()).toList(), _currentSchemaVersion));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      // Best-effort persistence; a failure here must never crash the app.
    }
  }

  /// Adds a new custom station named [name] streaming from [streamUrl].
  Future<List<CustomRadioStation>> add(String name, String streamUrl) async {
    final existing = await load();
    final station = CustomRadioStation(
      id: 'radio:custom:${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      streamUrl: streamUrl,
      createdAt: DateTime.now(),
    );
    final updated = [...existing, station];
    await save(updated);
    return updated;
  }

  /// Deletes the custom station with [id], if one exists. A harmless
  /// no-op otherwise.
  Future<List<CustomRadioStation>> delete(String id) async {
    final existing = await load();
    final updated = existing.where((s) => s.id != id).toList();
    await save(updated);
    return updated;
  }
}
