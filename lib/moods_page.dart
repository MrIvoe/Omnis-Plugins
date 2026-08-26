import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/custom_mood.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/custom_mood_store.dart';
import 'package:omnis_plugins/forgotten_music_page.dart';
import 'package:omnis_plugins/mood_builder_dialog.dart';

/// Moods tab: a grid of preset mood tiles (every query any registered
/// [IQueueBuilder] reports) plus the user's own rule-based custom moods,
/// each tap building a real queue from the real library and starting
/// playback.
///
/// Moved here from the Omnis app's own `lib/ui/home_page.dart`, where it
/// used to be one of the hardcoded core tabs (Tier 2 task 4) — it's now
/// owned by `MoodsPlugin`, which contributes it as a `PluginDestination`.
/// The three app singletons it used to reach directly are replaced by the
/// equivalent [PluginContext] reads: `LibraryRepository.load` by
/// [PluginContext.loadLibraryTracks] and `AudioEngine.setQueue`/`play` by
/// [PluginContext.setQueue]/`play`. `IRatingsProvider`/
/// `IPlayHistoryProvider` were already looked up by capability interface
/// and simply move from `PluginManager.services` to
/// [PluginContext.services] — the same registry, reached from the plugin
/// side.
///
/// One real capability gap fell out of the move and is deliberately not
/// worked around, exactly as `HomeDashboardPage`'s own doc comment
/// describes for the identical gap: starting playback no longer pushes
/// the Now Playing screen afterward (this page used to take an
/// `onPlaybackStarted` callback that `home_page.dart` wired to a
/// `Navigator.push` of `NowPlayingPage`, which lives in the Omnis app and
/// isn't reachable from a bundled plugin). The always-visible mini-player
/// is still one tap away from the same screen.
class MoodsPage extends StatefulWidget {
  final PluginContext pluginContext;

  const MoodsPage({super.key, required this.pluginContext});

  @override
  MoodsPageState createState() => MoodsPageState();
}

class MoodsPageState extends State<MoodsPage> {
  bool _loading = false;
  List<CustomMood> _customMoods = [];

  @override
  void initState() {
    super.initState();
    _loadCustomMoods();
  }

  Future<void> _loadCustomMoods() async {
    final moods = await CustomMoodStore.instance.load();
    if (mounted) setState(() => _customMoods = moods);
  }

  /// The user's saved custom moods, as currently loaded by this page —
  /// backs this page's own grid (the tiles built alongside the preset
  /// moods in [build]). `MoodsPlugin.customMoods` no longer reads this
  /// getter: it reads `CustomMoodStore` directly instead, to avoid racing
  /// this page's own async [_loadCustomMoods] at app startup (see that
  /// getter's own doc comment for the full reasoning). Kept public mainly
  /// so [playCustomMood]/[_deleteCustomMood]/etc. and this page's own
  /// tests have one obvious place to read the currently-loaded list.
  List<CustomMood> get customMoods => List.unmodifiable(_customMoods);

  IRatingsProvider? get _ratings =>
      widget.pluginContext.services.get<IRatingsProvider>();

  IPlayHistoryProvider? get _playHistory =>
      widget.pluginContext.services.get<IPlayHistoryProvider>();

  Future<void> _createCustomMood() async {
    final library = await widget.pluginContext.loadLibraryTracks();
    final knownGenres = {for (final t in library) ...t.genres}.toList()
      ..sort();
    final knownMoodTags = {
      for (final t in library)
        if (t.mood != null && t.mood!.isNotEmpty) t.mood!,
    }.toList()
      ..sort();
    if (!mounted) return;
    final created = await Navigator.of(context).push<CustomMood>(
      MaterialPageRoute(
        builder: (context) => MoodBuilderPage(
          knownGenres: knownGenres,
          knownMoodTags: knownMoodTags,
        ),
      ),
    );
    if (created == null) return;
    final updated = [..._customMoods, created];
    await CustomMoodStore.instance.save(updated);
    if (mounted) setState(() => _customMoods = updated);
  }

  Future<void> _editCustomMood(CustomMood mood) async {
    final library = await widget.pluginContext.loadLibraryTracks();
    final knownGenres = {for (final t in library) ...t.genres}.toList()
      ..sort();
    final knownMoodTags = {
      for (final t in library)
        if (t.mood != null && t.mood!.isNotEmpty) t.mood!,
    }.toList()
      ..sort();
    if (!mounted) return;
    final edited = await Navigator.of(context).push<CustomMood>(
      MaterialPageRoute(
        builder: (context) => MoodBuilderPage(
          existing: mood,
          knownGenres: knownGenres,
          knownMoodTags: knownMoodTags,
        ),
      ),
    );
    if (edited == null) return;
    final updated = [
      for (final m in _customMoods) if (m.id == edited.id) edited else m,
    ];
    await CustomMoodStore.instance.save(updated);
    if (mounted) setState(() => _customMoods = updated);
  }

  Future<void> _deleteCustomMood(CustomMood mood) async {
    final updated = _customMoods.where((m) => m.id != mood.id).toList();
    await CustomMoodStore.instance.save(updated);
    if (mounted) setState(() => _customMoods = updated);
  }

  /// UI_SPEC §13's "Play Late Night Drive becomes an intelligent queue" —
  /// filters the library through [CustomMood.matches] rather than going
  /// through [_queueBuilders] (those serve the separate, fixed
  /// `supportedQueries` preset moods, not a user's own rule-based one).
  /// Same empty-library/empty-result snackbar UX and setQueue+play flow
  /// [playMood] already established, so a custom mood tile behaves
  /// identically to a preset one from the user's perspective.
  ///
  /// Public so `MoodsPlugin` can serve `IMoodPlayer.playCustomMood` — the
  /// pop-out sidebar's "MY MOODS" section plays a pinned custom mood
  /// through it — reusing this exact matching/snackbar-feedback logic
  /// rather than duplicating it.
  Future<void> playCustomMood(CustomMood mood) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final library = await widget.pluginContext.loadLibraryTracks();
      if (library.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your library is empty — add tracks in the Library tab first.',
            ),
          ),
        );
        return;
      }
      final ratingsProvider = _ratings;
      final playHistory = _playHistory;
      Set<String> recentlyPlayedIds = const {};
      if (mood.excludeRecentlyPlayedDays != null && playHistory != null) {
        final cutoff = DateTime.now()
            .subtract(Duration(days: mood.excludeRecentlyPlayedDays!));
        recentlyPlayedIds = playHistory
            .recentlyPlayed(limit: 2000)
            .where((r) => r.playedAt.isAfter(cutoff))
            .map((r) => r.trackId)
            .toSet();
      }
      final queue = library
          .where((track) => mood.matches(
                track,
                ratingOf: (id) => ratingsProvider?.ratingOf(id) ?? 0,
                recentlyPlayedIds: recentlyPlayedIds,
              ))
          .toList();
      if (queue.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No tracks match "${mood.name}" yet — try widening its '
              'genres, tempo range, or rating floor.',
            ),
          ),
        );
        return;
      }
      await widget.pluginContext.setQueue(queue);
      await widget.pluginContext.play();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Every registered `IQueueBuilder`, in registration order —
  /// `SmartPlaylistPlugin` (curated mood-tag matches) before
  /// `QueuePresetPlugin` (objective BPM/genre fallback), enforced by
  /// `bundled_plugins.dart`'s list order. Looked up by interface, not
  /// concrete plugin type, so a future third mood source registers here
  /// automatically.
  List<IQueueBuilder> get _queueBuilders =>
      widget.pluginContext.services.getAll<IQueueBuilder>();

  /// Builds a queue for [mood]/[preset] by trying every registered
  /// `IQueueBuilder` in order and keeping the first non-empty result.
  /// Previously this hardcoded exactly two concrete plugins and their
  /// fallback order by hand; every preset used to dead-end with "no
  /// tracks tagged" until the user had separately run metadata lookup or
  /// audio analysis, since only the mood-tag path was ever tried —
  /// "Sleep" (a preset only `QueuePresetPlugin` contributes) could never
  /// work at all.
  ///
  /// Public so `MoodsPlugin` can serve `IMoodPlayer.playMood` — the §37
  /// "search everywhere" command palette and the pop-out sidebar both
  /// play a preset mood through it — reusing this exact
  /// builder-fallback/snackbar-feedback logic rather than duplicating it.
  Future<void> playMood(String mood) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final library = await widget.pluginContext.loadLibraryTracks();
      if (library.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Your library is empty — add tracks in the Library tab first.',
            ),
          ),
        );
        return;
      }

      var queue = const <BaseTrack>[];
      var usedFallback = false;
      final builders = _queueBuilders;
      for (var i = 0; i < builders.length; i++) {
        final result = builders[i].buildQueueFor(library, mood);
        if (result.isNotEmpty) {
          queue = result;
          usedFallback = i > 0;
          break;
        }
      }

      if (queue.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No tracks tagged for "$mood" yet — mood matching uses '
              'each track\'s mood/genre metadata.',
            ),
          ),
        );
        return;
      }
      await widget.pluginContext.setQueue(queue);
      await widget.pluginContext.play();
      if (usedFallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No tracks tagged "$mood" yet — playing a BPM/genre-based '
              'match instead.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final presetMoods = <String>{
      for (final builder in _queueBuilders) ...builder.supportedQueries,
    }.toList();
    final now = DateTime.now();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Moods'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history_toggle_off),
            tooltip: 'Forgotten Music',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ForgottenMusicPage(pluginContext: widget.pluginContext),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _createCustomMood,
        tooltip: 'Create a mood',
        child: const Icon(Icons.add),
      ),
      body: Stack(
        children: [
          // A fixed `crossAxisCount: 2` looked sparse on a wide desktop
          // window (two ~800px-wide tiles) and wasted space in between,
          // but gave every width the same treatment. Deriving the column
          // count from available width keeps each tile close to a
          // ~200dp target width instead — floor-divided so tiles don't
          // shrink below that, clamped so it never drops below the
          // original 2-column minimum or grows unreasonably wide on a
          // very large window.
          LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount =
                  (constraints.maxWidth / 200).floor().clamp(2, 5);
              return GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  // Was 1.1 — too tight once a two-word preset name
                  // ("Forgotten Favorites") wraps to a second title line;
                  // taller cards give every tile real breathing room
                  // instead of the subtitle text touching the bottom
                  // edge. Still right once the column count varies: each
                  // tile's *width* stays pinned near the same ~200dp
                  // target regardless of column count (more columns
                  // only appear because more width is available), so
                  // this ratio keeps producing a similarly-proportioned
                  // tile at every width instead of needing a
                  // per-column-count value.
                  childAspectRatio: 0.95,
                ),
                itemCount: presetMoods.length + _customMoods.length,
                itemBuilder: (context, index) {
                  if (index < presetMoods.length) {
                    final mood = presetMoods[index];
                    return Card(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _loading ? null : () => playMood(mood),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          // A two-word mood/preset name (e.g. "Forgotten
                          // Favorites") wraps to a second line, which this
                          // fixed-aspect-ratio grid tile's height doesn't
                          // budget for — the single-word names this grid was
                          // originally built for (Chill/Focus/Workout/Sleep)
                          // never exposed that. Same `SingleChildScrollView`
                          // guard used elsewhere in this app for exactly
                          // "fixed-size content might not always fit."
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.mood,
                                    size: 36, color: theme.colorScheme.primary),
                                const SizedBox(height: 12),
                                Text(mood, style: theme.textTheme.titleMedium),
                                const SizedBox(height: 4),
                                Text('Tap to build and play a queue',
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }
                  final mood = _customMoods[index - presetMoods.length];
                  // UI_SPEC §14's "mood visuals": a user-picked color/icon
                  // identify this tile, distinct from every preset tile's
                  // generic `Icons.mood`/theme-primary look above.
                  final tileColor = mood.color ?? theme.colorScheme.primary;
                  return Card(
                    child: Stack(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: _loading ? null : () => playCustomMood(mood),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(mood.icon.icon,
                                      size: 36, color: tileColor),
                                  const SizedBox(height: 12),
                                  Text(mood.name,
                                      style: theme.textTheme.titleMedium),
                                  const SizedBox(height: 4),
                                  Text(
                                    mood.isInTimeWindow(now)
                                        ? 'Suggested now'
                                        : 'Tap to build and play a queue',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: PopupMenuButton<String>(
                            tooltip: 'Mood options',
                            onSelected: (value) {
                              if (value == 'edit') _editCustomMood(mood);
                              if (value == 'delete') _deleteCustomMood(mood);
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
          if (_loading)
            const ColoredBox(
              color: Colors.black26,
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}
