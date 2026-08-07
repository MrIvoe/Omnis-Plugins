import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_interface.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';

/// A simple visualizer plugin that renders animated bars in the
/// now-playing UI.
///
/// `just_audio` exposes no PCM/FFT tap, so these levels are driven by the
/// UI rather than by real spectrum analysis. [emitLevels] is the injection
/// point a future native audio-tap could feed.
///
/// Implements [IVisualizerProvider] and registers itself under that
/// interface — [VisualizerBars] reads through the interface, so a future
/// real spectrum-analysis source could replace this plugin without the
/// widget changing. [emitLevels] itself stays plugin-specific (how a
/// provider *produces* levels varies; a real FFT-based source wouldn't
/// take injected values at all), the same read/write split
/// `LyricsPlugin`/`ILyricsProvider` established.
class VisualizerPlugin extends MusicPlugin implements IVisualizerProvider {
  final StreamController<List<double>> _levelsController =
      StreamController.broadcast();

  /// Number of bars the widget renders.
  static const barCount = 8;

  List<double> _latest = List.filled(barCount, 0.2);

  /// The most recently emitted levels, so a widget that subscribes late
  /// still renders something rather than flat bars.
  @override
  List<double> get latest => List.unmodifiable(_latest);

  @override
  Stream<List<double>> get levels => _levelsController.stream;

  void emitLevels(List<double> levels) {
    if (_levelsController.isClosed) return;
    _latest = List<double>.from(levels);
    _levelsController.add(_latest);
  }

  @override
  String get id => 'visualizer';

  @override
  String get name => 'Visualizer';

  @override
  String get description =>
      'Shows a simple animated spectrum for the current track.';

  @override
  String get version => '1.0.0';

  @override
  String get author => 'Omnis Team';

  @override
  Future<void> initialize() async {
    context?.services.register(IVisualizerProvider, this);
  }

  @override
  Future<void> onTrackStart(BaseTrack track) async {}

  @override
  Future<void> onLibraryScan(String file) async {}

  @override
  dynamic uiSlot(String locationID) => null;

  @override
  Future<void> enable() async {
    context?.services.register(IVisualizerProvider, this);
  }

  @override
  Future<void> disable() async {
    context?.services.unregister(IVisualizerProvider, this);
  }

  @override
  Future<void> dispose() async {
    context?.services.unregister(IVisualizerProvider, this);
    await _levelsController.close();
  }
}

/// Animated bar display driven by an [IVisualizerProvider].
class VisualizerBars extends StatefulWidget {
  final IVisualizerProvider plugin;

  const VisualizerBars({super.key, required this.plugin});

  @override
  State<VisualizerBars> createState() => _VisualizerBarsState();
}

class _VisualizerBarsState extends State<VisualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final StreamSubscription<List<double>> _sub;
  late List<double> _levels;

  @override
  void initState() {
    super.initState();
    _levels = widget.plugin.latest;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
    _sub = widget.plugin.levels.listen((levels) {
      if (mounted) setState(() => _levels = levels);
    });
  }

  @override
  void dispose() {
    // Cancel the subscription before disposing the controller so a level
    // event in flight can't call setState on a half-disposed State.
    _sub.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_levels.length, (index) {
            final base = _levels[index].clamp(0.0, 1.0);
            final height = 18.0 +
                base * 70.0 +
                (progress * 10.0 * ((index % 2) == 0 ? 1 : -1));
            return Container(
              width: 8,
              height: height,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        );
      },
    );
  }
}
