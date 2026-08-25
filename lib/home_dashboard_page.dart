import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/events.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugin_api/track_play_stats.dart';
import 'package:omnis_plugins/home_layout_store.dart';
import 'package:omnis_plugins/reorder_menu_button.dart';
import 'package:omnis_plugins/track_artwork.dart';

/// Home tab: Recently Played / Most Played / Recently Added / Continue
/// Listening / Favorites / Most Skipped, each a horizontally-scrolling
/// row of cards.
///
/// Recently Played/Most Played/Continue Listening/Most Skipped are
/// sourced from [PluginContext.loadRecentlyPlayed]/`loadMostPlayed`/
/// `loadContinueListening`/`loadMostSkipped` (core, always on — works
/// regardless of whether the optional `ScrobblePlugin` is installed).
/// Favorites reads whatever's registered as `IFavoritesProvider` — the
/// section simply doesn't render if nothing's registered or nothing's
/// favorited, the same graceful-absence pattern used throughout this
/// app.
///
/// Moved here from the Omnis app's own `lib/ui/home_dashboard_page.dart`
/// (Tier 2 task 3) — this page is now owned by `HomeDashboardPlugin`,
/// which contributes it as a `PluginDestination` rather than
/// `home_page.dart` constructing it directly. Two real capability gaps
/// fell out of that move and are deliberately **not** worked around
/// here (see the plugin's own doc comment / the task report for the
/// reasoning):
///
///  - No live "library changed" signal is reachable from a bundled
///    plugin (`PluginContext` only offers a one-shot
///    [PluginContext.loadLibraryTracks], not a change stream) — a tag
///    edit or delete made on the Library tab while this page is already
///    mounted still doesn't refresh Recently Added immediately; it
///    catches up the next time a track-change or favorite-change event
///    fires this page's own [_load]. A **scan** specifically is covered
///    though: `MusicPlugin.onLibraryScan(String file)` already fires
///    per-file during one, and `HomeDashboardPlugin` debounces those
///    into a single call to [refreshAfterLibraryScan] once the scan goes
///    quiet, so Recently Added catches up right after a scan completes
///    without needing a genuine change-event stream.
///  - Tapping a card starts playback via [PluginContext.setQueue]/`play`
///    but no longer pushes Now Playing afterward — `NowPlayingPage`
///    lives in the Omnis app and isn't reachable from a bundled plugin.
///    The always-visible `MiniPlayerBar` (which starts showing/updating
///    the instant playback starts) is still one tap away from the same
///    screen.
class HomeDashboardPage extends StatefulWidget {
  final PluginContext pluginContext;

  const HomeDashboardPage({
    super.key,
    required this.pluginContext,
  });

  @override
  HomeDashboardPageState createState() => HomeDashboardPageState();
}

class _HomeSection {
  final String id;
  final String title;
  final List<BaseTrack> tracks;
  const _HomeSection(this.id, this.title, this.tracks);
}

class HomeDashboardPageState extends State<HomeDashboardPage> {
  bool _loading = true;
  List<BaseTrack> _recentlyPlayed = const [];
  List<BaseTrack> _mostPlayed = const [];
  List<BaseTrack> _recentlyAdded = const [];
  List<BaseTrack> _continueListening = const [];
  List<BaseTrack> _favorites = const [];
  List<BaseTrack> _mostSkipped = const [];
  List<HomeSectionPreference> _layout = const [];

  StreamSubscription<BaseTrack?>? _trackSub;
  StreamSubscription<FavoriteChangedEvent>? _favoriteSub;

  @override
  void initState() {
    super.initState();
    _load();
    // Keep every section fresh while this tab stays alive in the
    // background (HomePage's IndexedStack never disposes it) — otherwise
    // returning to Home after playing or favoriting something elsewhere
    // would show stale data until some unrelated rebuild happened to
    // occur. Same event-bus pattern playlist_page.dart's Favorites smart
    // list already uses to decouple from FavoritesPlugin.
    _trackSub = widget.pluginContext.trackStream.listen((_) => _load());
    _favoriteSub =
        widget.pluginContext.events.on<FavoriteChangedEvent>().listen((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _trackSub?.cancel();
    _favoriteSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final library = await widget.pluginContext.loadLibraryTracks();
    final libraryById = {for (final t in library) t.id: t};

    // A played track that was never scanned/imported into the library —
    // a radio station, a Spotify/YouTube/Jellyfin/Plex/Subsonic/DLNA/
    // Emby track — has no entry in `libraryById` by definition, but its
    // play was still genuinely recorded. `TrackPlayStats.trackSnapshot`
    // (captured at record time, only for a non-local track) is the
    // fallback that makes it displayable/replayable here too instead of
    // the entry silently vanishing — item 41's "recorded but never
    // rendered" gap.
    // A snapshot decode failure (a corrupted/partially-written record,
    // the same real-world failure mode every other JSON-backed store in
    // this app defends against per-entry) must skip just that one
    // history entry, not the whole dashboard load.
    BaseTrack? decodeSnapshot(Map<String, dynamic> json) {
      try {
        return BaseTrack.fromJson(json);
      } catch (_) {
        return null;
      }
    }

    List<BaseTrack> joinStats(List<TrackPlayStats> stats) => [
          for (final s in stats)
            if (libraryById[s.trackId] != null)
              libraryById[s.trackId]!
            else if (s.trackSnapshot != null)
              if (decodeSnapshot(s.trackSnapshot!) case final track?) track,
        ];

    final recentlyPlayed =
        joinStats(await widget.pluginContext.loadRecentlyPlayed());
    final mostPlayed = joinStats(await widget.pluginContext.loadMostPlayed());
    final continueListening =
        joinStats(await widget.pluginContext.loadContinueListening());
    final mostSkipped =
        joinStats(await widget.pluginContext.loadMostSkipped());

    final recentlyAdded = library.where((t) => t.dateAdded != null).toList()
      ..sort((a, b) => b.dateAdded!.compareTo(a.dateAdded!));

    final favorites = widget.pluginContext.services
            .get<IFavoritesProvider>()
            ?.favoritesWithSnapshots(library) ??
        const <BaseTrack>[];

    final layout = await HomeLayoutStore.instance.load();

    if (!mounted) return;
    setState(() {
      _recentlyPlayed = recentlyPlayed;
      _mostPlayed = mostPlayed;
      _recentlyAdded = recentlyAdded.take(20).toList();
      _continueListening = continueListening;
      _favorites = favorites.take(20).toList();
      _mostSkipped = mostSkipped;
      _layout = layout;
      _loading = false;
    });
  }

  /// Item 45's "0% for Home" gap — a real, persisted customization of
  /// section order/visibility, the tractable slice of the spec's larger
  /// "widget canvas" vision for a fixed set of sections rather than
  /// freely-composable ones. Opens a modal sheet to reorder/hide the
  /// six known sections; on close, saves via [HomeLayoutStore] and
  /// reloads so [applyHomeLayout] picks up the change immediately.
  ///
  /// Public (this class isn't private, unlike most page `State`s in this
  /// app) so `HomeDashboardPlugin` (which implements `IHomeCustomizer`
  /// for the command palette's item 48/spec §38 "Customize home" action)
  /// can trigger it via a `GlobalKey` it owns itself — the sheet itself
  /// lives entirely here, the plugin class never needs to know its
  /// shape, only that opening it and reloading is one call away.
  Future<void> openCustomizeSheet() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _HomeCustomizeSheet(),
    );
    if (changed == true) await _load();
  }

  /// Called by `HomeDashboardPlugin.onLibraryScan` (via its own debounce
  /// — `onLibraryScan` fires once per file during a scan, not once
  /// overall) once a scan goes quiet, so Recently Added picks up files
  /// the scan just added. Public, like [openCustomizeSheet], for the same
  /// `GlobalKey`-reach reason — the plugin owns the key, this page owns
  /// the reload logic.
  Future<void> refreshAfterLibraryScan() => _load();

  Future<void> _play(List<BaseTrack> section, int index) async {
    await widget.pluginContext.setQueue(section, startIndex: index);
    await widget.pluginContext.play();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final defaultSections = <_HomeSection>[
      if (_continueListening.isNotEmpty)
        _HomeSection(
            'continue_listening', 'Continue Listening', _continueListening),
      if (_recentlyPlayed.isNotEmpty)
        _HomeSection('recently_played', 'Recently Played', _recentlyPlayed),
      if (_mostPlayed.isNotEmpty)
        _HomeSection('most_played', 'Most Played', _mostPlayed),
      if (_recentlyAdded.isNotEmpty)
        _HomeSection('recently_added', 'Recently Added', _recentlyAdded),
      if (_favorites.isNotEmpty)
        _HomeSection('favorites', 'Favorites', _favorites),
      if (_mostSkipped.isNotEmpty)
        _HomeSection('most_skipped', 'Most Skipped', _mostSkipped),
    ];
    final sections = applyHomeLayout(defaultSections, _layout, (s) => s.id);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Customize',
            onPressed: openCustomizeSheet,
          ),
        ],
      ),
      body: sections.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Play some music to see it here.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [for (final s in sections) _buildSection(s)],
            ),
    );
  }

  Widget _buildSection(_HomeSection section) {
    final theme = Theme.of(context);
    // The 190px row height was sized for the 130x130 art tile + a 6px
    // gap + two single-line text rows at the *default* 1.0x text scale
    // (130 + 6 + 20 + 16 = 172, leaving ~18px of slack). At
    // `AppSettings.textScaleFactor`'s own clamp ceiling of 1.5x (see
    // `clampTextScale`), the two text rows alone grow to 30 + 24 = 54px
    // — a confirmed render at that exact scale shows the card's content
    // then totals exactly 190px, leaving zero slack (verified via a
    // direct widget-tree measurement, not the approximate arithmetic
    // above), one rounding/locale/font-substitution nudge away from
    // clipping. A damped scale (full growth is deliberately avoided —
    // ballooning the whole horizontal-scroll row for a bit of extra
    // text headroom would look wrong on its own) restores real margin
    // at the ceiling without changing anything below 1.0x scale.
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);
    final sectionHeight = textScale > 1.0
        ? 190.0 * (1.0 + (textScale - 1.0) * 0.4)
        : 190.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(section.title, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 8),
          SizedBox(
            key: ValueKey('home_section_${section.title}'),
            height: sectionHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: section.tracks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final track = section.tracks[index];
                return _HomeCard(
                  track: track,
                  onTap: () => _play(section.tracks, index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal sheet for item 45's Home customization: drag-to-reorder plus a
/// visibility checkbox for each of the six known sections
/// ([homeSectionCatalog]) — listed regardless of whether that section
/// currently has anything to show, so a user can pre-arrange a section
/// before it ever has content. Builds its working list from whatever's
/// already saved (defaulting to catalog order, all visible, when
/// nothing has ever been customized) and only writes to
/// [HomeLayoutStore] once, when the sheet closes — not on every drag/
/// toggle — the same "the dialog builds the value, caller applies it"
/// split this app's other builder-style dialogs already use.
class _HomeCustomizeSheet extends StatefulWidget {
  const _HomeCustomizeSheet();

  @override
  State<_HomeCustomizeSheet> createState() => _HomeCustomizeSheetState();
}

class _HomeCustomizeSheetState extends State<_HomeCustomizeSheet> {
  List<HomeSectionPreference> _prefs = [];
  bool _loading = true;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final saved = await HomeLayoutStore.instance.load();
    final byId = {for (final p in saved) p.sectionId: p};
    // Every known section, in the saved order first, then any section
    // never mentioned in a save (nothing customized yet, or a section
    // added since) appended at the end — the same precedence
    // [applyHomeLayout] itself uses.
    final ordered = <HomeSectionPreference>[
      for (final p in saved)
        if (homeSectionCatalog.containsKey(p.sectionId)) p,
      for (final id in homeSectionCatalog.keys)
        if (!byId.containsKey(id))
          HomeSectionPreference(sectionId: id, visible: true),
    ];
    if (!mounted) return;
    setState(() {
      _prefs = ordered;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await HomeLayoutStore.instance.save(_prefs);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _resetToDefault() async {
    await HomeLayoutStore.instance.save(const []);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The whole sheet scrolls together (SingleChildScrollView), not just
    // the section list — six sections plus the header/button can exceed
    // a short screen's height, and everything (including "Done") needs
    // to stay reachable. The ReorderableListView inside uses
    // `shrinkWrap: true` + `NeverScrollableScrollPhysics` so it sizes to
    // its own content and hands scroll gestures up to the outer
    // scrollable — drag-to-reorder is a distinct long-press gesture, so
    // it's unaffected by the inner list not handling plain scroll drags.
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Customize Home', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: _resetToDefault,
                    child: const Text('Reset'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Drag to reorder, or hide a section entirely.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  onReorder: (oldIndex, newIndex) => setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final item = _prefs.removeAt(oldIndex);
                    _prefs.insert(newIndex, item);
                    _changed = true;
                  }),
                  children: [
                    for (var i = 0; i < _prefs.length; i++)
                      CheckboxListTile(
                        key: ValueKey(_prefs[i].sectionId),
                        value: _prefs[i].visible,
                        // The checkbox itself already owns this tile's
                        // trailing slot (CheckboxListTile's default
                        // `controlAffinity`) — `secondary` is the widget
                        // shown on the opposite (leading) side, the only
                        // slot left for the keyboard-reachable reorder
                        // fallback below.
                        secondary: ReorderMenuButton(
                          index: i,
                          lastIndex: _prefs.length - 1,
                          onReorder: (oldIndex, newIndex) => setState(() {
                            if (newIndex > oldIndex) newIndex -= 1;
                            final item = _prefs.removeAt(oldIndex);
                            _prefs.insert(newIndex, item);
                            _changed = true;
                          }),
                        ),
                        title: Text(homeSectionCatalog[_prefs[i].sectionId] ??
                            _prefs[i].sectionId),
                        onChanged: (value) => setState(() {
                          _prefs[i] =
                              _prefs[i].copyWith(visible: value ?? true);
                          _changed = true;
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed:
                    _changed ? _save : () => Navigator.of(context).pop(false),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  final BaseTrack track;
  final VoidCallback onTap;

  const _HomeCard({required this.track, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: TrackArtwork(
                track: track,
                width: 130,
                height: 130,
                iconSize: 40,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              track.artists.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
