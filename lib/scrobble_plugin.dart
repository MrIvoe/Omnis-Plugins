import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/play_record.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Records real play history, persisted via this plugin's own
/// [MusicPlugin.storage] (plugin-private state, not a shared app-settings
/// singleton — `storage` also works before this plugin is attached to a
/// `PluginManager`, unlike `context`, which keeps it usable standalone in
/// tests). Previously this only ever lived in memory, capped at the last
/// 10 plays as pre-joined display strings — so every "recently
/// played"/"most played" idea (which every named competitor has under
/// some name) had no real data to work from, and a restart erased
/// everything anyway.
///
/// Implements [IPlayHistoryProvider] and registers itself under that
/// interface (`context.services`) rather than only being reachable as a
/// concrete `ScrobblePlugin` — anything asking "what's been played most"
/// asks the interface.
class ScrobblePlugin extends MusicPlugin implements IPlayHistoryProvider {
  static const _maxHistory = 500;
  static const _playHistoryKey = 'play_history';

  List<PlayRecord> _history = [];

  /// Full play history, oldest first.
  List<PlayRecord> get playRecords => List.unmodifiable(_history);

  /// Legacy display-string API — still used by Settings' "Scrobble
  /// history" card.
  List<String> get history =>
      _history.map((r) => '${r.title} • ${r.artist}').toList();

  List<PlayRecord> _readHistory() {
    final raw = storage.getString(_playHistoryKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => PlayRecord.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persistHistory() => storage.setString(
      _playHistoryKey, jsonEncode(_history.map((r) => r.toJson()).toList()));

  @override
  String get id => 'scrobble';

  @override
  String get name => 'Scrobble';

  @override
  String get description =>
      'Records real play history for recently-played and most-played lists.';

  @override
  String get version => '2.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    _history = _readHistory();
    context?.services.register(IPlayHistoryProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {
    _history.add(PlayRecord(
      trackId: track.id,
      title: track.title,
      artist: track.artists.join(', '),
      playedAt: DateTime.now(),
    ));
    if (_history.length > _maxHistory) {
      _history = _history.sublist(_history.length - _maxHistory);
    }
    await _persistHistory();
  }

  /// Most recently played tracks, newest first, deduped to one entry per
  /// track — a track played 5 times today shouldn't fill all 5 slots of a
  /// "recently played" list with itself.
  @override
  List<PlayRecord> recentlyPlayed({int limit = 25}) {
    final seen = <String>{};
    final result = <PlayRecord>[];
    for (final record in _history.reversed) {
      if (record.trackId.isEmpty) continue;
      if (seen.add(record.trackId)) result.add(record);
      if (result.length >= limit) break;
    }
    return result;
  }

  /// Track ids ordered by how often they've been played, most first — the
  /// data "most played" queries filter a real track list against.
  @override
  List<MapEntry<String, int>> mostPlayedIds({int limit = 25}) {
    final counts = <String, int>{};
    for (final record in _history) {
      if (record.trackId.isEmpty) continue;
      counts[record.trackId] = (counts[record.trackId] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(limit).toList();
  }

  /// How many times [trackId] has been played.
  @override
  int playCountFor(String trackId) =>
      _history.where((r) => r.trackId == trackId).length;

  /// Wipes all recorded play history. Used by this plugin's own settings
  /// page — there's no undo, so the UI confirms before calling this.
  Future<void> clearHistory() async {
    _history = [];
    await storage.remove(_playHistoryKey);
  }

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => switch (locationID) {
        'now_playing_overlay' => _historyBadge(),
        'plugin_settings' => _ScrobbleSettings(plugin: this),
        _ => null,
      };

  Widget? _historyBadge() {
    // Proves the uiSlot hook actually reaches the screen: a bundled plugin
    // can return a real Flutter Widget (an external, dart_eval-interpreted
    // plugin cannot — see PluginSlotView for the declarative fallback that
    // path uses instead).
    if (_history.isEmpty) return null;
    return Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history,
                  size: 14, color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 6),
              Text(
                '${_history.length} play${_history.length == 1 ? '' : 's'} tracked',
                style: TextStyle(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Future<void> enable() async {
    context?.services.register(IPlayHistoryProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IPlayHistoryProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IPlayHistoryProvider, this);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. Previously the play history list lived directly in
/// `settings_page.dart` as a hardcoded "Plugin activity" card that only
/// ever showed `ScrobblePlugin`; now it's this plugin's own page, and
/// gains a real "clear history" action `settings_page.dart` never had.
class _ScrobbleSettings extends StatefulWidget {
  final ScrobblePlugin plugin;

  const _ScrobbleSettings({required this.plugin});

  @override
  State<_ScrobbleSettings> createState() => _ScrobbleSettingsState();
}

class _ScrobbleSettingsState extends State<_ScrobbleSettings> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final history = widget.plugin.history.reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Play history', style: theme.textTheme.titleSmall),
            const Spacer(),
            if (history.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Clear play history?'),
                      content: const Text(
                          'Removes every recorded play. Recently played / '
                          'most played lists will start over. This cannot '
                          'be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await widget.plugin.clearHistory();
                    if (mounted) setState(() {});
                  }
                },
                child: const Text('Clear'),
              ),
          ],
        ),
        if (history.isEmpty)
          const Text('Nothing played yet.')
        else
          ...history.take(50).map((entry) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    const Icon(Icons.history, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(entry,
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              )),
        if (history.length > 50)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '+ ${history.length - 50} more',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
