// Sample Omnis plugin: logs track starts to the console.
//
// Install via the Plugins tab by pasting a GitHub URL that contains
// this file plus an `omnis_plugin.yaml` manifest.

dynamic createPlugin(dynamic api) {
  return {
    'id': 'sample_logger',
    'name': 'Sample Logger',
    'description': 'Logs track starts to the console',
    'version': '1.0.0',
    'author': 'Omnis Team',
    'hooks': ['onTrackStart', 'onLibraryScan', 'uiSlot'],
  };
}

/// Called when a track starts playing.
/// [track] is a JSON Map with title, artists, album, etc.
dynamic onTrackStart(dynamic track) {
  // In a real plugin you'd fetch lyrics, scrobble, etc.
  // Here we just return a confirmation string.
  return 'logged';
}

/// Called once per file during a library scan.
/// [file] is the file path as a String.
dynamic onLibraryScan(dynamic file) {
  return 'scanned';
}

/// Injects a small badge into the Now Playing screen.
///
/// Downloaded plugins run in dart_eval and cannot import `dart:ui`, so
/// they cannot build a real Flutter widget the way a bundled plugin can.
/// Instead they return a small declarative Map — `{'type': ..., ...}` —
/// which the host app (`PluginSlotView`) knows how to render. This is the
/// only shape of UI a downloaded plugin can contribute.
dynamic uiSlot(dynamic locationID) {
  if (locationID != 'now_playing_overlay') {
    return null;
  }
  return {
    'type': 'badge',
    'text': 'Sample Logger active',
    'icon': 'info',
  };
}
