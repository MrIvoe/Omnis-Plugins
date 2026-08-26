import 'package:flutter/material.dart';
import 'package:omnis_plugin_api/base_track.dart';
import 'package:omnis_plugin_api/plugin_context.dart';
import 'package:omnis_plugin_api/service_interfaces.dart';
import 'package:omnis_plugins/custom_radio_station_store.dart';

/// "Online" tab (spec §63/item 38's "user access" gap): a single place to
/// reach every online music source — Radio (via [RadioBody], merged into
/// this same file — see that class's own doc comment for why), each
/// self-hosted connectivity plugin (Ampache/Koel/OpenSubsonic/Jellyfin/
/// Plex/Emby — any [IOnlineSearchProvider] that's both enabled and
/// [IOnlineSearchProvider.isConfigured]), and YouTube/Spotify.
///
/// Moved here from the Omnis app's own `lib/ui/online_page.dart` (Tier 2
/// task 5), where Radio was the only online source with a real tab; the
/// connectivity plugins had full working search backends
/// (`AmpachePlugin.search`, etc.) with **no UI anywhere** that called
/// them, and YouTube/Spotify playback were reachable only by burying into
/// Settings → Plugins → tap the plugin — this page is what makes "we have
/// a way of user access" to all of it actually true.
///
/// YouTube/Spotify are deliberately **not** [IOnlineSearchProvider]s (see
/// that interface's own doc comment): both only ever return metadata-only
/// tracks a real [AudioEngine] can't actually play. Rather than force them
/// through a "tap a result to play" contract they can't honestly satisfy,
/// their tabs embed each plugin's own existing `uiSlot('plugin_settings')`
/// widget directly — `YoutubePlaybackPlugin`'s real paste-a-URL-and-play
/// embedded player, `SpotifyPlaybackPlugin`'s real Spotify Connect
/// remote-control UI — reusing fully-working functionality instead of
/// inventing a new, misleading search-and-play UI neither plugin can
/// back up. Pre-extraction, this page reached each of those two plugins
/// directly by concrete-type-adjacent lookup
/// (`PluginManager.byId('youtube_playback')`/`.enabled` +
/// `PluginManager.uiSlotForPlugin(...)`) — both Omnis-app-only types a
/// bundled plugin can't reach. Both now register themselves under the new
/// [IEmbeddedPlaybackProvider] capability interface instead (see that
/// interface's own doc comment in `service_interfaces.dart` for the full
/// deviation writeup), and this page simply asks
/// `pluginContext.services.getAll<IEmbeddedPlaybackProvider>()` for
/// whichever ones are currently enabled — the same "ask the registry, not
/// a plugin's own enabled flag" pattern [IOnlineSearchProvider] already
/// uses here.
///
/// The three app singletons the pre-extraction page used to reach
/// directly (`AudioEngine`/`PluginManager.services`/
/// `PluginManager.byId`+`uiSlotForPlugin`) are replaced by the equivalent
/// [PluginContext] reads, the same substitution `HomeDashboardPage`/
/// `MoodsPage` already made for their own moves: `AudioEngine.setQueue`/
/// `play` by [PluginContext.setQueue]/`play`, `AudioEngine.currentTrack`
/// by [PluginContext.currentTrack], and every `services.get`/`getAll` call
/// simply moves from `PluginManager.services` to [PluginContext.services].
///
/// One small cosmetic gap fell out of the move: the old page fired
/// `OmnisHaptics.selectionClick()` (gated on the user's haptics setting)
/// when switching the section chip. `OmnisHaptics`/`AppSettings` are both
/// Omnis-app-only and unreachable from a bundled plugin — the same class
/// of gap `HomeDashboardPlugin`/`MoodsPlugin` already document for their
/// own app-only reaches — so switching chips here is silent. Nothing else
/// in this repo's other moved pages used haptics, so there's no
/// established plugin-side replacement to reuse.
class OnlinePage extends StatefulWidget {
  final PluginContext pluginContext;

  const OnlinePage({super.key, required this.pluginContext});

  @override
  State<OnlinePage> createState() => _OnlinePageState();
}

/// One selectable entry in the top selector bar.
enum _OnlineSectionKind { radio, searchProvider, embedded }

class _OnlineSection {
  final _OnlineSectionKind kind;
  final String label;
  final IOnlineSearchProvider? provider;
  final IEmbeddedPlaybackProvider? embeddedProvider;

  const _OnlineSection(this.kind, this.label,
      {this.provider, this.embeddedProvider});
}

class _OnlinePageState extends State<OnlinePage> {
  int _selectedIndex = 0;
  final _radioBodyKey = GlobalKey<RadioBodyState>();

  List<IOnlineSearchProvider> get _searchProviders => widget
      .pluginContext.services
      .getAll<IOnlineSearchProvider>()
      .where((p) => p.isConfigured)
      .toList();

  List<IEmbeddedPlaybackProvider> get _embeddedProviders =>
      widget.pluginContext.services.getAll<IEmbeddedPlaybackProvider>();

  List<_OnlineSection> get _sections {
    return [
      const _OnlineSection(_OnlineSectionKind.radio, 'Radio'),
      for (final provider in _searchProviders)
        _OnlineSection(_OnlineSectionKind.searchProvider,
            provider.providerName,
            provider: provider),
      for (final provider in _embeddedProviders)
        _OnlineSection(_OnlineSectionKind.embedded, provider.providerName,
            embeddedProvider: provider),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sections = _sections;
    // The set of available sections can shrink (a plugin disabled mid-
    // session) — clamp rather than index out of range.
    final selected = _selectedIndex >= sections.length ? 0 : _selectedIndex;
    final current = sections[selected];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Online'),
        actions: current.kind == _OnlineSectionKind.radio
            ? [
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add station',
                  onPressed: () => _radioBodyKey.currentState?.addStation(),
                ),
              ]
            : null,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < sections.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(sections[i].label),
                      selected: i == selected,
                      onSelected: (_) {
                        setState(() => _selectedIndex = i);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          Expanded(child: _buildSection(current)),
        ],
      ),
    );
  }

  Widget _buildSection(_OnlineSection section) {
    switch (section.kind) {
      case _OnlineSectionKind.radio:
        return RadioBody(
          key: _radioBodyKey,
          pluginContext: widget.pluginContext,
        );
      case _OnlineSectionKind.searchProvider:
        // A fresh key per provider so switching providers doesn't reuse
        // another provider's search results/text-field state.
        return _ProviderSearchView(
          key: ValueKey(section.provider!.providerName),
          pluginContext: widget.pluginContext,
          provider: section.provider!,
        );
      case _OnlineSectionKind.embedded:
        return _EmbeddedProviderBody(
          key: ValueKey(section.embeddedProvider!.providerName),
          provider: section.embeddedProvider!,
        );
    }
  }
}

/// Internet Radio section: search and browse live streaming stations, and
/// play one straight through the normal queue — a station is just a
/// [BaseTrack] with `type: TrackType.radio` and a real `streamUrl`, so
/// playback needs no special-casing at all ([PluginContext.setQueue]
/// already plays any track with a `streamUrl`).
///
/// Stations come from whichever plugin has registered itself as the
/// [IRadioProvider] capability, looked up through
/// `pluginContext.services.get<IRadioProvider>()`. The bundled
/// `RadioPlugin` (backed by the Radio Browser directory) is what provides
/// it in practice, but this widget never names that — or any other —
/// concrete plugin type; anything implementing the interface can back it
/// instead.
///
/// Merged into this file rather than kept as its own sibling
/// (`radio_page.dart`, Omnis app) — Tier 2 task 5's move. Before the move
/// this had exactly one consumer, [OnlinePage] (the standalone `RadioPage`
/// `Scaffold` wrapper it also used to back had zero production references
/// and was deleted outright), so there is no remaining reason to keep it
/// a separate file: no second host embeds it, and it already shares this
/// file's imports (`CustomRadioStationStore`, the online-tab service
/// interfaces) almost entirely. [addStation] stays public so
/// [OnlinePage]'s own AppBar action can trigger the add-station dialog
/// through the `GlobalKey<RadioBodyState>` it already holds — the same
/// "public method reached through a GlobalKey" pattern
/// `HomeDashboardPageState.openCustomizeSheet` established before this
/// task moved this code.
class RadioBody extends StatefulWidget {
  final PluginContext pluginContext;

  const RadioBody({super.key, required this.pluginContext});

  @override
  State<RadioBody> createState() => RadioBodyState();
}

class RadioBodyState extends State<RadioBody> {
  final _searchController = TextEditingController();
  List<BaseTrack> _stations = const [];
  List<CustomRadioStation> _customStations = const [];
  bool _loading = false;
  bool _searched = false;

  IRadioProvider? get _plugin =>
      widget.pluginContext.services.get<IRadioProvider>();

  IFavoritesProvider? get _favoritesProvider =>
      widget.pluginContext.services.get<IFavoritesProvider>();

  bool _isFavorite(String stationId) =>
      _favoritesProvider?.isFavorite(stationId) ?? false;

  /// [station] is passed through to [IFavoritesProvider.setFavorite] so a
  /// newly-favorited station gets a real snapshot captured (a station is
  /// never part of the scanned local library, so without one it would be
  /// genuinely favorited but invisible in the Playlists page's aggregate
  /// "Favorites" list).
  Future<void> _toggleFavorite(BaseTrack station) async {
    final provider = _favoritesProvider;
    if (provider == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No favorites provider is installed/enabled.'),
      ));
      return;
    }
    await provider.setFavorite(station.id, !provider.isFavorite(station.id),
        track: station);
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadTopStations();
    _loadCustomStations();
  }

  Future<void> _loadCustomStations() async {
    final stations = await CustomRadioStationStore.instance.load();
    if (!mounted) return;
    setState(() => _customStations = stations);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTopStations() async {
    final plugin = _plugin;
    if (plugin == null) return;
    setState(() => _loading = true);
    final stations = await plugin.topStations();
    if (!mounted) return;
    setState(() {
      _stations = stations;
      _loading = false;
      _searched = false;
    });
  }

  Future<void> _search(String query) async {
    final plugin = _plugin;
    if (plugin == null) return;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      await _loadTopStations();
      return;
    }
    setState(() => _loading = true);
    final stations = await plugin.searchStations(trimmed);
    if (!mounted) return;
    setState(() {
      _stations = stations;
      _loading = false;
      _searched = true;
    });
  }

  Future<void> _play(int index) async {
    await widget.pluginContext.setQueue(_stations, startIndex: index);
    await widget.pluginContext.play();
  }

  Future<void> _playCustom(CustomRadioStation station) async {
    await widget.pluginContext.setQueue([station.toTrack()]);
    await widget.pluginContext.play();
  }

  Future<void> _deleteCustomStation(CustomRadioStation station) async {
    final updated = await CustomRadioStationStore.instance.delete(station.id);
    if (!mounted) return;
    setState(() => _customStations = updated);
  }

  /// Prompts for a name + stream URL and, once both look real (a
  /// non-empty name, a URL that parses with an http/https scheme —
  /// no attempt to actually reach the stream first, the same
  /// "trust what's entered, fail at play time if it's wrong" stance a
  /// Radio Browser-fetched URL already gets), persists it via
  /// [CustomRadioStationStore]. Public so a host page's own AppBar
  /// action can trigger it through a `GlobalKey<RadioBodyState>`.
  Future<void> addStation() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add radio station'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Station name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'Stream URL',
                hintText: 'https://stream.example.com/live',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final name = nameController.text.trim();
    final url = urlController.text.trim();
    final uri = Uri.tryParse(url);
    final validUrl = uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
    if (name.isEmpty || !validUrl) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Enter a station name and a valid http(s) stream URL.'),
      ));
      return;
    }

    final updated = await CustomRadioStationStore.instance.add(name, url);
    if (!mounted) return;
    setState(() => _customStations = updated);
  }

  @override
  Widget build(BuildContext context) {
    final plugin = _plugin;
    if (plugin == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'The Internet Radio plugin is disabled in Settings.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search stations (e.g. "jazz", "BBC")',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _loadTopStations();
                      },
                    )
                  : null,
            ),
            onSubmitted: _search,
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    if (_customStations.isNotEmpty) ...[
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'My stations',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ),
                      for (final custom in _customStations)
                        _buildCustomStationTile(custom),
                      const Divider(),
                    ],
                    if (_stations.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _searched ? 'Search results' : 'Top stations',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ),
                    if (_stations.isEmpty && _customStations.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: Text(
                            _searched
                                ? 'No stations found.'
                                : 'No stations available right now.',
                          ),
                        ),
                      ),
                    for (var index = 0; index < _stations.length; index++)
                      _buildStationTile(_stations[index], index),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildStationTile(BaseTrack station, int index) {
    final current = widget.pluginContext.currentTrack;
    final isPlaying = current?.id == station.id;
    return ListTile(
      leading: _StationIcon(station: station),
      title: Text(
        station.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (station.artists.isNotEmpty) station.artists.first,
          if (station.genres.isNotEmpty) station.genres.take(2).join(', '),
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              _isFavorite(station.id) ? Icons.favorite : Icons.favorite_border,
            ),
            color: _isFavorite(station.id)
                ? Theme.of(context).colorScheme.primary
                : null,
            tooltip: _isFavorite(station.id)
                ? 'Remove from favorites'
                : 'Add to favorites',
            onPressed: () => _toggleFavorite(station),
          ),
          isPlaying
              ? Icon(Icons.graphic_eq, color: Theme.of(context).colorScheme.primary)
              : const Icon(Icons.play_circle_outline),
        ],
      ),
      onTap: () => _play(index),
    );
  }

  Widget _buildCustomStationTile(CustomRadioStation custom) {
    final current = widget.pluginContext.currentTrack;
    final isPlaying = current?.id == custom.id;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.radio)),
      title: Text(
        custom.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        custom.streamUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              _isFavorite(custom.id) ? Icons.favorite : Icons.favorite_border,
            ),
            color: _isFavorite(custom.id)
                ? Theme.of(context).colorScheme.primary
                : null,
            tooltip:
                _isFavorite(custom.id) ? 'Remove from favorites' : 'Add to favorites',
            onPressed: () => _toggleFavorite(custom.toTrack()),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove station',
            onPressed: () => _deleteCustomStation(custom),
          ),
          isPlaying
              ? Icon(Icons.graphic_eq, color: Theme.of(context).colorScheme.primary)
              : const Icon(Icons.play_circle_outline),
        ],
      ),
      onTap: () => _playCustom(custom),
    );
  }
}

/// A station's favicon when it has one and it actually loads, otherwise a
/// generic radio icon — never a broken-image placeholder. Deliberately
/// separate from `TrackArtwork`: that resolves *real* embedded/MediaStore
/// artwork for local/library tracks and caches decoded bytes in memory, a
/// different contract from a plain remote favicon URL that `Image.network`
/// already caches on its own.
class _StationIcon extends StatelessWidget {
  final BaseTrack station;

  const _StationIcon({required this.station});

  @override
  Widget build(BuildContext context) {
    final favicon = station.coverArt;
    const size = 40.0;
    if (favicon == null || favicon.isEmpty) {
      return const CircleAvatar(
        radius: size / 2,
        child: Icon(Icons.radio),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        favicon,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const CircleAvatar(
          radius: size / 2,
          child: Icon(Icons.radio),
        ),
      ),
    );
  }
}

/// Search-and-play for one [IOnlineSearchProvider] — a self-hosted server
/// whose results are real, directly playable [BaseTrack]s, so this
/// mirrors [RadioBody]'s own search-box-plus-list shape rather than
/// inventing a different pattern for what's functionally the same kind
/// of source. No "top results on open" the way Radio has (Radio Browser
/// has a real "most voted" endpoint; a generic media server's `search`
/// has no equivalent "show me something" query), so this starts empty
/// with a prompt instead.
class _ProviderSearchView extends StatefulWidget {
  final PluginContext pluginContext;
  final IOnlineSearchProvider provider;

  const _ProviderSearchView({
    super.key,
    required this.pluginContext,
    required this.provider,
  });

  @override
  State<_ProviderSearchView> createState() => _ProviderSearchViewState();
}

class _ProviderSearchViewState extends State<_ProviderSearchView> {
  final _searchController = TextEditingController();
  List<BaseTrack> _results = const [];
  bool _loading = false;
  bool _searched = false;

  IFavoritesProvider? get _favoritesProvider =>
      widget.pluginContext.services.get<IFavoritesProvider>();

  bool _isFavorite(String trackId) =>
      _favoritesProvider?.isFavorite(trackId) ?? false;

  Future<void> _toggleFavorite(BaseTrack track) async {
    final provider = _favoritesProvider;
    if (provider == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No favorites provider is installed/enabled.'),
      ));
      return;
    }
    await provider.setFavorite(track.id, !provider.isFavorite(track.id),
        track: track);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = const [];
        _searched = false;
      });
      return;
    }
    setState(() => _loading = true);
    final results = await widget.provider.search(trimmed);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
      _searched = true;
    });
  }

  Future<void> _play(int index) async {
    await widget.pluginContext.setQueue(_results, startIndex: index);
    await widget.pluginContext.play();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search ${widget.provider.providerName}',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _results = const [];
                          _searched = false;
                        });
                      },
                    )
                  : null,
            ),
            onSubmitted: _search,
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : !_searched
                  ? Center(
                      child: Text(
                        'Search ${widget.provider.providerName}\'s library.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : _results.isEmpty
                      ? const Center(child: Text('No matches found.'))
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, index) =>
                              _buildResultTile(_results[index], index),
                        ),
        ),
      ],
    );
  }

  Widget _buildResultTile(BaseTrack track, int index) {
    final current = widget.pluginContext.currentTrack;
    final isPlaying = current?.id == track.id;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.cloud_queue)),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        track.artists.isNotEmpty ? track.artists.join(', ') : 'Unknown artist',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(
              _isFavorite(track.id) ? Icons.favorite : Icons.favorite_border,
            ),
            color: _isFavorite(track.id)
                ? Theme.of(context).colorScheme.primary
                : null,
            tooltip: _isFavorite(track.id)
                ? 'Remove from favorites'
                : 'Add to favorites',
            onPressed: () => _toggleFavorite(track),
          ),
          isPlaying
              ? Icon(Icons.graphic_eq, color: Theme.of(context).colorScheme.primary)
              : const Icon(Icons.play_circle_outline),
        ],
      ),
      onTap: () => _play(index),
    );
  }
}

/// Renders exactly one [IEmbeddedPlaybackProvider]'s own
/// [IEmbeddedPlaybackProvider.buildSettingsSlot] widget as a tab body —
/// the same widget `PluginSettingsPage` would show for that plugin, just
/// without that page's own Scaffold/AppBar/description-card chrome, since
/// here it's one section among several under the Online tab's own shared
/// AppBar.
///
/// Pre-extraction this loaded a plugin's `uiSlot('plugin_settings')`
/// *asynchronously* via `PluginManager.uiSlotForPlugin` (a
/// `Future`-returning sandboxed call, needed only because that path could
/// run arbitrary/downloaded-plugin code) — [buildSettingsSlot] is a
/// synchronous, direct call for a bundled plugin, so this widget needs no
/// loading state of its own any more.
class _EmbeddedProviderBody extends StatelessWidget {
  final IEmbeddedPlaybackProvider provider;

  const _EmbeddedProviderBody({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final content = provider.buildSettingsSlot();
    if (content is! Widget) {
      return Center(
        child: Text('${provider.providerName} has nothing to show here.'),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: content,
    );
  }
}
