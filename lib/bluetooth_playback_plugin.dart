import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/playlist.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// Detects a Bluetooth audio device (speaker, car stereo, headphones)
/// connecting or disconnecting, and offers one-tap "quick play" — an
/// entire library shuffle, a mood, or a saved playlist — for exactly the
/// "just got in the car, want music going" moment this was built for.
///
/// Detection goes through `audio_session` (already a transitive
/// dependency of `just_audio`, so no new native platform-channel code is
/// needed) rather than a raw Bluetooth API: its
/// `devicesChangedEventStream` reports real output-device connect/
/// disconnect events, filtered here to `AudioDeviceType.bluetoothA2dp`/
/// `bluetoothLe`/`bluetoothSco`. This is the same signal Android's own
/// audio-routing UI reacts to, and it's a well-established, actively
/// maintained package — a materially safer foundation than a
/// less-maintained raw-Bluetooth package would have been for something
/// this couldn't be device-tested against here.
///
/// Library/playlist loading and the Bluetooth permission request go
/// through `PluginContext` (`loadLibraryTracks`/`loadPlaylists`/
/// `requestBluetoothPermission`) rather than this app's own
/// `LibraryStore`/`PlaylistStore`/`OmnisPermissions` — this plugin lives
/// in a separate package with no dependency on the Omnis app itself, so
/// context is the only way to reach them.
///
/// **Verification status**: implemented against `audio_session`'s
/// documented API; not exercised against a real Bluetooth device
/// connecting/disconnecting in this environment.
/// What a Bluetooth connect/disconnect event should do to the active Now
/// Playing layout, per [bluetoothLayoutActionFor] — kept as a pure,
/// dependency-free decision separate from the stateful plugin so it's
/// unit-testable without a real `PluginContext`.
enum BluetoothLayoutAction {
  /// Switch to the configured target layout (connecting, not already on it).
  switchToTarget,

  /// Restore whichever layout was active before switching (disconnecting).
  restorePrevious,

  /// Do nothing — the feature is off, or there's nothing to change.
  none,
}

/// Decides what [BluetoothLayoutAction] a device connect/disconnect
/// event should trigger. Mirrors `DrivingModePlugin._enterDrivingMode`/
/// `_exitDrivingMode`'s own "only switch if not already there" guard —
/// spec's own example ("Bluetooth device connected → Activate Driving
/// UI") for the connect side, symmetric restore-on-disconnect for the
/// other.
BluetoothLayoutAction bluetoothLayoutActionFor({
  required bool enabled,
  required bool connected,
  required String currentLayoutId,
  required String targetLayoutId,
}) {
  if (!enabled) return BluetoothLayoutAction.none;
  if (connected) {
    return currentLayoutId == targetLayoutId
        ? BluetoothLayoutAction.none
        : BluetoothLayoutAction.switchToTarget;
  }
  return BluetoothLayoutAction.restorePrevious;
}

class BluetoothPlaybackPlugin extends MusicPlugin
    implements IDeviceConnectivityProvider {
  static const _enabledKey = 'enabled';
  static const _switchLayoutKey = 'switch_layout_on_connect';
  static const _targetLayoutId = 'car_mode';

  StreamSubscription<AudioDevicesChangedEvent>? _devicesSub;
  String? connectedDeviceName;
  String? lastError;
  String? _previousLayoutId;

  /// Whether connecting a Bluetooth device should switch the active Now
  /// Playing layout to Car Mode — off by default so an existing user's
  /// layout doesn't change out from under them the first time this
  /// ships. Distinct from [enabled] (whether device detection itself
  /// runs at all): this only controls what happens to the layout once
  /// detection is already on.
  bool get switchLayoutOnConnect => storage.getBool(_switchLayoutKey) ?? false;

  Future<void> setSwitchLayoutOnConnect(bool value) =>
      storage.setBool(_switchLayoutKey, value);

  /// Broadcasts [connectedDeviceName] every time it changes (a device
  /// connecting, a different device connecting, or disconnecting to
  /// `null`) — unlike the field itself, which callers had to poll.
  /// `EqualizerPlugin` listens to this for per-device EQ presets; any
  /// other plugin wanting to react to device changes can too, without
  /// this plugin needing to know who's listening.
  final _deviceController = StreamController<String?>.broadcast();
  Stream<String?> get deviceChanges => _deviceController.stream;

  bool get enabled => storage.getBool(_enabledKey) ?? false;

  Future<void> setEnabled(bool value) async {
    await storage.setBool(_enabledKey, value);
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  static bool _isBluetoothOutput(AudioDevice device) {
    const bluetoothTypes = {
      AudioDeviceType.bluetoothA2dp,
      AudioDeviceType.bluetoothLe,
      AudioDeviceType.bluetoothSco,
    };
    return device.isOutput && bluetoothTypes.contains(device.type);
  }

  Future<void> _start() async {
    final granted = await context?.requestBluetoothPermission() ?? false;
    if (!granted) {
      lastError = 'Bluetooth permission denied — can\'t detect connected devices.';
      return;
    }
    lastError = null;
    try {
      final session = await AudioSession.instance;
      await _devicesSub?.cancel();
      _devicesSub = session.devicesChangedEventStream.listen((event) {
        for (final device in event.devicesAdded) {
          if (_isBluetoothOutput(device)) {
            connectedDeviceName = device.name;
            _deviceController.add(connectedDeviceName);
            _applyLayoutAction(connected: true);
            return;
          }
        }
        for (final device in event.devicesRemoved) {
          if (_isBluetoothOutput(device) && device.name == connectedDeviceName) {
            connectedDeviceName = null;
            _deviceController.add(null);
            _applyLayoutAction(connected: false);
          }
        }
      });
    } catch (e) {
      lastError = 'Could not watch for Bluetooth devices: $e';
    }
  }

  Future<void> _stop() async {
    await _devicesSub?.cancel();
    _devicesSub = null;
    if (connectedDeviceName != null) {
      connectedDeviceName = null;
      _deviceController.add(null);
      _applyLayoutAction(connected: false);
    }
  }

  /// Applies whatever [bluetoothLayoutActionFor] decides for a connect/
  /// disconnect event — the thin `PluginContext` wrapper around that
  /// pure decision. Remembers the layout active before switching to
  /// Car Mode so disconnecting restores it, the same
  /// `_previousLayoutId` shape `DrivingModePlugin` already uses.
  void _applyLayoutAction({required bool connected}) {
    final ctx = context;
    if (ctx == null) return;
    final action = bluetoothLayoutActionFor(
      enabled: switchLayoutOnConnect,
      connected: connected,
      currentLayoutId: ctx.playerLayoutId,
      targetLayoutId: _targetLayoutId,
    );
    switch (action) {
      case BluetoothLayoutAction.switchToTarget:
        _previousLayoutId = ctx.playerLayoutId;
        // ignore: unawaited_futures
        ctx.setPlayerLayoutId(_targetLayoutId);
      case BluetoothLayoutAction.restorePrevious:
        final previous = _previousLayoutId;
        _previousLayoutId = null;
        if (previous != null && ctx.playerLayoutId == _targetLayoutId) {
          // ignore: unawaited_futures
          ctx.setPlayerLayoutId(previous);
        }
      case BluetoothLayoutAction.none:
        break;
    }
  }

  /// Every mood/preset name any registered [IQueueBuilder] understands —
  /// `SmartPlaylistPlugin`'s curated moods and `QueuePresetPlugin`'s
  /// objective presets combined, deduped, for a single quick-play list.
  List<String> get availableMoods {
    final builders = context?.services.getAll<IQueueBuilder>() ?? const [];
    final moods = <String>{};
    for (final builder in builders) {
      moods.addAll(builder.supportedQueries);
    }
    return moods.toList();
  }

  Future<List<Playlist>> availablePlaylists() =>
      context?.loadPlaylists() ?? Future.value(const []);

  /// Shuffles and plays the whole library.
  Future<void> playLibrary() async {
    final tracks = await context?.loadLibraryTracks() ?? const [];
    if (tracks.isEmpty) return;
    final shuffled = List<BaseTrack>.from(tracks)..shuffle();
    await context?.setQueue(shuffled);
    await context?.play();
  }

  /// Plays a mood/preset queue via whichever registered [IQueueBuilder]
  /// finds something first — same "try each in order, keep the first
  /// non-empty result" pattern `HomePage._MoodsPageState._playMood` uses.
  Future<void> playMood(String mood) async {
    final tracks = await context?.loadLibraryTracks() ?? const [];
    final builders = context?.services.getAll<IQueueBuilder>() ?? const [];
    for (final builder in builders) {
      final result = builder.buildQueueFor(tracks, mood);
      if (result.isNotEmpty) {
        await context?.setQueue(result);
        await context?.play();
        return;
      }
    }
  }

  /// Plays a saved playlist by id, in its saved order.
  Future<void> playPlaylist(String playlistId) async {
    final playlists = await context?.loadPlaylists() ?? const [];
    Playlist? playlist;
    for (final p in playlists) {
      if (p.id == playlistId) {
        playlist = p;
        break;
      }
    }
    if (playlist == null) return;
    final tracks = await context?.loadLibraryTracks() ?? const [];
    final byId = {for (final t in tracks) t.id: t};
    final ordered = playlist.trackIds
        .map((id) => byId[id])
        .whereType<BaseTrack>()
        .toList();
    if (ordered.isEmpty) return;
    await context?.setQueue(ordered);
    await context?.play();
  }

  @override
  String get id => 'bluetooth_playback';

  @override
  String get name => 'Bluetooth Playback';

  @override
  String get description => enabled
      ? (connectedDeviceName != null
          ? 'Connected to $connectedDeviceName.'
          : 'Watching for a Bluetooth audio device.')
      : 'Quick-play your library, a mood, or a playlist when a Bluetooth '
          'speaker/car stereo connects.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IDeviceConnectivityProvider, this);
    if (enabled) await _start();
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  Future<void> enable() async {
    context?.services.register(IDeviceConnectivityProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IDeviceConnectivityProvider, this);
    await _stop();
  }

  @override
  dynamic uiSlot(String locationID) => switch (locationID) {
        'plugin_settings' => _BluetoothPlaybackSettings(plugin: this),
        'now_playing_overlay' => _ConnectedBadge(plugin: this),
        _ => null,
      };

  @override
  Future<void> dispose() async {
    await _stop();
    await _deviceController.close();
  }
}

/// Small badge on Now Playing when a Bluetooth device is connected —
/// tapping it opens the same quick-play sheet the settings page offers.
class _ConnectedBadge extends StatelessWidget {
  final BluetoothPlaybackPlugin plugin;

  const _ConnectedBadge({required this.plugin});

  @override
  Widget build(BuildContext context) {
    if (!plugin.enabled || plugin.connectedDeviceName == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return ActionChip(
      avatar: const Icon(Icons.bluetooth_audio, size: 16),
      label: Text('Connected to ${plugin.connectedDeviceName} — Quick play'),
      backgroundColor: theme.colorScheme.secondaryContainer,
      onPressed: () => _showQuickPlaySheet(context, plugin),
    );
  }
}

Future<void> _showQuickPlaySheet(
  BuildContext context,
  BluetoothPlaybackPlugin plugin,
) async {
  final playlists = await plugin.availablePlaylists();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.library_music),
            title: const Text('Play entire library'),
            onTap: () {
              Navigator.of(context).pop();
              plugin.playLibrary();
            },
          ),
          for (final mood in plugin.availableMoods)
            ListTile(
              leading: const Icon(Icons.mood),
              title: Text(mood),
              onTap: () {
                Navigator.of(context).pop();
                plugin.playMood(mood);
              },
            ),
          for (final playlist in playlists)
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(playlist.name),
              onTap: () {
                Navigator.of(context).pop();
                plugin.playPlaylist(playlist.id);
              },
            ),
        ],
      ),
    ),
  );
}

class _BluetoothPlaybackSettings extends StatefulWidget {
  final BluetoothPlaybackPlugin plugin;

  const _BluetoothPlaybackSettings({required this.plugin});

  @override
  State<_BluetoothPlaybackSettings> createState() =>
      _BluetoothPlaybackSettingsState();
}

class _BluetoothPlaybackSettingsState
    extends State<_BluetoothPlaybackSettings> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plugin = widget.plugin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Watch for Bluetooth audio devices'),
          subtitle: Text(plugin.connectedDeviceName != null
              ? 'Connected to ${plugin.connectedDeviceName}'
              : 'Not currently connected'),
          value: plugin.enabled,
          onChanged: (value) async {
            await plugin.setEnabled(value);
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Switch to Car Mode when connected'),
          subtitle: const Text(
              'Activates the Car Mode Now Playing layout while a Bluetooth '
              'device is connected, restoring your previous layout on '
              'disconnect'),
          value: plugin.switchLayoutOnConnect,
          onChanged: (value) async {
            await plugin.setSwitchLayoutOnConnect(value);
            if (mounted) setState(() {});
          },
        ),
        if (plugin.lastError != null) ...[
          Text(plugin.lastError!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        Text('Quick play', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Available any time, not just while connected — useful to try '
          'this out without a Bluetooth device handy.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _showQuickPlaySheet(context, plugin),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Quick play…'),
        ),
      ],
    );
  }
}
