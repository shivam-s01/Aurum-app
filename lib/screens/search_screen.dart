import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';

import '../services/browse_service.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../widgets/aurum_empty_state.dart';
import 'full_player_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Staggered list item — fade + slide up, same system as home_screen.dart's
// _StaggeredSection. Capped delay so long result lists don't take forever
// to finish animating in; items beyond the cap appear immediately.
// ─────────────────────────────────────────────────────────────────────────────
class _StaggeredItem extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredItem({required this.index, required this.child});

  @override
  State<_StaggeredItem> createState() => _StaggeredItemState();
}

class _StaggeredItemState extends State<_StaggeredItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    final cappedIndex = widget.index.clamp(0, 10);
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    Future.delayed(Duration(milliseconds: 20 + cappedIndex * 35), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _slide, child: child),
      ),
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faded horizontal list edges — same lightweight ShaderMask trick as
// home_screen.dart, so horizontal rows feel consistent across the app.
// ─────────────────────────────────────────────────────────────────────────────
class _FadedHorizontalList extends StatelessWidget {
  final Widget child;
  final double height;
  const _FadedHorizontalList({required this.child, required this.height});

  @override
  Widget build(BuildContext context) {
    final bg = AurumTheme.bgOf(context);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: 0, top: 0, bottom: 0,
            width: 20,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [bg, bg.withOpacity(0.0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 0, top: 0, bottom: 0,
            width: 20,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [bg, bg.withOpacity(0.0)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode  = FocusNode();

  // Tab controller: 0 = Search, 1 = Browse
  late final TabController _tabController;

  // Search tab state
  List<Song>   _results     = [];
  List<Song>   _liveResults = [];
  List<String> _suggestions = [];
  List<String> _history     = [];
  bool _loading     = false;
  bool _liveLoading = false;
  bool _showHistory = false;

  // Browse tab state
  bool              _browseLoading = false;
  BrowseSearchResult _browseResult = BrowseSearchResult.empty();
  String            _lastBrowseQuery = '';

  Timer? _debounce;
  Timer? _suggestDebounce;

  static const _prefKey    = 'aurum_search_history';
  static const _maxHistory = 10;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadHistory();
    _focusNode.addListener(_onFocusChange);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    // Ping Saavn backend the moment search opens — absorbs Render free-tier
    // cold-start delay before the user finishes typing their query.
    ApiService.wakeSaavn();
  }

  // FIX: SearchScreen sits in an IndexedStack — it's never disposed when the
  // user switches tabs, just hidden. If the TextField had focus, that focus
  // (and the keyboard) stays alive in the background. Any rebuild triggered
  // by PlayerProvider (song change, position update) can cause Android to
  // resurface the keyboard even on a completely different tab.
  //
  // didUpdateWidget fires every time the parent rebuilds this widget. When
  // the search tab is no longer visible (user switched away), we drop focus
  // immediately so there's nothing for Android to resurface.
  //
  // We detect visibility via ModalRoute.of(context)?.isCurrent — if the
  // search tab is not the active tab, the route is not current and we unfocus.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // STRICT keyboard policy: when this screen is not the active tab,
    // force-unfocus AND block any future focus requests on the node.
    // canRequestFocus=false means even if PlayerProvider triggers a rebuild
    // (song change, position update) the TextField can never auto-grab focus
    // and resurface the keyboard. It's re-enabled only when user explicitly
    // taps the search bar (onTap on the TextField container).
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (!isCurrent) {
      if (_focusNode.hasFocus) _focusNode.unfocus();
      _focusNode.canRequestFocus = false;
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } else {
      _focusNode.canRequestFocus = true;
    }
  }

  void _onFocusChange() {
    if (!mounted) return;
    final shouldShowHistory =
        _focusNode.hasFocus && _controller.text.trim().isEmpty && _history.isNotEmpty;
    // Only rebuild when the value actually changes — repeated identical
    // setState calls from focus flicker (tab switches, list touches) were
    // the root cause of the keyboard opening/closing repeatedly.
    if (shouldShowHistory != _showHistory) {
      setState(() => _showHistory = shouldShowHistory);
    }
  }

  void _dismissKeyboard() {
    if (_focusNode.hasFocus) {
      _suggestDebounce?.cancel();
      _focusNode.unfocus();
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    _tabController.dispose();
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    super.dispose();
  }

  // ── History ──────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() { _history = prefs.getStringList(_prefKey) ?? []; });
  }

  Future<void> _saveToHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    _history.remove(q);
    _history.insert(0, q);
    if (_history.length > _maxHistory) _history = _history.sublist(0, _maxHistory);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, _history);
    if (mounted) setState(() {});
  }

  Future<void> _removeFromHistory(String query) async {
    _history.remove(query);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefKey, _history);
    if (mounted) setState(() {});
  }

  Future<void> _clearHistory() async {
    _history.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    if (mounted) setState(() => _showHistory = false);
  }

  // ── Search logic ─────────────────────────────────────────────

  void _onChanged(String q) {
    _suggestDebounce?.cancel();
    final query = q.trim();

    if (query.isEmpty) {
      setState(() {
        _suggestions  = [];
        _liveResults  = [];
        _liveLoading  = false;
        _showHistory  = _history.isNotEmpty && _focusNode.hasFocus;
      });
      return;
    }

    setState(() { _showHistory = false; _liveLoading = true; });

    _suggestDebounce = Timer(const Duration(milliseconds: 280), () async {
      if (!mounted || _controller.text.trim() != query) return;

      // Fire both independently — whichever resolves first updates the UI
      // immediately. Previously these were awaited together, so a slow
      // autocomplete call could hold up already-ready song results.
      ApiService.quickSearch(query).then((songs) {
        if (!mounted || _controller.text.trim() != query) return;
        setState(() {
          _liveResults = songs;
          _liveLoading = false;
        });
      });

      ApiService.suggest(query).then((suggestions) {
        if (!mounted || _controller.text.trim() != query) return;
        setState(() => _suggestions = suggestions);
      });

      // also trigger browse if on Browse tab
      if (_tabController.index == 1) _fetchBrowse(query);
    });
  }

  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    HapticFeedback.lightImpact();
    _dismissKeyboard();
    setState(() { _loading = true; _liveLoading = false; _showHistory = false; _results = []; });
    _saveToHistory(query);
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final results = await ApiService.search(query);
      if (mounted) setState(() { _results = results; _loading = false; });
    });
  }

  void _clearSearch() {
    HapticFeedback.lightImpact();
    _suggestDebounce?.cancel();
    _debounce?.cancel();
    _controller.clear();
    // STRICT: do NOT requestFocus here — user cleared the text but that
    // doesn't mean they want the keyboard back. They can tap the bar again.
    setState(() {
      _results = []; _liveResults = []; _suggestions = [];
      _liveLoading = false; _loading = false;
      _showHistory = _history.isNotEmpty;
      
      _browseResult = BrowseSearchResult.empty();
      _lastBrowseQuery = '';
    });
  }


  Future<void> _fetchBrowse(String query) async {
    if (query == _lastBrowseQuery) return;
    _lastBrowseQuery = query;
    setState(() => _browseLoading = true);
    final result = await BrowseService.search(query);
    if (mounted && _lastBrowseQuery == query) {
      setState(() { _browseResult = result; _browseLoading = false; });
    }
  }


  Future<void> _playBrowseTrack(BrowseTrack track) async {
    HapticFeedback.lightImpact();
    _dismissKeyboard();
    // Convert to Song using the resolve query, then play via PlayerProvider
    final song = Song(
      id:         'browse_${track.trackId}',
      title:      track.title,
      artist:     track.artist,
      album:      track.album,
      artworkUrl: track.artworkUrl,
      duration:   track.durationMs != null ? (track.durationMs! / 1000).round() : null,
      source:     SongSource.saavn, // will resolve via Saavn first
    );
    if (mounted) {
      context.read<PlayerProvider>().playSong(song, queue: [song], index: 0);
      Navigator.of(context).push(
        PageRouteBuilder(
          // FIX: opaque:false made Flutter treat SearchScreen as possibly
          // still visible underneath, so it stopped fully repainting this
          // route while FullPlayerScreen was open. On pop, SearchScreen's
          // last (stale) frame stayed frozen — showing as a blank
          // white/black screen until some other state change forced a
          // rebuild. FullPlayerScreen already paints its own full opaque
          // background (_BgLayer), so marking this route opaque:true loses
          // no visual effect and fixes the freeze.
          opaque: true,
          pageBuilder: (_, __, ___) => const FullPlayerScreen(),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 380),
        ),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  String _computeBodyKey() {
    if (_loading) return 'loading';
    if (_results.isNotEmpty) return 'results';
    if (_controller.text.trim().isNotEmpty) return 'live';
    if (_showHistory && _history.isNotEmpty) return 'history';
    return 'empty';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _dismissKeyboard,
      // Opaque, not translucent: translucent let every tap (including
      // taps that land on TextField/SongTile/TabBar) also bubble through
      // this detector, causing focus to flicker on/off and the keyboard
      // to repeatedly open/close. Opaque only fires for taps that don't
      // land on an interactive child first.
      behavior: HitTestBehavior.opaque,
      child: Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(context),
              _buildSearchBar(context),
              // tab bar
              _buildTabBar(context),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  // NeverScrollableScrollPhysics: prevents swipe-between-tabs
                  // from triggering focus events that reopen the keyboard.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    // Tab 0: existing search
                    ColoredBox(
                      color: AurumTheme.bgOf(context),
                      child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) {
                        final slide = Tween<Offset>(
                          begin: const Offset(0, 0.05),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
                        final scale = Tween<double>(begin: 0.97, end: 1.0)
                            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: slide,
                            child: ScaleTransition(scale: scale, child: child),
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey(_computeBodyKey()),
                        child: _buildBody(context),
                      ),
                    ),
                    ),  // ColoredBox
                    // Tab 1: Browse
                    
                    _BrowseTab(
                      loading:  _browseLoading,
                      result:   _browseResult,
                      query:    _controller.text.trim(),
                      onSearch: _fetchBrowse,
                      onPlay:   _playBrowseTrack,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // tab bar widget
  Widget _buildTabBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(10),
        ),
        child: TabBar(
          controller: _tabController,
          indicator: BoxDecoration(
            color: AurumTheme.gold,
            borderRadius: BorderRadius.circular(8),
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: Colors.black,
          unselectedLabelColor: AurumTheme.textSecondaryOf(context),
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          padding: const EdgeInsets.all(3),
          tabs: const [
            Tab(text: 'Search'),
            Tab(text: 'Browse'),
          ],
          onTap: (i) {
            if (i == 1 && _controller.text.trim().isNotEmpty) {
              _fetchBrowse(_controller.text.trim());
            }
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(key: ValueKey('loading'), child: AurumMorphLoader());
    if (_results.isNotEmpty) return _buildResults();
    if (_controller.text.trim().isNotEmpty) return _buildLivePanel(context);
    if (_showHistory && _history.isNotEmpty) return _buildHistory(context);
    return _buildEmpty(context);
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(children: [
        ShaderMask(
          shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
          child: const Text('Search', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _focusNode.hasFocus
                ? AurumTheme.gold.withOpacity(0.45)
                : AurumTheme.dividerOf(context),
            width: _focusNode.hasFocus ? 1.2 : 0.5,
          ),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          onSubmitted: _search,
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Songs, artists, albums...',
            hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
            prefixIcon: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 20),
            suffixIcon: _controller.text.isNotEmpty
                ? GestureDetector(
                    onTap: _clearSearch,
                    child: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context), size: 18),
                  )
                : null,
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
          textInputAction: TextInputAction.search,
        ),
      ),
    );
  }

  // ── History UI ───────────────────────────────────────────────

  Widget _buildHistory(BuildContext context) {
    return Column(
      key: const ValueKey('history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent', style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
              TextButton(
                onPressed: _clearHistory,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text('Clear all', style: TextStyle(color: AurumTheme.gold.withOpacity(0.8), fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: _history.length,
            itemExtent: 52,
            itemBuilder: (_, i) {
              final item = _history[i];
              return ListTile(
                leading: Icon(Icons.history_rounded, color: AurumTheme.textMutedOf(context), size: 18),
                title: Text(item, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () { _controller.text = item; _controller.selection = TextSelection.fromPosition(TextPosition(offset: item.length)); _onChanged(item); },
                      child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16)),
                    ),
                    GestureDetector(
                      onTap: () => _removeFromHistory(item),
                      child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context), size: 16)),
                    ),
                  ],
                ),
                dense: true,
                onTap: () { _controller.text = item; _search(item); },
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Live panel ───────────────────────────────────────────────

  Widget _buildLivePanel(BuildContext context) {
    final query          = _controller.text.trim();
    final hasSuggestions = _suggestions.isNotEmpty;
    final hasLive        = _liveResults.isNotEmpty;

    Widget content;
    if (!hasSuggestions && !hasLive) {
      content = _liveLoading ? _buildLiveLoadingState(context) : _buildNoLiveResults(context, query);
    } else {
      content = ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: [
          if (_liveLoading) _buildLiveProgressBar(context),
          if (hasSuggestions) ...[
            ..._suggestions.map((s) => _suggestionTile(context, s)),
            if (hasLive) Divider(color: AurumTheme.dividerOf(context), height: 1, indent: 16, endIndent: 16),
          ],
          if (hasLive) ...[
            _sectionLabel(context, 'Songs'),
            ..._liveResults.asMap().entries.map((e) => _StaggeredItem(
              index: e.key,
              child: SongTile(
                key: ValueKey('live_${e.value.id}_${e.key}'),
                song: e.value, queue: _liveResults, index: e.key,
              ),
            )),
          ],
          if (query.isNotEmpty) _seeAllTile(context, query),
        ],
      );
    }

    return KeyedSubtree(key: const ValueKey('live'), child: content);
  }

  Widget _buildLiveProgressBar(BuildContext context) {
    return const SizedBox(height: 2, child: AurumM3Loader(height: 2));
  }

  Widget _buildLiveLoadingState(BuildContext context) {
    return Column(children: [
      _buildLiveProgressBar(context),
      const Expanded(child: Center(child: AurumMorphLoader())),
    ]);
  }

  Widget _buildNoLiveResults(BuildContext context, String query) {
    return AurumEmptyState(
      icon: Icons.search_off_rounded,
      title: 'No results for "$query"',
      actionLabel: 'Search everywhere',
      onAction: () {
        HapticFeedback.lightImpact();
        _search(query);
      },
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(label.toUpperCase(), style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
    );
  }

  Widget _suggestionTile(BuildContext context, String s) {
    return ListTile(
      key: ValueKey('sugg_$s'),
      leading: Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 18),
      title: Text(s, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: GestureDetector(
        onTap: () { HapticFeedback.lightImpact(); _controller.text = s; _controller.selection = TextSelection.fromPosition(TextPosition(offset: s.length)); _onChanged(s); },
        child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16)),
      ),
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      onTap: () { _controller.text = s; _search(s); },
    );
  }

  Widget _seeAllTile(BuildContext context, String query) {
    return ListTile(
      key: const ValueKey('see_all'),
      leading: Icon(Icons.travel_explore_rounded, color: AurumTheme.gold, size: 20),
      title: Text('See all results for "$query"', style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.gold.withOpacity(0.6), size: 14),
      dense: true,
      onTap: () => _search(query),
    );
  }

  // ── Results ──────────────────────────────────────────────────

  Widget _buildResults() {
    return ColoredBox(
      color: AurumTheme.bgOf(context),
      child: ListView.builder(
        key: const ValueKey('results'),
        physics: const BouncingScrollPhysics(),
        itemCount: _results.length,
        itemExtent: 66,
        padding: const EdgeInsets.only(bottom: 80),
        itemBuilder: (_, i) => _StaggeredItem(
          index: i,
          child: SongTile(
            key: ValueKey('result_${_results[i].id}_$i'),
            song: _results[i], queue: _results, index: i,
          ),
        ),
      ),
    );
  }

  // ── Empty state ──────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context) {
    return Center(
      key: const ValueKey('empty'),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.music_note_rounded, color: AurumTheme.gold.withOpacity(0.2), size: 64),
        const SizedBox(height: 16),
        Text('Search for your favourite songs', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14)),
      ]),
    );
  }
}

// =============================================================================
// Browse Tab Widget
// =============================================================================

class _BrowseTab extends StatefulWidget {
  final bool               loading;
  final BrowseSearchResult result;
  final String             query;
  final void Function(String) onSearch;
  final void Function(BrowseTrack) onPlay;

  const _BrowseTab({
    required this.loading,
    required this.result,
    required this.query,
    required this.onSearch,
    required this.onPlay,
  });

  @override
  State<_BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends State<_BrowseTab> {
  // Album drill-down state
  String?           _openAlbumId;
  String?           _openAlbumName;
  bool              _albumLoading = false;
  List<BrowseTrack> _albumTracks  = [];

  // Artist drill-down state
  String?           _openArtistName;
  bool              _artistLoading = false;
  List<BrowseTrack> _artistTracks  = [];

  Future<void> _openAlbum(BrowseAlbum album) async {
    setState(() { _openAlbumId = album.collectionId; _openAlbumName = album.name; _albumLoading = true; _albumTracks = []; _openArtistName = null; });
    final tracks = await BrowseService.albumTracks(album.collectionId);
    if (mounted) setState(() { _albumTracks = tracks; _albumLoading = false; });
  }

  Future<void> _openArtist(BrowseArtist artist) async {
    setState(() { _openArtistName = artist.name; _artistLoading = true; _artistTracks = []; _openAlbumId = null; });
    final tracks = await BrowseService.artistTopSongs(artist.name);
    if (mounted) setState(() { _artistTracks = tracks; _artistLoading = false; });
  }

  void _back() => setState(() { _openAlbumId = null; _openAlbumName = null; _openArtistName = null; _albumTracks = []; _artistTracks = []; });

  @override
  Widget build(BuildContext context) {
    // Drill-down: album tracks
    if (_openAlbumId != null) return _buildTrackList(context, _openAlbumName ?? 'Album', _albumLoading, _albumTracks);
    // Drill-down: artist top songs
    if (_openArtistName != null) return _buildTrackList(context, _openArtistName!, _artistLoading, _artistTracks);

    if (widget.query.isEmpty) return _buildBrowseEmpty(context);
    if (widget.loading)       return const Center(child: AurumMorphLoader());
    if (widget.result.isEmpty) return _buildBrowseEmpty(context);

    return ListView(
      padding: const EdgeInsets.only(bottom: 100),
      children: [
        // Artists
        if (widget.result.artists.isNotEmpty) ...[
          _sectionLabel(context, 'Artists'),
          _FadedHorizontalList(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: widget.result.artists.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                child: _ArtistChip(
                  artist: widget.result.artists[i],
                  onTap: () => _openArtist(widget.result.artists[i]),
                ),
              ),
            ),
          ),
        ],
        // Albums
        if (widget.result.albums.isNotEmpty) ...[
          _sectionLabel(context, 'Albums'),
          _FadedHorizontalList(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: widget.result.albums.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                child: _AlbumCard(
                  album: widget.result.albums[i],
                  onTap: () => _openAlbum(widget.result.albums[i]),
                ),
              ),
            ),
          ),
        ],
        // Tracks
        if (widget.result.tracks.isNotEmpty) ...[
          _sectionLabel(context, 'Songs'),
          ...widget.result.tracks.asMap().entries.map((e) => _StaggeredItem(
            index: e.key,
            child: _BrowseTrackTile(track: e.value, onPlay: () => widget.onPlay(e.value)),
          )),
        ],
      ],
    );
  }

  Widget _buildTrackList(BuildContext context, String title, bool loading, List<BrowseTrack> tracks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back header
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 16, 8),
          child: Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18), onPressed: _back, color: AurumTheme.textPrimaryOf(context)),
            Expanded(child: Text(title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ),
        if (loading)
          const Expanded(child: Center(child: AurumMorphLoader()))
        else
          Expanded(
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: tracks.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                child: _BrowseTrackTile(track: tracks[i], onPlay: () => widget.onPlay(tracks[i])),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBrowseEmpty(BuildContext context) {
    return AurumEmptyState(
      icon: Icons.library_music_outlined,
      title: widget.query.isEmpty ? 'Type to browse artists & albums' : 'No results',
    );
  }

  Widget _sectionLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(label.toUpperCase(), style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
    );
  }
}

// ── Browse sub-widgets ─────────────────────────────────────────────────────────

// Tiny reusable press-scale wrapper — same feel as home_screen's _SongCard
// press animation, without duplicating an AnimationController per widget type.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressScale({required this.child, required this.onTap});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _scale = Tween(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.selectionClick();
    _ctrl.forward().then((_) => _ctrl.reverse());
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}

class _BrowseTrackTile extends StatelessWidget {
  final BrowseTrack track;
  final VoidCallback onPlay;
  const _BrowseTrackTile({required this.track, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.currentSong?.title == track.title && p.currentSong?.artist == track.artist);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AurumArtwork(url: track.artworkUrl, size: 44),
      ),
      title: Text(track.title, style: TextStyle(color: isPlaying ? AurumTheme.gold : AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.artist, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: isPlaying
          ? Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 20)
          : Icon(Icons.play_circle_outline_rounded, color: AurumTheme.textMutedOf(context), size: 22),
      dense: true,
      onTap: onPlay,
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final BrowseAlbum album;
  final VoidCallback onTap;
  const _AlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: AurumArtwork(url: album.artworkUrl, size: 130),
          ),
          const SizedBox(height: 6),
          Text(album.name, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 12, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(album.artist, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

class _ArtistChip extends StatelessWidget {
  final BrowseArtist artist;
  final VoidCallback onTap;
  const _ArtistChip({required this.artist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _PressScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AurumTheme.bgCardOf(context),
              border: Border.all(color: AurumTheme.gold.withOpacity(0.3), width: 1.5),
            ),
            child: Icon(Icons.person_rounded, color: AurumTheme.gold.withOpacity(0.7), size: 28),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 70,
            child: Text(artist.name, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 11, fontWeight: FontWeight.w500), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }
}
