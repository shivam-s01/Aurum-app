import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../widgets/aurum_pressable.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';

import '../services/browse_service.dart';
import '../services/recommendation_engine.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/faded_horizontal_list.dart';
import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/aurum_equalizer_bars.dart';
import '../l10n/generated/app_localizations.dart';
import 'full_player_screen.dart';
import '../utils/aurum_haptics.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Staggered list item — fade + slide up, same system as home_screen.dart's
// _StaggeredSection. Capped delay so long result lists don't take forever
// to finish animating in; items beyond the cap appear immediately.
// ─────────────────────────────────────────────────────────────────────────────
// Tracks which staggered items have already animated in this session —
// mirrors home_screen.dart's _seenSections. Without this, a ListView
// scrolling an item off-screen and back on tears down and rebuilds
// _StaggeredItemState (Flutter disposes off-screen list children), which
// re-runs initState() and replays the slide/fade-in animation from
// scratch. That's the actual mechanism behind "thumbnail jumps up and
// down" — every scroll pass re-triggers a fresh 0.06-offset slide-in for
// any item that had scrolled out of view, which reads as the artwork
// snapping to a slightly-off position then sliding into place, repeatedly,
// as the user scrolls.
//
// FIX (search-specific bug on top of the above): this used to be keyed by
// plain list position (`int` index) alone. Search results change every
// time the user runs a new query, but positions restart from 0 for each
// new result list — so a fresh, never-before-seen result landing at
// position 3 of a NEW query would be treated as "already seen" if
// anything had ever occupied position 3 in an EARLIER query this
// session, and would wrongly skip straight to its settled end state with
// no entrance animation at all. Keying by a stable item identity (song
// id, passed in as itemKey) when available, falling back to the index
// only when no such identity exists, fixes that cross-query collision.
final _seenStaggeredItems = <String>{};

class _StaggeredItem extends StatefulWidget {
  final int index;
  final Widget child;
  // Optional stable identity for the underlying item (e.g. a song or
  // track id). When provided, this — not the raw list position — is
  // used to decide whether this item has already animated in, so a new
  // search query's results don't collide with a previous query's items
  // that happened to sit at the same position.
  final String? itemKey;
  const _StaggeredItem({required this.index, required this.child, this.itemKey});

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

    // FIX (see _seenStaggeredItems doc comment above): only play the
    // slide/fade-in the first time this item is ever seen. A re-mount
    // from scrolling back on-screen jumps straight to the settled end
    // state instead of replaying the entrance animation. Keyed by the
    // stable itemKey when available so a new query's results at the same
    // position as an old query's don't collide.
    final seenKey = widget.itemKey ?? 'idx_${widget.index}';
    if (_seenStaggeredItems.contains(seenKey)) {
      _ctrl.value = 1.0;
    } else {
      _seenStaggeredItems.add(seenKey);
      Future.delayed(Duration(milliseconds: 20 + cappedIndex * 35), () {
        if (mounted) _ctrl.forward();
      });
    }
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
// _FadedHorizontalList moved to lib/widgets/faded_horizontal_list.dart
// (FadedHorizontalList, public) so Home screen's carousels can share the
// exact same edge-fade treatment instead of each screen keeping its own
// private copy.

class SearchScreen extends StatefulWidget {
  final bool isActive;
  const SearchScreen({super.key, this.isActive = true});

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
  List<Song>   _results        = [];
  // Vibe/related expansion, kept separate from _results so the UI shows it
  // as its own labeled "You might also like" section — never silently
  // merged into the direct matches (that mixing was why unrelated songs
  // used to appear inside plain search results with no explanation).
  List<Song>   _relatedResults = [];
  List<Song>   _liveResults = [];
  List<String> _suggestions = [];
  List<String> _history     = [];
  bool _loading     = false;
  bool _liveLoading = false;
  // FIX (search screen "goes blank/covers with a loader" on live typing):
  // _liveLoading used to drive _buildLiveLoadingState's full-cover
  // Expanded(Center(AurumMorphLoader)) directly and IMMEDIATELY — it
  // flips true synchronously in _onChanged on every single keystroke of
  // a query that has no suggestions/results yet (which is every fresh
  // query, and often several keystrokes into one, since results only
  // exist once the 280ms debounce + network round-trip finishes). In
  // practice that meant a big spinner regularly flashing over the whole
  // content area for a brief instant while typing normally — reading as
  // "the screen keeps going blank", exactly what was reported.
  //
  // Real fix: don't show that heavy full-cover loader until it's been
  // needed for a genuine beat — gate it behind a short grace timer
  // (_liveLoaderGraceTimer below) that only flips _showLiveLoader true
  // if _liveLoading is STILL true (nothing arrived yet) after 350ms. Any
  // response fast enough to land before that (the common case now that
  // quickSearch fires Saavn+YT concurrently — see api_service.dart) never
  // triggers the loader at all; the panel just goes straight from
  // "typing" to "results", no flash in between. Only a genuinely slow
  // network gets the loader, and only after giving the fast path a fair
  // chance first.
  bool _showLiveLoader = false;
  Timer? _liveLoaderGraceTimer;
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
    _applyActiveState();
  }

  // ROOT FIX (keyboard stuck closed after leaving the Search tab): see
  // widget.isActive doc comment above. We react to real tab-visibility
  // changes here instead of a ModalRoute check that is always true for
  // this whole shell.
  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    _applyActiveState();
  }

  void _applyActiveState() {
    if (!widget.isActive) {
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
    _liveLoaderGraceTimer?.cancel();
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
    _liveLoaderGraceTimer?.cancel();
    final query = q.trim();

    if (query.isEmpty) {
      setState(() {
        _suggestions  = [];
        _liveResults  = [];
        _liveLoading  = false;
        _showLiveLoader = false;
        _showHistory  = _history.isNotEmpty && _focusNode.hasFocus;
      });
      return;
    }

    setState(() { _showHistory = false; _liveLoading = true; _showLiveLoader = false; });

    // Only start showing the full-cover loader if this exact query is
    // STILL loading 350ms from now — i.e. genuinely slow, not just
    // "hasn't had a chance to respond yet". Anything that resolves
    // faster than that (the normal case) never triggers this at all, so
    // the panel goes straight from "typing" to "results" with no flash.
    _liveLoaderGraceTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_controller.text.trim() != query) return;
      if (_liveLoading) setState(() => _showLiveLoader = true);
    });

    _suggestDebounce = Timer(const Duration(milliseconds: 280), () async {
      // FIX (blank search screen): if the query changed by the time this
      // timer fired (user kept typing), we used to bail out here WITHOUT
      // resetting _liveLoading — which was already set true back in
      // _onChanged for the newest keystroke. If that newest keystroke's own
      // timer/callbacks also hit this same stale-query guard, _liveLoading
      // could get stuck true forever with nothing left to flip it back to
      // false. Since _buildLivePanel only shows a small loader while
      // _liveLoading is true and there are no results yet, the rest of the
      // screen just stayed empty indefinitely — looking like a "blank page"
      // whenever the user typed fast enough to produce a stale timer.
      if (!mounted) return;
      if (_controller.text.trim() != query) return;

      // Fire both independently — whichever resolves first updates the UI
      // immediately. Previously these were awaited together, so a slow
      // autocomplete call could hold up already-ready song results.
      ApiService.quickSearch(query).then((songs) {
        if (!mounted) return;
        if (_controller.text.trim() != query) return;
        setState(() {
          _liveResults = songs;
          _liveLoading = false;
          _showLiveLoader = false;
        });
      }).catchError((_) {
        if (!mounted) return;
        if (_controller.text.trim() != query) return;
        setState(() { _liveLoading = false; _showLiveLoader = false; });
      });

      ApiService.suggest(query).then((suggestions) {
        if (!mounted || _controller.text.trim() != query) return;
        setState(() => _suggestions = suggestions);
      }).catchError((_) {});

      // also trigger browse if on Browse tab
      if (_tabController.index == 1) _fetchBrowse(query);
    });
  }

  // FIX ("same song 5-6 times back to back in Up Next"): tapping a search
  // result used to pass `queue: _results` — the raw, unfiltered search
  // response — straight into the player. A popular song's search results
  // are naturally full of near-duplicate entries (the same song re-uploaded
  // by five different channels, official + lyric-video + status-video cuts
  // of the same track, etc.), and none of that gets deduped before display
  // because search SHOULD show every version so the user can pick one.
  // But once picked, dumping that same noisy list straight into Up Next
  // meant the next 5-6 slots were just re-uploads of the song that was
  // just tapped. This builds a separate queue for playback only: the
  // tapped song goes first, then every other result is kept only if
  // isSameSongSmart doesn't already consider it a re-upload of something
  // already in the queue. _results itself (what's on screen) is untouched
  // — search still shows every version; only what auto-plays next changes.
  List<Song> _dedupedQueueFor(int tappedIndex) {
    final anchor = _results[tappedIndex];
    final seenIds = <String>{anchor.id};
    final seenRawTitles = <String>[anchor.title];
    final out = <Song>[anchor];
    for (int j = 0; j < _results.length; j++) {
      if (j == tappedIndex) continue;
      final s = _results[j];
      if (seenIds.contains(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      var isDup = false;
      for (final raw in seenRawTitles) {
        if (RecommendationEngine.isSameSongSmart(s.title, raw)) {
          isDup = true;
          break;
        }
      }
      if (isDup) continue;
      seenIds.add(s.id);
      seenRawTitles.add(s.title);
      out.add(s);
    }
    return out;
  }

  // Same dedup logic as _dedupedQueueFor, scoped to the "You might also
  // like" section instead of the direct-match section — tapping a related
  // song should queue up more related songs, not jump back into direct
  // matches for the original query.
  List<Song> _dedupedRelatedQueueFor(int tappedIndex) {
    final anchor = _relatedResults[tappedIndex];
    final seenIds = <String>{anchor.id};
    final seenRawTitles = <String>[anchor.title];
    final out = <Song>[anchor];
    for (int j = 0; j < _relatedResults.length; j++) {
      if (j == tappedIndex) continue;
      final s = _relatedResults[j];
      if (seenIds.contains(s.id)) continue;
      if (RecommendationEngine.isInherentVariant(s.title)) continue;
      var isDup = false;
      for (final raw in seenRawTitles) {
        if (RecommendationEngine.isSameSongSmart(s.title, raw)) {
          isDup = true;
          break;
        }
      }
      if (isDup) continue;
      seenIds.add(s.id);
      seenRawTitles.add(s.title);
      out.add(s);
    }
    return out;
  }

  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    _liveLoaderGraceTimer?.cancel();
    AurumHaptics.light();
    _dismissKeyboard();
    // FIX ("live suggestions/results flash and vanish 2s after typing,
    // then songs appear"): _search() previously left _suggestions and
    // _liveResults completely untouched — only _results was cleared. Since
    // _computeBodyKey()/_buildBody fall back to the 'live' panel (built
    // from _suggestions/_liveResults) whenever _results is empty, the
    // OLD suggestion dropdown and live results kept sitting on screen,
    // fully interactive-looking, for the entire 150ms debounce + full
    // network round-trip of ApiService.search() — then vanished all at
    // once the instant _results finally populated. That abrupt swap is
    // exactly the "gayab ho jata hai" symptom reported. Explicitly
    // clearing _suggestions/_liveResults here means the panel falls
    // through to the (already-existing) loading state immediately, so
    // there's one clean transition — typing → loading → results — instead
    // of stale suggestions lingering and then snapping away.
    setState(() {
      _loading = true;
      _liveLoading = false;
      _showLiveLoader = false;
      _showHistory = false;
      _results = [];
      _suggestions = [];
      _liveResults = [];
    });
    _saveToHistory(query);
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final result = await ApiService.search(query);
      if (!mounted) return;
      // Stale-guard: if the user kept typing/searched something else while
      // this was in flight, don't stomp on the newer query's results.
      if (_controller.text.trim() != query) return;
      setState(() {
        _results        = result.direct;
        _relatedResults = result.related;
        _loading = false;
      });
    });
  }

  void _clearSearch() {
    AurumHaptics.light();
    _suggestDebounce?.cancel();
    _debounce?.cancel();
    _liveLoaderGraceTimer?.cancel();
    _controller.clear();
    // STRICT: do NOT requestFocus here — user cleared the text but that
    // doesn't mean they want the keyboard back. They can tap the bar again.
    setState(() {
      _results = []; _relatedResults = []; _liveResults = []; _suggestions = [];
      _liveLoading = false; _showLiveLoader = false; _loading = false;
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
    AurumHaptics.light();
    _dismissKeyboard();
    // FIX: tracks discovered via the YouTube fallback (Saavn had nothing for
    // that artist/album) carry a real YouTube video ID as trackId. Forcing
    // source: SongSource.saavn on those meant the player tried to resolve a
    // YouTube ID against Saavn and always failed silently — tapping the
    // track did nothing. track.isFromYoutube is set explicitly wherever
    // these tracks are created, so playback routes to the correct resolver
    // instead of guessing from the ID's shape.
    final song = Song(
      id:         track.trackId,
      title:      track.title,
      artist:     track.artist,
      album:      track.album,
      artworkUrl: track.artworkUrl,
      duration:   track.durationMs != null ? (track.durationMs! / 1000).round() : null,
      source:     track.isFromYoutube ? SongSource.youtube : SongSource.saavn,
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
          // FIX (flat theme-colored screen for 1-2s on open/swipe-down-
          // close instead of instant artwork): see the matching fix in
          // home_screen.dart's pushFullPlayer(), mini_player.dart's
          // _openFullPlayer(), song_tile.dart's _handleTap(), and
          // library_screen.dart — FullPlayerScreen already paints its own
          // opaque, theme-correct background on its first frame, so this
          // extra flat ColoredBox was redundant and is what showed
          // through as an untinted flat color during the whole
          // transition, both directions.
          transitionsBuilder: (context, anim, __, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 380),
          // FIX ("back feels stuck/not smooth"): matched to the forward
          // duration above — was 300ms vs 380ms open (same root-cause fix
          // as aurum_transitions.dart).
          reverseTransitionDuration: const Duration(milliseconds: 380),
        ),
      );
    }
  }

  // ── Build ─────────────────────────────────────────────────────

  // Single source of truth for both _computeBodyKey (drives the outer
  // AnimatedSwitcher) and _buildBody (decides what to actually render).
  // Keeping this in one place is deliberate — these two were previously
  // duplicated ad hoc and fell out of sync, which is exactly what caused
  // the full-page-cover bug on submit search.
  bool get _hasVisibleContent =>
      _results.isNotEmpty ||
      (_controller.text.trim().isNotEmpty && _liveResults.isNotEmpty);

  String _computeBodyKey() {
    // STRICT FIX: this key drives the AnimatedSwitcher wrapping _buildBody.
    // It used to return 'loading' the instant _loading flipped true,
    // regardless of whether results were already on screen — so even
    // though _buildBody itself kept rendering the results list, this outer
    // key change made AnimatedSwitcher tear the whole subtree down and
    // fade/scale in a brand new "loading" subtree over it. That's what
    // made the page look like it "gets completely covered" on submit
    // search even though the results view underneath was otherwise fine.
    if (_loading && !_hasVisibleContent) return 'loading';
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
        // Was left at the default (true), so THIS Scaffold resized its own
        // body to avoid the keyboard — but SearchScreen actually lives
        // inside MainShell's IndexedStack, sitting under an OUTER Scaffold
        // whose bottomNavigationBar (MiniPlayer + nav bar, ~140-160px) does
        // NOT resize for the keyboard. Two Scaffolds independently deciding
        // how much space the keyboard eats produced a squeezed/broken
        // layout the instant the live-results panel appeared and needed
        // more vertical room — looking like the screen "went blank" behind
        // the keyboard. A single Scaffold that doesn't fight the keyboard,
        // with the scrollable content given explicit bottom padding for
        // the keyboard height instead, keeps one consistent layout.
        resizeToAvoidBottomInset: false,
        backgroundColor: AurumTheme.bgOf(context),
        // extendBody: true — matches MainShell's outer Scaffold so search
        // results scroll underneath the floating glass nav bar/mini player
        // instead of stopping in a flat strip above it (see main_shell.dart
        // for the matching change + rationale).
        extendBody: true,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
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
      ),
    );
  }

  // tab bar widget
  Widget _buildTabBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.6),
        ),
        child: TabBar(
          controller: _tabController,
          indicator: BoxDecoration(
            gradient: AurumTheme.goldGradient,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.35),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          labelColor: Colors.black,
          unselectedLabelColor: AurumTheme.textSecondaryOf(context),
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          padding: const EdgeInsets.all(3),
          tabs: [
            Tab(text: l10n.searchTabSearch),
            Tab(text: l10n.searchTabBrowse),
          ],
          onTap: (i) {
            if (i != _tabController.index) AurumHaptics.selection();
            if (i == 1 && _controller.text.trim().isNotEmpty) {
              _fetchBrowse(_controller.text.trim());
            }
          },
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    // STRICT FIX: previously `if (_loading)` was checked first, no matter
    // what — so the instant the user hit the keyboard's Search action
    // (_search() sets _loading = true), this ColoredBox slammed down over
    // whatever was already on screen (live results the user was just
    // scrolling) and hid everything behind a full-page loader until the
    // new results arrived. That's the "page suddenly gets covered" bug —
    // it only ever happened on submit, never on live/typeahead search,
    // because live search uses `_liveLoading` + a small in-panel loader,
    // not this full-cover branch.
    //
    // Fix: only show the full-cover loader when there is genuinely nothing
    // to show yet (cold state). If results are already on screen — either
    // finished search results or live results — keep them visible while
    // the new search resolves; _buildResults()/_buildLivePanel() below
    // render a slim top progress line instead so the transition reads as
    // "refreshing", not "reloading the whole page".
    // BUGFIX: this branch (and _buildEmpty/_buildHistory/_buildLivePanel/
    // _buildResults below) used to each wrap themselves in their own
    // ColoredBox(color: bgOf(context)). The outer AnimatedSwitcher above
    // already sits on top of a solid ColoredBox background (see the "Tab 0"
    // wrapper), so every one of these was a second, redundant background
    // layer. During the 280ms cross-fade/scale transition between two
    // states (e.g. empty → live the instant you start typing),
    // AnimatedSwitcher keeps BOTH the outgoing and incoming subtrees on
    // screen at once — so two overlapping ColoredBoxes, each fading/scaling
    // independently, briefly produced a visible flash/wash across the
    // whole screen that looked like the theme was changing. It wasn't a
    // theme bug — it was two stacked opaque backgrounds animating against
    // each other. Removing the inner ColoredBox from every branch means
    // the switcher now only ever cross-fades the actual content on a
    // single, stable background.
    if (_loading && !_hasVisibleContent) {
      return const Center(key: ValueKey('loading'), child: AurumMorphLoader(size: 56));
    }
    if (_results.isNotEmpty) return _buildResults();
    if (_controller.text.trim().isNotEmpty) return _buildLivePanel(context);
    if (_showHistory && _history.isNotEmpty) return _buildHistory(context);
    return _buildEmpty(context);
  }

  Widget _buildHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(children: [
        ShaderMask(
          shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
          child: Text(l10n.searchTabSearch, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.2)),
        ),
      ]),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final focused = _focusNode.hasFocus;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused
                ? AurumTheme.gold.withOpacity(0.6)
                : AurumTheme.dividerOf(context),
            width: focused ? 1.3 : 0.5,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.16),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          // SAFETY NET: force canRequestFocus back on and request focus
          // whenever the user actually taps the field, regardless of what
          // isActive-driven state thinks it should be. This is the direct
          // fix for the keyboard never opening again after leaving the tab.
          onTap: () {
            if (!_focusNode.canRequestFocus) _focusNode.canRequestFocus = true;
            if (!_focusNode.hasFocus) _focusNode.requestFocus();
          },
          onChanged: _onChanged,
          onSubmitted: _search,
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
            prefixIcon: Icon(Icons.search_rounded,
                color: focused ? AurumTheme.gold : AurumTheme.textMutedOf(context), size: 20),
            suffixIcon: _controller.text.isNotEmpty
                ? AurumPressable(
                    scaleAmount: 0.82,
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
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('history'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l10n.searchRecent, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
              TextButton(
                onPressed: _clearHistory,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Text(l10n.searchClearAll, style: TextStyle(color: AurumTheme.gold.withOpacity(0.8), fontSize: 12)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            // PERF: pre-builds rows a bit ahead of view so fast scrolling
            // through history doesn't show list items popping in.
            cacheExtent: 600,
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
                    AurumPressable(
                      scaleAmount: 0.80,
                      onTap: () { _controller.text = item; _controller.selection = TextSelection.fromPosition(TextPosition(offset: item.length)); _onChanged(item); },
                      child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16)),
                    ),
                    AurumPressable(
                      scaleAmount: 0.80,
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
      // FIX: was `_liveLoading ? _buildLiveLoadingState : _buildNoLiveResults`
      // — _liveLoading flips true on literally every keystroke, so this
      // branch showed the full-cover spinner constantly while typing
      // normally, even when the real answer was about to arrive well
      // under a second later. Gated on _showLiveLoader instead, which
      // only ever becomes true after the 350ms grace timer in _onChanged
      // confirms this specific query is still genuinely unresolved — a
      // normal fast response never trips it, so typing reads as smooth
      // "results just appear" rather than "screen keeps flashing a
      // loader".
      content = _showLiveLoader ? _buildLiveLoadingState(context) : _buildNoLiveResults(context, query);
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
            _sectionLabel(context, AppLocalizations.of(context)!.librarySongs),
            ..._liveResults.asMap().entries.map((e) => _StaggeredItem(
              index: e.key,
              itemKey: 'live_${e.value.id}',
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
      const Expanded(child: Center(child: AurumMorphLoader(size: 56))),
    ]);
  }

  Widget _buildNoLiveResults(BuildContext context, String query) {
    final l10n = AppLocalizations.of(context)!;
    return AurumEmptyState(
      icon: Icons.search_off_rounded,
      title: l10n.searchNoResultsFor(query),
      actionLabel: l10n.searchEverywhere,
      onAction: () {
        AurumHaptics.light();
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
      trailing: AurumPressable(
        scaleAmount: 0.80,
        haptic: false, // custom lightImpact below instead of default selectionClick
        onTap: () { AurumHaptics.light(); _controller.text = s; _controller.selection = TextSelection.fromPosition(TextPosition(offset: s.length)); _onChanged(s); },
        child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.north_west_rounded, color: AurumTheme.textMutedOf(context), size: 16)),
      ),
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      onTap: () { _controller.text = s; _search(s); },
    );
  }

  Widget _seeAllTile(BuildContext context, String query) {
    final l10n = AppLocalizations.of(context)!;
    return ListTile(
      key: const ValueKey('see_all'),
      leading: Icon(Icons.travel_explore_rounded, color: AurumTheme.gold, size: 20),
      title: Text(l10n.searchSeeAllResultsFor(query), style: TextStyle(color: AurumTheme.gold, fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.gold.withOpacity(0.6), size: 14),
      dense: true,
      onTap: () => _search(query),
    );
  }

  // ── Results ──────────────────────────────────────────────────

  Widget _buildResults() {
    final l10n = AppLocalizations.of(context)!;
    // Two clearly separated sections instead of one flat list — direct
    // matches for the query first, then a labeled "You might also like"
    // section for the mood/genre-related expansion. This is the fix for
    // search showing unrelated songs (e.g. other artists' tracks) with no
    // explanation of why they were there: now they're visually and
    // structurally set apart, same as Spotify/Fabtune-style search.
    final showRelatedHeader = _relatedResults.isNotEmpty;
    final itemCount = _results.length
        + (showRelatedHeader ? 1 : 0)
        + _relatedResults.length;

    return Stack(
      children: [
        ListView.builder(
          key: const ValueKey('results'),
          physics: const BouncingScrollPhysics(),
          // PERF: same pop-in fix as history list above — search results
          // often get scrolled through quickly.
          cacheExtent: 800,
          itemCount: itemCount,
          padding: const EdgeInsets.only(bottom: 80),
          itemBuilder: (_, i) {
            if (i < _results.length) {
              return SizedBox(
                height: 66,
                child: _StaggeredItem(
                  index: i,
                  itemKey: 'result_${_results[i].id}',
                  child: SongTile(
                    key: ValueKey('result_${_results[i].id}_$i'),
                    song: _results[i], queue: _dedupedQueueFor(i), index: 0,
                  ),
                ),
              );
            }
            final headerIdx = _results.length;
            if (showRelatedHeader && i == headerIdx) {
              return _sectionLabel(context, l10n.searchYouMightAlsoLike);
            }
            final relatedIdx = i - _results.length - (showRelatedHeader ? 1 : 0);
            return SizedBox(
              height: 66,
              child: _StaggeredItem(
                index: i,
                itemKey: 'related_${_relatedResults[relatedIdx].id}',
                child: SongTile(
                  key: ValueKey('related_${_relatedResults[relatedIdx].id}_$relatedIdx'),
                  song: _relatedResults[relatedIdx],
                  queue: _dedupedRelatedQueueFor(relatedIdx), index: 0,
                ),
              ),
            );
          },
        ),
        // Thin top progress line while a new submit-search is refreshing
        // these same results — this is the "premium" refresh cue: the
        // list the user was already looking at stays put and scrollable,
        // instead of the whole screen vanishing behind a full loader.
        if (_loading)
          const Positioned(
            top: 0, left: 0, right: 0,
            child: SizedBox(height: 2, child: AurumM3Loader(height: 2)),
          ),
      ],
    );
  }

  // ── Empty state ──────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      key: const ValueKey('empty'),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                AurumTheme.gold.withOpacity(0.16),
                AurumTheme.gold.withOpacity(0.0),
              ],
            ),
          ),
          child: Center(
            child: ShaderMask(
              shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
              child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 46),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(l10n.searchFavouriteSongs,
            style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 14.5,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(l10n.searchAllInOnePlace,
            style: TextStyle(
                color: AurumTheme.textMutedOf(context),
                fontSize: 12.5)),
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

  // Scroll controllers so FadedHorizontalList can observe each row's
  // position and only fade an edge once there's actually more content
  // that way — see faded_horizontal_list.dart.
  final _artistsScrollController = ScrollController();
  final _albumsScrollController = ScrollController();

  @override
  void dispose() {
    _artistsScrollController.dispose();
    _albumsScrollController.dispose();
    super.dispose();
  }

  Future<void> _openAlbum(BrowseAlbum album) async {
    setState(() { _openAlbumId = album.collectionId; _openAlbumName = album.name; _albumLoading = true; _albumTracks = []; _openArtistName = null; });
    final tracks = await BrowseService.albumTracks(album.collectionId, isFromYoutube: album.isFromYoutube);
    if (mounted) setState(() { _albumTracks = tracks; _albumLoading = false; });
  }

  Future<void> _openArtist(BrowseArtist artist) async {
    setState(() { _openArtistName = artist.name; _artistLoading = true; _artistTracks = []; _openAlbumId = null; });
    final tracks = await BrowseService.artistTopSongs(artist.name, isFromYoutube: artist.isFromYoutube);
    if (mounted) setState(() { _artistTracks = tracks; _artistLoading = false; });
  }

  void _back() => setState(() { _openAlbumId = null; _openAlbumName = null; _openArtistName = null; _albumTracks = []; _artistTracks = []; });

  @override
  Widget build(BuildContext context) {
    final bool isDrilledDown = _openAlbumId != null || _openArtistName != null;

    // System/gesture back (and the Android predictive-back swipe) was
    // previously invisible to this drill-down — it isn't a real Navigator
    // route, just a setState-driven view swap, so back used to fall
    // straight through to the Search screen's own route and exit all the
    // way to Home. PopScope intercepts it while drilled into an
    // album/artist and routes it through the same _back() the header's
    // back arrow already uses, instead of popping the real screen.
    return PopScope(
      canPop: !isDrilledDown,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isDrilledDown) _back();
      },
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Drill-down: album tracks
    if (_openAlbumId != null) return _buildTrackList(context, _openAlbumName ?? AppLocalizations.of(context)!.browseAlbumFallbackTitle, _albumLoading, _albumTracks);
    // Drill-down: artist top songs
    if (_openArtistName != null) return _buildTrackList(context, _openArtistName!, _artistLoading, _artistTracks);

    if (widget.query.isEmpty) return _buildBrowseEmpty(context);
    if (widget.loading)       return const Center(child: AurumMorphLoader(size: 56));
    if (widget.result.isEmpty) return _buildBrowseEmpty(context);

    return ListView(
      padding: const EdgeInsets.only(bottom: 100),
      children: [
        // Artists
        if (widget.result.artists.isNotEmpty) ...[
          _sectionLabel(context, AppLocalizations.of(context)!.libraryArtists),
          FadedHorizontalList(
            height: 100,
            controller: _artistsScrollController,
            child: ListView.builder(
              controller: _artistsScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // PERF: horizontal carousel pop-in fix.
              cacheExtent: 500,
              itemCount: widget.result.artists.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                itemKey: 'artist_${widget.result.artists[i].artistId}',
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
          _sectionLabel(context, AppLocalizations.of(context)!.libraryAlbums),
          FadedHorizontalList(
            height: 180,
            controller: _albumsScrollController,
            child: ListView.builder(
              controller: _albumsScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              // PERF: horizontal carousel pop-in fix.
              cacheExtent: 700,
              itemCount: widget.result.albums.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                itemKey: 'album_${widget.result.albums[i].collectionId}',
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
          _sectionLabel(context, AppLocalizations.of(context)!.librarySongs),
          ...widget.result.tracks.asMap().entries.map((e) => _StaggeredItem(
            index: e.key,
            itemKey: 'track_${e.value.trackId}',
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
          const Expanded(child: Center(child: AurumMorphLoader(size: 56)))
        else
          Expanded(
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 100),
              // PERF: pop-in fix for the full track browse list.
              cacheExtent: 1000,
              itemCount: tracks.length,
              itemBuilder: (_, i) => _StaggeredItem(
                index: i,
                itemKey: 'browsetrack_${tracks[i].trackId}',
                child: _BrowseTrackTile(track: tracks[i], onPlay: () => widget.onPlay(tracks[i])),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBrowseEmpty(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AurumEmptyState(
      icon: Icons.library_music_outlined,
      title: widget.query.isEmpty ? l10n.browseTypeToExplore : l10n.browseNoResults,
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
    AurumHaptics.selection();
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
    // FIX: was comparing on title+artist strings. Two different tracks that
    // share the same title/artist (a reupload, a cover, the same song from
    // a different album/source) would both light up as "now playing" at
    // once — every SongTile elsewhere in the app already compares by the
    // actual song id (see song_tile.dart), so Browse's own tile should
    // hold the same identity bar instead of a string-based approximation.
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.currentSong?.id == track.trackId);
    final isActuallyPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AurumArtwork(url: track.artworkUrl, size: 44),
      ),
      title: Text(track.title, style: TextStyle(color: isPlaying ? AurumTheme.gold : AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.artist, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: isPlaying
          ? AurumEqualizerBars(playing: isActuallyPlaying, color: AurumTheme.gold, size: 20)
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
            child: ClipOval(
              child: artist.imageUrl.isEmpty
                  ? Icon(Icons.person_rounded, color: AurumTheme.gold.withOpacity(0.7), size: 28)
                  : AurumArtwork(url: artist.imageUrl, size: 60, borderRadius: 30),
            ),
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
