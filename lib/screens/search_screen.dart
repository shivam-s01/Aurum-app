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
import '../providers/recently_played_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/faded_horizontal_list.dart';
import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/aurum_equalizer_bars.dart';
import '../l10n/generated/app_localizations.dart';
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
// LIGHTWEIGHT FIX ("ekdam lightweight rahe, hang na ho"): this set is
// module-level (lives for the whole app session, not just this screen) and
// previously had no upper bound — every unique itemKey ever seen across
// every search query, scroll pass, and Browse visit stayed in memory
// forever with nothing ever removed. Over a long session (lots of
// searching/scrolling) this is a slow, permanent memory leak. Capped with
// simple FIFO eviction: once the set gets large, the oldest entries are
// dropped. Losing an old entry only means that one specific item plays its
// entrance animation again if it's ever scrolled back into view after a
// long time — a purely cosmetic, one-time replay, not a functional bug —
// which is a fair trade for bounded memory.
final _seenStaggeredItems = <String>{};
final _seenStaggeredOrder = <String>[];
const _maxSeenStaggeredItems = 500;

void _markStaggeredSeen(String key) {
  _seenStaggeredItems.add(key);
  _seenStaggeredOrder.add(key);
  if (_seenStaggeredOrder.length > _maxSeenStaggeredItems) {
    final evict = _seenStaggeredOrder.removeAt(0);
    // Only remove from the set if nothing else re-added the same key later
    // in the order list (cheap safety check; keys are effectively unique
    // per song id so this is normally a no-op condition).
    if (!_seenStaggeredOrder.contains(evict)) _seenStaggeredItems.remove(evict);
  }
}

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
  AnimationController? _ctrl;
  Animation<double>?   _fade;
  Animation<Offset>?   _slide;
  // LIGHTWEIGHT FIX ("aur stable/lightweight kro, hang na kre"): every
  // item used to get a full AnimationController + two Tweens +
  // CurvedAnimations allocated in initState, even for items whose
  // entrance animation was already played once and were just jumping
  // straight to the settled end state (_ctrl.value = 1.0 below). On a
  // long lazy-loaded list, scrolling back and forth re-mounts items
  // repeatedly — each re-mount was paying for a Ticker registration and
  // three object allocations purely to sit at a fixed final value that
  // needed no animation machinery at all. Already-seen items now skip
  // controller creation entirely and render as a plain static widget.
  bool _alreadySettled = false;

  @override
  void initState() {
    super.initState();
    final seenKey = widget.itemKey ?? 'idx_${widget.index}';
    if (_seenStaggeredItems.contains(seenKey)) {
      _alreadySettled = true;
      return;
    }
    _markStaggeredSeen(seenKey);

    final cappedIndex = widget.index.clamp(0, 10);
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _ctrl = ctrl;
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic));

    Future.delayed(Duration(milliseconds: 20 + cappedIndex * 35), () {
      if (mounted) ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_alreadySettled) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl!,
      builder: (_, child) => FadeTransition(
        opacity: _fade!,
        child: SlideTransition(position: _slide!, child: child),
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
  // PERF FIX ("scroll karo to bahut jyada lag kar raha hai"): _dedupedQueueFor
  // and _dedupedRelatedQueueFor used to run their O(n) nested dedup loop
  // (isSameSongSmart string comparisons against every prior song) fresh
  // inside itemBuilder, on every single build — which for a ListView means
  // every scroll frame, for every visible tile. With 80-100 search results
  // that's hundreds of string comparisons repeated per frame purely from
  // scrolling, which is exactly what read as "lag". Since the underlying
  // queue for a given tapped index never changes unless _results/
  // _relatedResults themselves change, it's computed ONCE right after those
  // lists are set (see _search/_onChanged) and cached here — itemBuilder now
  // just does an O(1) list lookup instead of recomputing the whole dedup
  // pass on every frame.
  List<List<Song>> _resultQueues = [];
  List<List<Song>> _relatedQueues = [];
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

  // Tracks the body key from the PREVIOUS build so the AnimatedSwitcher's
  // duration can tell "empty -> live" (keystroke #1, should feel instant)
  // apart from every other transition (should keep the normal 280ms feel).
  // Updated at the end of build(), after _computeBodyKey() has already
  // been read for both the duration check and the KeyedSubtree key.
  String _bodyKeyBeforeThisBuild = 'empty';

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

    // SPEED FIX ("network tip-top fast, Spotify level"): was 280ms.
    // _searchSaavn races every host for the FIRST valid response instead
    // of waiting for the slowest to settle, so each round-trip resolves
    // fast — a shorter debounce no longer means paying full latency on
    // every keystroke.
    _suggestDebounce = Timer(const Duration(milliseconds: 120), () async {
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
        // SMART ENGINE FEATURE ("history se seekhe, jo pehle play kiya
        // wahi priority mile"): a STABLE partial re-sort — songs the user
        // has played before are pulled to the front IN THE ORDER
        // quickSearch already ranked them, only breaking ties among
        // otherwise-similar relevance, never overriding an exact-title
        // match quickSearch already placed first.
        final playedIds = context.read<RecentlyPlayedProvider>().playedIdSet;
        final boosted = playedIds.isEmpty
            ? songs
            : [
                ...songs.where((s) => playedIds.contains(s.id)),
                ...songs.where((s) => !playedIds.contains(s.id)),
              ];
        setState(() {
          _liveResults = boosted;
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

      // STABILITY FIX ("production level pe crash na ho"): this callback
      // runs after a 120ms Timer delay — a real async gap. If the widget
      // gets disposed during that wait (user backs out of Search fast
      // enough), _fetchBrowse's very first line does
      // `setState(() => _browseLoading = true)` with no mounted check of
      // its own, which throws "setState() called after dispose()" and
      // crashes. Every other callback in this same Timer already guards
      // on `if (!mounted) return` before touching state; this call site
      // was the one gap.
      if (mounted && _tabController.index == 1) _fetchBrowse(query);
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
  // PERF: computes every tapped-index queue for _results ONCE, called right
  // after _results is set (search submit, or live results promoted) instead
  // of once per itemBuilder call. Same dedup logic as before, just computed
  // up-front instead of on every scroll frame.
  // CRASH/ANR FIX ("loading bar search karne pe hang karta hai"): this was
  // the same unbounded O(n²) shape as _precomputeRelatedQueues below,
  // just on _results instead of _relatedResults — a deep search's direct
  // matches (_results) can themselves run into the dozens, and this ran
  // uncapped for EVERY tapped-index anchor, rescanning the ENTIRE list
  // with an isSameSongSmart (Levenshtein-backed) call per comparison, all
  // synchronously on the UI thread right after setState. That's exactly
  // the freeze-then-ANR pattern, just triggered from the direct-results
  // path instead of the related-results path. Same fix, same caps.
  void _precomputeResultQueues() {
    final cap = _results.length < _maxRelatedQueueAnchors
        ? _results.length
        : _maxRelatedQueueAnchors;
    _resultQueues = List.generate(cap, (tappedIndex) {
      final anchor = _results[tappedIndex];
      final seenIds = <String>{anchor.id};
      final seenRawTitles = <String>[anchor.title];
      final out = <Song>[anchor];
      final scanLimit = _results.length < _maxRelatedQueueScan
          ? _results.length
          : _maxRelatedQueueScan;
      for (int j = 0; j < scanLimit; j++) {
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
    });
  }

  // Same as _precomputeResultQueues but for _relatedResults.
  //
  // CRASH FIX ("search results scroll/settle hote hi app freeze ho ke crash
  // ho jata hai" — ANR, not a thrown exception): this used to be an
  // uncapped O(n²) pass — for EVERY related song, rescan the ENTIRE related
  // list, calling isSameSongSmart (which runs a Levenshtein-distance check
  // internally) against every earlier title. _relatedResults can genuinely
  // hold 100+ songs, so this could mean on the order of 10,000
  // Levenshtein-checked string comparisons running synchronously on the UI
  // thread immediately after setState — long enough on a mid/low-end
  // device to miss enough frames for Android to consider the app
  // unresponsive and kill it. Bounding both the outer loop (how many
  // anchors get a precomputed queue) and the inner scan (how many earlier
  // titles each anchor is compared against) keeps the worst case fixed
  // regardless of how large a deep search's related expansion gets.
  // Anchors beyond the cap just fall back to a single-song queue (song,
  // index) at the call site instead of the reupload-aware queue, which
  // only matters for far-off-screen items anyway.
  static const int _maxRelatedQueueAnchors = 40;
  static const int _maxRelatedQueueScan = 40;

  void _precomputeRelatedQueues() {
    final cap = _relatedResults.length < _maxRelatedQueueAnchors
        ? _relatedResults.length
        : _maxRelatedQueueAnchors;
    _relatedQueues = List.generate(cap, (tappedIndex) {
      final anchor = _relatedResults[tappedIndex];
      final seenIds = <String>{anchor.id};
      final seenRawTitles = <String>[anchor.title];
      final out = <Song>[anchor];
      final scanLimit = _relatedResults.length < _maxRelatedQueueScan
          ? _relatedResults.length
          : _maxRelatedQueueScan;
      for (int j = 0; j < scanLimit; j++) {
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
    });
  }

  void _search(String q) {
    final query = q.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    _suggestDebounce?.cancel();
    _liveLoaderGraceTimer?.cancel();
    AurumHaptics.light();
    _dismissKeyboard();
    // FIX (full-page-cover bug on submit search — "search page cover ho
    // jata hai"): this used to clear _liveResults in the SAME setState
    // that flips _loading true. _hasVisibleContent checks
    // `_results.isNotEmpty || (text.isNotEmpty && _liveResults.isNotEmpty)`
    // — with _liveResults wiped and _results still empty, that flips
    // false on the very same frame _loading becomes true, so
    // _computeBodyKey() fell into the 'loading' branch and _buildBody's
    // full-cover AurumMorphLoader slammed down over whatever was already
    // showing. Since ApiService.search() genuinely takes anywhere from a
    // few hundred ms to several seconds (sequential Saavn passes + a 5s
    // timeout + optional YT fallback), that full-cover loader could sit
    // there for a long, visibly "stuck" stretch — until literally any
    // other state change (e.g. switching to the Browse tab and back)
    // forced a rebuild that happened to land after the response arrived,
    // which is what made it look like tapping Browse was what "fixed" it.
    // Only suggestions are cleared here now — the dropdown-style
    // suggestion list genuinely looks stale/wrong once a search is
    // submitted. _liveResults is intentionally LEFT ON SCREEN as
    // "refreshing" content until the real results replace it, so
    // _hasVisibleContent stays true and the page never goes fully blank.
    setState(() {
      _loading = true;
      _liveLoading = false;
      _showLiveLoader = false;
      _showHistory = false;
      _results = [];
      _suggestions = [];
      _resultQueues = [];
      _relatedQueues = [];
    });
    _saveToHistory(query);
    // YT-STABILITY FIX ("YT results aate hain phir gayab ho ke sirf Saavn
    // bachta hai"): if the live pass already found real YT songs, freeze
    // them — permanently, no swap, no length comparison, no fallback
    // merge. Saavn is backup-only and its catalog is bigger, so any
    // count-based "which list is bigger" comparison eventually lets a
    // slower/weaker second YT call get outvoted by Saavn padding. Simplest
    // correct rule: good YT snapshot in hand → keep it; deep search below
    // only ever contributes the "related" section, never replaces it.
    final liveYtSnapshot = _liveResults
        .where((s) => s.source == SongSource.youtube)
        .toList();
    final hasGoodLiveYt = liveYtSnapshot.length >= 5;

    if (hasGoodLiveYt) {
      setState(() {
        _results = liveYtSnapshot;
        _loading = false;
      });
      _precomputeResultQueues();
    }

    _debounce = Timer(const Duration(milliseconds: 150), () async {
      SearchResult result;
      try {
        result = await ApiService.search(query);
      } catch (_) {
        if (!mounted || _controller.text.trim() != query) return;
        if (!hasGoodLiveYt) setState(() { _loading = false; });
        return;
      }
      if (!mounted || _controller.text.trim() != query) return;

      // DEDUP FIX ("related section mein wahi song dikh jata hai jo upar
      // direct results mein already frozen hai"): when hasGoodLiveYt froze
      // _results to liveYtSnapshot above, result.related was still built
      // by api_service.dart against its OWN direct list, not against
      // liveYtSnapshot — so a song present in both could show twice on
      // screen. Same guard the old freeze path used before this file's
      // last pass, restored: dedup result.direct + result.related against
      // the frozen live snapshot (id first, then isSameSongSmart on a
      // capped raw-title list — cheap, bounded, same helper used
      // everywhere else in this file). Only runs in the hasGoodLiveYt
      // branch; the other branch already takes result.related as-is with
      // zero extra work, unchanged.
      List<Song> dedupedRelated = result.related;
      if (hasGoodLiveYt) {
        final liveIds = liveYtSnapshot.map((s) => s.id).toSet();
        const maxLiveTitlesToCheck = 25;
        final liveRawTitles = liveYtSnapshot
            .map((s) => s.title)
            .take(maxLiveTitlesToCheck)
            .toList();
        bool isDupOfLive(Song s) {
          if (liveIds.contains(s.id)) return true;
          for (final t in liveRawTitles) {
            if (RecommendationEngine.isSameSongSmart(s.title, t)) return true;
          }
          return false;
        }
        const maxCandidatesToDedup = 150;
        dedupedRelated = <Song>[
          ...result.direct.take(maxCandidatesToDedup).where((s) => !isDupOfLive(s)),
          ...result.related.take(maxCandidatesToDedup).where((s) => !isDupOfLive(s)),
        ];
      }

      setState(() {
        if (!hasGoodLiveYt) _results = result.direct;
        _relatedResults = dedupedRelated;
        _loading = false;
      });
      if (!hasGoodLiveYt) _precomputeResultQueues();
      _precomputeRelatedQueues();
    });
  }

  // ROOT of "search history se seekhe" — see the matching doc comment on
  // ApiService.recordSearchSelection for the full reasoning. Called the
  // instant a result tile is tapped (onTapDown, before playback even
  // starts) so the engine learns "this song is what they meant by this
  // query" and can surface it first next time, exactly like Spotify/
  // YouTube Music. Fire-and-forget — never blocks or delays the tap.
  void _recordSelection(String query, Song song) {
    if (query.trim().isEmpty) return;
    ApiService.recordSearchSelection(query, song);
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
      _resultQueues = []; _relatedQueues = [];
      _browseResult = BrowseSearchResult.empty();
      _lastBrowseQuery = '';
    });
  }


  Future<void> _fetchBrowse(String query) async {
    if (!mounted) return;
    if (query == _lastBrowseQuery) return;
    _lastBrowseQuery = query;
    setState(() => _browseLoading = true);
    // STABILITY FIX: same class of bug as ApiService.search() above —
    // BrowseService.search() was awaited with no try/catch, so a real
    // exception here (Browse tab search fires from the same debounce timer
    // as live search) had the same uncaught-async-error crash path.
    BrowseSearchResult result;
    try {
      result = await BrowseService.search(query);
    } catch (_) {
      if (mounted && _lastBrowseQuery == query) {
        setState(() => _browseLoading = false);
      }
      return;
    }
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
      // SPOTIFY-STYLE FIX ("kahi se bhi full player na khule"): tap now
      // only starts playback — mini player is the tap feedback.
      context.read<PlayerProvider>().playSong(song, queue: [song], index: 0);
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
    // Snapshot last build's key BEFORE recomputing this build's — the
    // AnimatedSwitcher duration check below needs "what was on screen a
    // moment ago" vs "what's about to render now" to tell empty->live
    // (keystroke #1) apart from every other transition. Plain field
    // writes, not a post-frame callback: this doesn't trigger a rebuild
    // or touch anything visual, so there's no risk of running mid-layout
    // — a fresh callback allocation on every single build was unnecessary
    // overhead for what's just bookkeeping two strings.
    final previousBodyKey = _bodyKeyBeforeThisBuild;
    final currentBodyKey = _computeBodyKey();
    _bodyKeyBeforeThisBuild = currentBodyKey;
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
                      // SPEED FIX ("1 letter type karte hi turant live
                      // results/suggestions aane chahiye, 'Search
                      // everywhere' empty-state text der tak na dikhe"):
                      // this was a flat 280ms fade/slide/scale for every
                      // state change, including the very first keystroke
                      // (empty -> live). That transition doesn't need to
                      // look "nice" — it needs to feel instant, since the
                      // user just started typing and expects the panel to
                      // react immediately. Any other transition (live ->
                      // results on submit, live -> history on clear) still
                      // gets the full 280ms so those keep their smooth
                      // feel. Only the empty->live jump — the one that
                      // fires on keystroke #1 — is shortened.
                      duration: (previousBodyKey == 'empty' && currentBodyKey == 'live')
                          ? const Duration(milliseconds: 80)
                          : const Duration(milliseconds: 280),
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
                        key: ValueKey(currentBodyKey),
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
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
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
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
      // FIX ("beech mein 'Search everywhere' / no-results dikhta hai jab
      // tak type karna band na karo"): this used to be
      // `_showLiveLoader ? _buildLiveLoadingState : _buildNoLiveResults`
      // — i.e. the very first frame after typing starts (before the
      // 350ms grace timer decides whether to show the full loader) fell
      // straight through to _buildNoLiveResults, which renders "No
      // results for '<query>'" + a "Search everywhere" button. That's a
      // negative/final state — it should only ever appear once a real
      // response has come back empty, never while a query is still
      // in-flight. While _liveLoading is true (set on every keystroke,
      // cleared only when quickSearch's response for the CURRENT query
      // lands), there is no live results/suggestions message. This is
      // what makes results look like they "pop in mid-keystroke" —
      // Spotify/YT Music both show a bare loading indicator, never a
      // not-found state, while a search is still resolving.
      content = _liveLoading
          ? (_showLiveLoader ? _buildLiveLoadingState(context) : const SizedBox.shrink())
          : _buildNoLiveResults(context, query);
    } else {
      // LIGHTWEIGHT FIX ("bahut jyada MB le raha tha, late/hang ho raha
      // tha"): this was a plain ListView with children built via
      // `.map()` — i.e. EVERY song in _liveResults got its SongTile (with
      // its own network artwork image, animations, gesture handlers)
      // instantiated immediately, all at once, regardless of how many
      // were actually visible on screen. With quickSearch's typo-variant
      // fallback able to add extra songs on top of the base 15, that
      // could mean dozens of full tiles — and dozens of simultaneous
      // artwork image downloads — building in a single frame on every
      // keystroke. ListView.builder only builds/loads what's actually
      // scrolled into view (plus a small cache extent), which is the
      // standard Flutter fix for exactly this symptom: high memory from
      // eager list rendering and jank/hang from too much work in one
      // frame. The suggestions/divider/progress-bar header is folded into
      // a single flattened index space so it still scrolls as part of the
      // same list.
      final headerCount = (_liveLoading ? 1 : 0)
          + (hasSuggestions ? _suggestions.length + (hasLive ? 1 : 0) : 0)
          + (hasLive ? 1 : 0); // the "Songs" section label itself
      final tailCount = query.isNotEmpty ? 1 : 0;
      final totalCount = headerCount + (hasLive ? _liveResults.length : 0) + tailCount;

      content = ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: totalCount,
        // PERF: bounds how much off-screen content gets pre-built while
        // scrolling — same tuning as the submit-search results list below.
        cacheExtent: 600,
        itemBuilder: (context, i) {
          var idx = i;
          if (_liveLoading) {
            if (idx == 0) return _buildLiveProgressBar(context);
            idx--;
          }
          if (hasSuggestions) {
            // CRASH FIX: _suggestions can be updated mid-scroll
            if (idx < 0 || idx >= _suggestions.length + (hasLive ? _liveResults.length + 2 : 0) + (hasLive ? 1 : 0)) {
              return const SizedBox.shrink();
            }
            if (idx < _suggestions.length) return _suggestionTile(context, _suggestions[idx]);
            idx -= _suggestions.length;
            if (hasLive) {
              if (idx == 0) {
                return Divider(color: AurumTheme.dividerOf(context), height: 1, indent: 16, endIndent: 16);
              }
              idx--;
            }
          }
          if (hasLive) {
            if (idx == 0) return _sectionLabel(context, AppLocalizations.of(context)!.librarySongs);
            idx--;
            // CRASH FIX: _liveResults setState() mid-scroll se idx out of bounds
            if (idx < 0 || idx >= _liveResults.length) return const SizedBox.shrink();
            if (idx < _liveResults.length) {
              final song = _liveResults[idx];
              // PERF: fixed height matches SongTile's actual rendered
              // size (same 66px convention the submit-search list uses)
              // so Flutter can lay out this item without measuring its
              // subtree first — cheaper per-item cost during fast scroll.
              return SizedBox(
                height: 66,
                child: _StaggeredItem(
                  index: idx,
                  itemKey: 'live_${song.id}',
                  // GestureDetector wraps SongTile purely to observe the tap
                  // for search-history learning (see _recordSelection doc
                  // comment below) — translucent + onTapDown so it never
                  // intercepts or delays SongTile's own tap handling, it
                  // just also fires alongside it.
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (_) => _recordSelection(query, song),
                    // LIGHTWEIGHT FIX: key used to be suffixed with the
                    // list index ('live_${song.id}_$idx'). A stable key
                    // exists specifically so Flutter can match this element
                    // to the same one from the previous build and reuse its
                    // state/render object instead of tearing it down and
                    // rebuilding from scratch. Appending the index defeats
                    // that entirely — the same song at a different position
                    // (which happens on nearly every keystroke as ranking
                    // shifts) got treated as a brand-new widget every time,
                    // forcing unnecessary rebuilds/relayouts and extra
                    // artwork image churn on every live-search update. The
                    // song id alone is already unique within this list.
                    child: SongTile(
                      key: ValueKey('live_${song.id}'),
                      song: song, queue: _liveResults, index: idx,
                    ),
                  ),
                ),
              );
            }
            idx -= _liveResults.length;
          }
          return _seeAllTile(context, query);
        },
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
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
            // CRASH FIX: _results/itemCount mismatch during scroll+update
            // race. itemCount was computed from _results.length at build()
            // time, but setState() can update _results mid-scroll — i can
            // exceed new _results.length. Bounds check prevents RangeError.
            if (i >= _results.length + (showRelatedHeader ? 1 : 0) + _relatedResults.length) {
              return const SizedBox.shrink();
            }
            if (i < _results.length) {
              return SizedBox(
                height: 66,
                child: _StaggeredItem(
                  index: i,
                  itemKey: 'result_${_results[i].id}',
                  // Non-invasive tap observer for search-history learning —
                  // see _recordSelection doc comment. Never intercepts
                  // SongTile's own tap.
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapDown: (_) => _recordSelection(_controller.text, _results[i]),
                    // LIGHTWEIGHT FIX: same index-suffixed-key issue as the
                    // live panel above — see that fix's doc comment. Song id
                    // is already unique within _results.
                    child: SongTile(
                      key: ValueKey('result_${_results[i].id}'),
                      song: _results[i],
                      queue: i < _resultQueues.length ? _resultQueues[i] : [_results[i]],
                      index: 0,
                    ),
                  ),
                ),
              );
            }
            final headerIdx = _results.length;
            if (showRelatedHeader && i == headerIdx) {
              return _sectionLabel(context, l10n.searchYouMightAlsoLike);
            }
            final relatedIdx = i - _results.length - (showRelatedHeader ? 1 : 0);
            // STABILITY FIX ("sab type karne ke baad, results scroll karte
            // time crash"): itemCount above is computed once per build()
            // from _results.length + _relatedResults.length at that
            // instant. Both lists get reassigned via setState() whenever a
            // fresh search response lands — including while the user is
            // mid-scroll through the PREVIOUS response. Unlike the
            // _results[i] branch above (which already had `if (i <
            // _results.length)`), this branch read _relatedResults[relatedIdx]
            // completely unguarded — if a new, shorter _relatedResults
            // landed while ListView.builder was still requesting indices
            // valid under the OLD (longer) itemCount, relatedIdx could
            // exceed the new list's bounds and throw RangeError: an
            // uncaught exception during frame build, which crashes the
            // app outright instead of showing an error widget. This is
            // the actual "scroll while results update → crash" bug.
            if (relatedIdx < 0 || relatedIdx >= _relatedResults.length) {
              return const SizedBox.shrink();
            }
            return SizedBox(
              height: 66,
              child: _StaggeredItem(
                index: i,
                itemKey: 'related_${_relatedResults[relatedIdx].id}',
                // Related/"you might also like" taps are NOT recorded
                // against the typed query — they weren't a direct match for
                // it, so learning from them would teach the engine a wrong
                // lesson (boosting a loosely-related song for an unrelated
                // query next time).
                // LIGHTWEIGHT FIX: same index-suffixed-key issue as above.
                child: SongTile(
                  key: ValueKey('related_${_relatedResults[relatedIdx].id}'),
                  song: _relatedResults[relatedIdx],
                  queue: relatedIdx < _relatedQueues.length
                      ? _relatedQueues[relatedIdx]
                      : [_relatedResults[relatedIdx]],
                  index: 0,
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
    // FIX: albumTitle pass karo — ab specific movie/album ke songs aayenge
    final tracks = await BrowseService.albumTracks(album.collectionId, isFromYoutube: album.isFromYoutube, albumTitle: album.name);
    if (mounted) setState(() { _albumTracks = tracks; _albumLoading = false; });
  }

  Future<void> _openArtist(BrowseArtist artist) async {
    setState(() { _openArtistName = artist.name; _artistLoading = true; _artistTracks = []; _openAlbumId = null; });
    final tracks = await BrowseService.artistTopSongs(
      artist.name,
      isFromYoutube: artist.isFromYoutube,
      channelId: artist.channelId,
    );
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

    // LIGHTWEIGHT FIX ("browser mai bhi bahut MB/hang" — same root cause
    // as the live-search panel): this was a plain ListView whose track
    // sections (topAlbumTracks, tracks) were built via `.map()` — every
    // track tile (with its own artwork image + gesture handling)
    // instantiated immediately regardless of scroll position. A movie
    // with a large OST or a broad keyword search could mean dozens of
    // tiles and simultaneous image loads on a single search. Converted to
    // CustomScrollView + slivers so the fixed carousels (artists/albums)
    // stay as-is, but each track list is a SliverList.builder — lazily
    // built only as the user actually scrolls to it.
    return CustomScrollView(
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: 0)),
        // PREMIUM FEATURE: complete playlist for a strongly-matched
        // album/movie name, pre-fetched by BrowseService.search — shown
        // above Artists/Albums since it's the most direct answer to "I
        // typed a movie name" and the user shouldn't have to tap the
        // album card first to see it.
        if (widget.result.topAlbum != null && widget.result.topAlbumTracks.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AurumArtwork(url: widget.result.topAlbum!.artworkUrl, size: 48),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.result.topAlbum!.name, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 15, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('${widget.result.topAlbumTracks.length} songs', style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          ),
          SliverList.builder(
            itemCount: widget.result.topAlbumTracks.length,
            itemBuilder: (_, i) {
              final t = widget.result.topAlbumTracks[i];
              return _StaggeredItem(
                index: i,
                itemKey: 'topalbum_${t.trackId}',
                child: _BrowseTrackTile(track: t, onPlay: () => widget.onPlay(t)),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],
        // Artists
        if (widget.result.artists.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionLabel(context, AppLocalizations.of(context)!.libraryArtists)),
          SliverToBoxAdapter(
            child: FadedHorizontalList(
              height: 100,
              controller: _artistsScrollController,
              child: ListView.builder(
                controller: _artistsScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
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
          ),
        ],
        // Albums
        if (widget.result.albums.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionLabel(context, AppLocalizations.of(context)!.libraryAlbums)),
          SliverToBoxAdapter(
            child: FadedHorizontalList(
              height: 180,
              controller: _albumsScrollController,
              child: ListView.builder(
                controller: _albumsScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
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
          ),
        ],
        // Tracks
        if (widget.result.tracks.isNotEmpty) ...[
          SliverToBoxAdapter(child: _sectionLabel(context, AppLocalizations.of(context)!.librarySongs)),
          SliverList.builder(
            itemCount: widget.result.tracks.length,
            itemBuilder: (_, i) {
              final t = widget.result.tracks[i];
              return _StaggeredItem(
                index: i,
                itemKey: 'track_${t.trackId}',
                child: _BrowseTrackTile(track: t, onPlay: () => widget.onPlay(t)),
              );
            },
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
      ],
    );
  }

  Widget _buildTrackList(BuildContext context, String title, bool loading, List<BrowseTrack> tracks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back header
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 20, 8),
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      // FIX (same class as song_tile.dart/library_screen.dart's InkWell
      // fix — "cold start pe kisi bhi title tap karo, grey/white layer
      // aa jaata hai"): ListTile's own internal InkWell had no explicit
      // splashColor/highlightColor, so it used Flutter's unthemed
      // Material default. Search's Browse tab tiles go through THIS
      // widget, not song_tile.dart's SongTile — so fixing SongTile alone
      // never covered a tap here. Same theme-correct, low-opacity color
      // closes this the same way.
      splashColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
      focusColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
      hoverColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
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
          Text(
            album.trackCount != null && album.trackCount! > 1
                ? '${album.artist} • ${album.trackCount} songs'
                : album.artist,
            style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
