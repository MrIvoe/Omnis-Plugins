import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';

/// A bundled plugin that applies a simple loudness normalization multiplier.
///
/// It reads each track's ReplayGain metadata on [onTrackStart] and pushes
/// the resulting multiplier to the audio engine through
/// [MusicPlugin.context], composing with any other plugin's gain rather
/// than overwriting it.
class ReplayGainPlugin extends MusicPlugin {
  /// Key this plugin's gain contribution is registered under.
  static const gainSource = 'replay_gain';

  static const _preampDbKey = 'preamp_db';
  static const _useAlbumGainKey = 'use_album_gain';

  double _multiplier = 1.0;

  double get multiplier => _multiplier;

  /// Extra overall trim applied on top of the computed ReplayGain
  /// multiplier, in decibels (-6..+6). Lets a user compensate for a
  /// library that's tagged consistently too quiet/loud without touching
  /// per-track values. 0 by default — no effect unless changed.
  double get preampDb => storage.getDouble(_preampDbKey) ?? 0.0;

  /// Whether to normalize using [ReplayGainValues.albumGain] instead of
  /// [ReplayGainValues.trackGain] — the standard alternative RG mode
  /// every real player (foobar2000, MusicBee) offers: track gain
  /// normalizes every track to the same perceived loudness, album gain
  /// instead preserves an album's own intentional relative loudness
  /// across its tracks (a quiet interlude stays quiet next to a loud
  /// chorus) while still normalizing *between* different albums. `false`
  /// (track gain) by default, matching this plugin's prior behavior
  /// exactly for anyone who already had it configured.
  bool get useAlbumGain => storage.getBool(_useAlbumGainKey) ?? false;

  Future<void> setPreampDb(double db) async {
    await storage.setDouble(_preampDbKey, db.clamp(-6.0, 6.0));
    // Re-apply immediately against the *current* track so a slider drag
    // is audible without waiting for the next track to start.
    final track = context?.currentTrack;
    if (track != null) {
      setReplayGain(track);
      await context?.setGain(gainSource, _multiplier);
    }
  }

  Future<void> setUseAlbumGain(bool value) async {
    await storage.setBool(_useAlbumGainKey, value);
    // Same "audible immediately, not just on the next track" contract
    // setPreampDb already has.
    final track = context?.currentTrack;
    if (track != null) {
      setReplayGain(track);
      await context?.setGain(gainSource, _multiplier);
    }
  }

  /// Compute the loudness multiplier for [track] from its ReplayGain tags,
  /// plus [preampDb]. Prefers [ReplayGainValues.albumGain] over
  /// [ReplayGainValues.trackGain] when [useAlbumGain] is on, but falls
  /// back to track gain when a track has no album gain tag at all —
  /// the same "don't silently no-op, use what's actually available"
  /// stance this app's other degrade paths already hold, rather than
  /// leaving a track completely unnormalized just because the specific
  /// field the user asked for happens to be missing on it.
  void setReplayGain(BaseTrack track) {
    final values = track.replayGain;
    final gain = useAlbumGain ? (values?.albumGain ?? values?.trackGain) : values?.trackGain;
    final base = (gain != null && gain.isFinite)
        ? (gain >= 0 ? 1.0 : 1.0 + (-gain / 20.0)).clamp(0.5, 1.5)
        : 1.0;
    final preamp = preampDb;
    _multiplier = preamp == 0.0
        ? base
        : (base * _dbToMultiplier(preamp)).clamp(0.3, 2.0);
  }

  static double _dbToMultiplier(double db) => db >= 0
      ? 1.0 + db / 12.0
      : 1.0 + db / 20.0;

  @override
  String get id => 'replay_gain';

  @override
  String get name => 'Replay Gain';

  @override
  String get description =>
      'Normalizes track loudness using ReplayGain-style metadata.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> onTrackStart(BaseTrack track) async {
    setReplayGain(track);
    await context?.setGain(gainSource, _multiplier);
  }

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) =>
      locationID == 'plugin_settings' ? _ReplayGainSettings(plugin: this) : null;

  @override
  Future<void> enable() async {
    await context?.setGain(gainSource, _multiplier);
  }

  @override
  Future<void> disable() async {
    // Stop normalizing immediately instead of leaving the last track's
    // multiplier applied to everything that follows.
    await context?.clearGain(gainSource);
  }

  @override
  Future<void> dispose() async {
    await context?.clearGain(gainSource);
  }
}

/// This plugin's own settings — reached by tapping it in the Plugins
/// list. A preamp is the one genuinely useful manual control on top of
/// automatic ReplayGain: it compensates for a whole library that's
/// tagged consistently too quiet or too loud without touching per-track
/// values.
class _ReplayGainSettings extends StatefulWidget {
  final ReplayGainPlugin plugin;

  const _ReplayGainSettings({required this.plugin});

  @override
  State<_ReplayGainSettings> createState() => _ReplayGainSettingsState();
}

class _ReplayGainSettingsState extends State<_ReplayGainSettings> {
  @override
  Widget build(BuildContext context) {
    final db = widget.plugin.preampDb;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use album gain'),
          subtitle: const Text(
              "Preserve an album's own relative loudness across its "
              "tracks, instead of normalizing every track to the same "
              'level. Falls back to track gain for a track with no '
              'album gain tag.'),
          value: widget.plugin.useAlbumGain,
          onChanged: (value) async {
            await widget.plugin.setUseAlbumGain(value);
            if (mounted) setState(() {});
          },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Preamp'),
          subtitle: Slider(
            value: db,
            min: -6,
            max: 6,
            divisions: 24,
            label: '${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB',
            onChanged: (value) async {
              await widget.plugin.setPreampDb(value);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }
}
