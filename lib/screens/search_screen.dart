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
import '../widgets/aurum_stacked_artwork.dart';
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
import '../utils/aurum_transitions.dart';
import 'artist_screen.dart';
import 'album_screen.dart';
import 'mix_screen.dart';
import 'moods_genres_screen.dart';
import '../utils/aurum_motion.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
      duration: AurumMotion.durationOrZero(AurumMotion.long1),
    );
    _ctrl = ctrl;
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: ctrl, curve: AurumMotion.standard));

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

// SimpMusic-style search-result filter chips (All/Songs/Albums/Artists).
// Public (not private to the state class) since it's referenced by the
// chip-row widget below, which is a small standalone StatelessWidget for
// clarity rather than an inline builder method.
enum SearchResultFilter { all, songs, albums, artists, communityPlaylists, featuredPlaylists }

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

  // Search tab state
  List<Song>   _results        = [];
  // FIX ("artist late aata hai / kabhi aata hi nahi" — a real race, not
  // just a display delay): the artist/album lookups used to guard their
  // async response with `_controller.text.trim() != query`, a fragile
  // exact-string comparison. On a slow connection (the screenshots this
  // was reported from show 2-60 KB/s) it's entirely possible for the
  // person to submit query A, then correct/resubmit as query B before
  // A's searchArtists() call resolves — the stale A response arriving
  // late would still pass a string check if the text field happens to
  // read back the same trimmed value, or silently vanish in ways that
  // looked like "artist sometimes just doesn't show up". A monotonically
  // increasing generation counter is the standard, unambiguous fix:
  // every _search() call stamps its own async work with the CURRENT
  // generation, and each callback checks it's still the latest generation
  // before touching state — no string comparison, no ambiguity, works
  // correctly even if two searches for the identical query text race.
  int _searchGeneration = 0;
  // NEW ("search mein artist bhi aaye"): artist matches for the current
  // query, shown as a horizontal row above the song results — separate
  // list, own fetch, never merged into _results so song-result logic
  // (dedup, queues, staggered animation) stays untouched.
  List<ArtistSimple> _artistResults = [];
  // NEW ("albums bhi search mein aaye, Spotify jaisa"): same pattern as
  // _artistResults — separate list, own fetch (searchAlbums),
  // never merged into _results, shown as its own labeled section with a
  // horizontal scroll of artwork cards (Spotify's own Albums search-result
  // shape) rather than the Artists row's vertical list-tile layout.
  List<BrowseAlbum> _albumResults = [];
  // NEW ("SimpMusic jaisa filter chips — All/Songs/Albums/Artists"):
  // which result-type view is currently showing. 'all' is the existing
  // mixed layout (Artists row + Albums row + Songs list) — unchanged.
  // Picking any other chip switches to a dedicated, full-width list for
  // just that type, matching the reference screenshots exactly: albums
  // show as name / "Album • Artist" / year with NO artwork thumbnail
  // crowding the row (the visual complaint in the screenshots was
  // specifically that small square art per row felt cluttered next to
  // mixed song/artist rows — a plain text-forward list reads cleaner at
  // this density). Reset to 'all' on every new search so switching
  // queries doesn't leave you stuck on a filter that happens to have zero
  // results for the new query. Also reachable directly from the Artists/
  // Albums section's own "See all" button in the 'all' view — tapping it
  // sets this straight to the matching filter instead of expanding those
  // sections inline, so it's a one-tap shortcut into the same dedicated
  // view the chip row offers.
  SearchResultFilter _activeFilter = SearchResultFilter.all;
  // Community/Featured playlists filter state — fetched only when their
  // chip is actually selected (not on every keystroke), same lazy
  // pattern as the Albums/Artists dedicated filter views elsewhere in
  // this file.
  List<SearchPlaylistResult> _communityPlaylistResults = [];
  bool _communityPlaylistsLoading = false;
  String _lastCommunityPlaylistQuery = '';
  List<SearchPlaylistResult> _featuredPlaylistResults = [];
  bool _featuredPlaylistsLoading = false;
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

  // Explore/Suggestions landing state (shown when there's no query) —
  // 0 = Explore (mood/genre grid), 1 = Suggestions (unique songs/artists).
  int _landingTabIndex = 0;
  List<MoodGenreSection>? _moodSections;

  // Tracks the body key from the PREVIOUS build so the AnimatedSwitcher's
  // duration can tell "empty -> live" (keystroke #1, should feel instant)
  // apart from every other transition (should keep the normal 280ms feel).
  // Updated at the end of build(), after _computeBodyKey() has already
  // been read for both the duration check and the KeyedSubtree key.
  String _bodyKeyBeforeThisBuild = 'empty';

  Timer? _debounce;
  Timer? _suggestDebounce;

  static const _prefKey    = 'aurum_search_history';
  static const _maxHistory = 10;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _focusNode.addListener(_onFocusChange);
    // Ping Saavn backend the moment search opens — absorbs Render free-tier
    // cold-start delay before the user finishes typing their query.
    ApiService.wakeSaavn();
    _applyActiveState();
    _loadMoodGenres();
  }

  Future<void> _loadMoodGenres() async {
    final cached = await MoodGenreCacheStore.load();
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() => _moodSections = cached);
    }
    final fresh = await MoodGenreCacheStore.isFresh();
    if (cached != null && cached.isNotEmpty && fresh) return;
    final sections = await ApiService.fetchMoodsAndGenres();
    if (!mounted || sections.isEmpty) return;
    setState(() => _moodSections = sections);
    unawaited(MoodGenreCacheStore.save(sections));
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
      // Also invalidate any in-flight live searchArtists/searchAlbums call
      // (see the generation-counter fetch added above) and clear their
      // results — otherwise clearing the text field while those two are
      // still resolving could repopulate the Artists/Albums sections on an
      // now-empty search bar once they land.
      _searchGeneration++;
      setState(() {
        _suggestions  = [];
        _liveResults  = [];
        _liveLoading  = false;
        _showLiveLoader = false;
        _showHistory  = _history.isNotEmpty && _focusNode.hasFocus;
        _artistResults = [];
        _albumResults = [];
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

      // FEATURE ("Udit Narayan ya artist ka naam likho to turant artist
      // card aa jaye" — Musify/SimpMusic-style instant artist match):
      // searchArtists()/searchAlbums() used to ONLY fire from _search(),
      // i.e. only after the user submitted (hit search/enter). Typing
      // alone — the normal, fastest way anyone actually searches — never
      // touched them at all, so an artist name typed and left to the live
      // panel never showed an artist card until you explicitly submitted.
      // Fired here too, same generation-counter guard _search() already
      // uses (see _searchGeneration's doc comment) so a fast-typed stale
      // query's response can't clobber a newer one's results.
      final myLiveGeneration = ++_searchGeneration;
      ApiService.searchArtists(query).then((artists) {
        if (!mounted || myLiveGeneration != _searchGeneration) return;
        setState(() { _artistResults = artists; });
      }).catchError((_) {});
      ApiService.searchAlbums(query).then((albums) {
        if (!mounted || myLiveGeneration != _searchGeneration) return;
        setState(() { _albumResults = albums; });
      }).catchError((_) {});

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
      _artistResults = [];
      _albumResults = [];
      _activeFilter = SearchResultFilter.all;
      _suggestions = [];
      _resultQueues = [];
      _relatedQueues = [];
    });
    // Stamp this search as the new "latest" generation — see the field's
    // doc comment above for why this replaces the old string-comparison
    // guard.
    final myGeneration = ++_searchGeneration;
    _saveToHistory(query);
    // Fire the Artists-row lookup independently — never blocks or delays
    // song results, updates in place whenever it resolves.
    ApiService.searchArtists(query).then((artists) {
      if (!mounted || myGeneration != _searchGeneration) return;
      setState(() { _artistResults = artists; });
    });
    // Fire the Albums-row lookup the same way — own independent fetch,
    // never blocks song results, updates in place whenever it resolves.
    ApiService.searchAlbums(query).then((albums) {
      if (!mounted || myGeneration != _searchGeneration) return;
      setState(() { _albumResults = albums; });
    });
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
    // Invalidate any in-flight searchArtists/searchAlbums call from before
    // the clear — same generation-counter guard as _search() above, so a
    // slow response that lands after clearing can't silently repopulate
    // the Artists/Albums sections on an now-empty search screen.
    _searchGeneration++;
    // STRICT: do NOT requestFocus here — user cleared the text but that
    // doesn't mean they want the keyboard back. They can tap the bar again.
    setState(() {
      _results = []; _relatedResults = []; _liveResults = []; _suggestions = [];
      _artistResults = [];
      _albumResults = [];
      _activeFilter = SearchResultFilter.all;
      _liveLoading = false; _showLiveLoader = false; _loading = false;
      _showHistory = _history.isNotEmpty;
      _resultQueues = []; _relatedQueues = [];
    });
  }

  // Explicit "back to Explore/Suggestions" — the search bar's own back
  // arrow (shown once the user is "inside" search: typing, viewing
  // history, or looking at results). Unlike _clearSearch(), this always
  // lands on the Explore/Suggestions landing screen even when search
  // history exists — a deliberate override, since the whole point of
  // this button is a guaranteed way back to that landing rather than
  // whatever _clearSearch()'s normal fallback would show.
  void _goToLanding() {
    AurumHaptics.light();
    _suggestDebounce?.cancel();
    _debounce?.cancel();
    _liveLoaderGraceTimer?.cancel();
    _dismissKeyboard();
    _controller.clear();
    _searchGeneration++;
    setState(() {
      _results = []; _relatedResults = []; _liveResults = []; _suggestions = [];
      _artistResults = [];
      _albumResults = [];
      _activeFilter = SearchResultFilter.all;
      _liveLoading = false; _showLiveLoader = false; _loading = false;
      _showHistory = false;
      _resultQueues = []; _relatedQueues = [];
    });
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
        // FIX ("search screen ka transparent nav bar ke peeche pill/ghost
        // background aa raha hai, mini player aur nav bar dono par"):
        // this Scaffold's backgroundColor used to be AurumTheme.bgOf(context)
        // — a real opaque color. Same root cause as the "ghost pill" fix
        // already applied to MainShell's OWN Scaffold (see main_shell.dart):
        // Scaffold always paints its backgroundColor as a solid fill across
        // its ENTIRE bounds via its internal Material, full screen height,
        // regardless of extendBody. Since SearchScreen sits inside
        // MainShell's IndexedStack at full screen size — directly behind
        // where MainShell's floating nav bar + mini player render on
        // top — that solid fill was showing through as an opaque pill
        // right behind them, exactly matching Home's transparent look
        // everywhere else but not there. HomeScreen has no Scaffold of its
        // own at all, which is why only Search showed this.
        // Setting this to transparent removes that extra fill; the actual
        // page background color is still painted correctly by MainShell's
        // outer Scaffold (AurumTheme.bgOf(context), see main_shell.dart)
        // underneath everything, so there's no visual change to the
        // background itself — only the stray solid pill behind the
        // floating bar/mini player is gone.
        backgroundColor: Colors.transparent,
        // FIX ("pill abhi bhi gaya nahi, sirf nav bar/mini player ke
        // peeche hi rehta hai, Home/Library clean hain" — the actual
        // missing piece, confirmed by direct comparison with
        // library_screen.dart's own Scaffold): setting backgroundColor
        // to transparent alone wasn't enough. Library's Scaffold — which
        // never shows this pill — has BOTH backgroundColor AND
        // `extendBody: true`. This Scaffold only had the former. Without
        // extendBody: true, Scaffold reserves/consumes bottom
        // MediaQuery padding for its OWN body before SafeArea below ever
        // sees it — that reserved strip is exactly the size and position
        // of MainShell's floating nav bar + mini player, and even with a
        // transparent backgroundColor, Scaffold's internal layout still
        // treats that reserved strip as part of its own solid canvas
        // rather than genuinely passing it through as see-through space
        // the way Home (no Scaffold at all) and Library (extendBody:
        // true) both do. Adding extendBody: true here — the exact same
        // property Library already relies on for this — tells this
        // Scaffold its body may extend all the way to the bottom edge
        // instead of stopping short to reserve that strip, closing the
        // one structural gap between Search and its two sibling tabs.
        extendBody: true,
        // BUGFIX (duplicate mini player on Search — two players stacked
        // on screen at once): SearchScreen is a ROOT TAB inside MainShell's
        // IndexedStack (exactly like HomeScreen), not a screen pushed via
        // Navigator.push. MainShell's own Scaffold already renders a
        // persistent MiniPlayer + nav bar in ITS bottomNavigationBar,
        // unconditionally, underneath all three tabs (see main_shell.dart).
        // A previous fix here added `extendBody: true` and
        // `bottomNavigationBar: const MiniPlayerSlot()` to this screen's
        // OWN inner Scaffold to solve a "mini player looks like a
        // translucent overlay" visual glitch — but MiniPlayerSlot renders
        // a real, second MiniPlayer widget. That pattern is only correct
        // for screens actually PUSHED on top of a tab (Liked Songs,
        // Downloads, Album, Artist, etc. — see MiniPlayerSlot's own doc
        // comment and how library_screen.dart uses it for its pushed
        // sub-screens), where the nav bar is hidden and something needs to
        // reserve/show the mini player in its place. Search never leaves
        // the tab host, so MainShell's outer MiniPlayer was already
        // correctly on screen the whole time — this inner one was purely
        // extra. Re-adding ONLY extendBody: true here (unlike that old
        // fix) does NOT bring back the duplicate-mini-player bug — no
        // bottomNavigationBar or MiniPlayerSlot is added on this Scaffold,
        // so there's still exactly one MiniPlayer in the whole screen,
        // MainShell's own.
        body: SafeArea(
          // FIX (pairs with extendBody: true above): bottom: false here
          // stops SafeArea from ALSO reserving its own bottom inset on
          // top of what extendBody already lets the body extend into.
          // With extendBody: true, this Scaffold's body is meant to run
          // all the way to the screen's bottom edge (transparent,
          // nothing painted there) exactly like Home/Library — a
          // default SafeArea(bottom: true) here would carve out a second,
          // redundant reserved strip at the same spot, undoing part of
          // what extendBody was just turned on to fix. Top inset (status
          // bar, notch) is still respected as before — only the bottom
          // reservation is turned off.
          bottom: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
            children: [
              _buildHeader(context),
              _buildSearchBar(context),
              _buildFilterChips(context),
              Expanded(
                child:
                    // FIX (nav bar showed solid/opaque on Search but
                    // transparent on Home): this used to be
                    // `ColoredBox(color: AurumTheme.bgOf(context))`
                    // wrapping the whole tab. Because this tab sits inside
                    // an Expanded that fills all available height under
                    // MainShell's extendBody:true Scaffold, that ColoredBox
                    // painted a full opaque rectangle all the way down
                    // behind the floating nav bar too — blocking the same
                    // transparency Home gets for free (Home has no single
                    // full-area ColoredBox, so nothing ever paints behind
                    // the bar there). The Scaffold's own backgroundColor
                    // (set once above, not part of this animated subtree)
                    // already shows through anywhere content doesn't reach,
                    // so no replacement fill is needed here.
                    AnimatedSwitcher(
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
                        ).animate(CurvedAnimation(parent: animation, curve: AurumMotion.standard));
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: slide,
                            child: child,
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey(currentBodyKey),
                        child: _buildBody(context),
                      ),
                    ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  // ── Filter chips (ArchiveTune-style: All / Songs / Albums / Artists,
  // pill row with a leading check on the selected chip) ──
  //
  // Only makes sense once there's an actual query with results.
  Widget _buildFilterChips(BuildContext context) {
    final hasQuery = _controller.text.trim().isNotEmpty;
    final hasAnyResults = _results.isNotEmpty || _artistResults.isNotEmpty || _albumResults.isNotEmpty;
    if (!hasQuery || !hasAnyResults) {
      return const SizedBox.shrink();
    }
    final chips = <(SearchResultFilter, String, IconData)>[
      (SearchResultFilter.all, 'All', Icons.check_rounded),
      (SearchResultFilter.songs, 'Songs', Icons.music_note_rounded),
      (SearchResultFilter.albums, 'Albums', Icons.album_rounded),
      (SearchResultFilter.artists, 'Artists', Icons.person_rounded),
      (SearchResultFilter.communityPlaylists, 'Community playlists', Icons.groups_rounded),
      (SearchResultFilter.featuredPlaylists, 'Featured playlists', Icons.playlist_play_rounded),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (filter, label, icon) = chips[i];
          final selected = _activeFilter == filter;
          return _PressScale(
            onTap: () {
              if (selected) return;
              setState(() => _activeFilter = filter);
              // Lazy-fetch the two playlist tabs only when actually
              // selected — never on every keystroke, same reasoning as
              // the Albums/Artists dedicated views already use.
              if (filter == SearchResultFilter.communityPlaylists) {
                _fetchCommunityPlaylists(_controller.text.trim());
              } else if (filter == SearchResultFilter.featuredPlaylists) {
                _fetchFeaturedPlaylists();
              }
            },
            child: AnimatedContainer(
              duration: AurumMotion.durationOrZero(AurumMotion.medium1),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: selected ? AurumTheme.accentGradient : null,
                color: selected ? null : AurumTheme.bgCardOf(context),
                borderRadius: BorderRadius.circular(20),
                border: selected
                    ? null
                    : Border.all(color: AurumTheme.dividerOf(context), width: 0.6),
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: AurumTheme.accentOf(context).withOpacity(0.35),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected ? Colors.black : AurumTheme.textSecondaryOf(context),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? Colors.black : AurumTheme.textSecondaryOf(context),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Dedicated Albums view (SimpMusic-style: no artwork thumbnail, just
  // name / "Album • Artist" / year — matches the reference screenshot's
  // clean, text-forward density) ──
  Widget _buildAlbumsFilterView(BuildContext context) {
    if (_albumResults.isEmpty) {
      return _buildEmptyFilterState(context, 'No albums found');
    }
    return ListView.builder(
      key: const ValueKey('albums_filter'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
      itemCount: _albumResults.length,
      itemBuilder: (context, i) {
        final album = _albumResults[i];
        return _buildAlbumFilterRow(context, album);
      },
    );
  }

  Widget _buildAlbumFilterRow(BuildContext context, BrowseAlbum album) {
    return AurumPressable(
      onTap: () => _openAlbumFromSearch(context, album),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // FIX ("albums bhi thumbnail nahi aa rahe hai"): this row used
            // to be text-only (name + "Album • Artist • Year"), with no
            // artwork at all — every other album surface in the app
            // (Browse tab's _AlbumCard, the horizontal Albums row in the
            // 'All' filter's _buildAlbumSection) already shows real
            // artwork via AurumArtwork, so the dedicated Albums filter
            // list was the one place missing it. Same widget, same
            // rounded-square treatment, sized for a list row instead of a
            // grid card.
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AurumArtwork(url: album.artworkUrl, size: 52),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      album.isFromYoutube ? 'YouTube' : 'Saavn',
                      if (album.artist.isNotEmpty) album.artist,
                      if (album.releaseYear != null) album.releaseYear!,
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Dedicated Artists view (same text-forward density as Albums above)
  Widget _buildArtistsFilterView(BuildContext context) {
    if (_artistResults.isEmpty) {
      return _buildEmptyFilterState(context, 'No artists found');
    }
    return ListView.builder(
      key: const ValueKey('artists_filter'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
      itemCount: _artistResults.length,
      itemBuilder: (context, i) => _buildArtistListTile(context, _artistResults[i]),
    );
  }

  Widget _buildEmptyFilterState(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Text(
          message,
          style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
        ),
      ),
    );
  }

  // ── Community playlists filter (real YT Music playlist search results
  // for the current query, via ApiService.searchPlaylists) ──
  Future<void> _fetchCommunityPlaylists(String query) async {
    if (!mounted || query.isEmpty) return;
    if (query == _lastCommunityPlaylistQuery && _communityPlaylistResults.isNotEmpty) return;
    _lastCommunityPlaylistQuery = query;
    setState(() => _communityPlaylistsLoading = true);
    List<SearchPlaylistResult> results;
    try {
      results = await ApiService.searchPlaylists(query);
    } catch (_) {
      if (mounted && _lastCommunityPlaylistQuery == query) {
        setState(() => _communityPlaylistsLoading = false);
      }
      return;
    }
    if (mounted && _lastCommunityPlaylistQuery == query) {
      setState(() {
        _communityPlaylistResults = results;
        _communityPlaylistsLoading = false;
      });
    }
  }

  Widget _buildCommunityPlaylistsFilterView(BuildContext context) {
    if (_communityPlaylistsLoading && _communityPlaylistResults.isEmpty) {
      return const Center(child: AurumMorphLoader());
    }
    if (_communityPlaylistResults.isEmpty) {
      return _buildEmptyFilterState(context, 'No community playlists found');
    }
    return ListView.builder(
      key: const ValueKey('community_playlists_filter'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
      itemCount: _communityPlaylistResults.length,
      itemBuilder: (context, i) =>
          _buildPlaylistResultTile(context, _communityPlaylistResults[i]),
    );
  }

  // ── Featured playlists filter (real YouTube Music InnerTube data — the
  // same official-weekly-chart queries fetchFeaturedPlaylistsForYou uses
  // for the home feed's "Featured playlists for you" shelf, just fetched
  // with a higher take() for a fuller list here — independent of the
  // typed query, same as how YT Music's own "Featured playlists" search
  // tab shows curated picks rather than a text match) ──
  Future<void> _fetchFeaturedPlaylists() async {
    if (!mounted || _featuredPlaylistResults.isNotEmpty) return;
    setState(() => _featuredPlaylistsLoading = true);
    List<SearchPlaylistResult> results;
    try {
      results = await ApiService.fetchFeaturedPlaylistsForSearch();
    } catch (_) {
      if (mounted) setState(() => _featuredPlaylistsLoading = false);
      return;
    }
    if (mounted) {
      setState(() {
        _featuredPlaylistResults = results;
        _featuredPlaylistsLoading = false;
      });
    }
  }

  Widget _buildFeaturedPlaylistsFilterView(BuildContext context) {
    if (_featuredPlaylistsLoading && _featuredPlaylistResults.isEmpty) {
      return const Center(child: AurumMorphLoader());
    }
    if (_featuredPlaylistResults.isEmpty) {
      return _buildEmptyFilterState(context, 'No featured playlists found');
    }
    return ListView.builder(
      key: const ValueKey('featured_playlists_filter'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 80),
      itemCount: _featuredPlaylistResults.length,
      itemBuilder: (context, i) =>
          _buildPlaylistResultTile(context, _featuredPlaylistResults[i]),
    );
  }

  // Shared row for both playlist filter tabs — real title/author/artwork,
  // tap opens MixScreen and lazy-loads the actual song list via
  // ApiService.fetchYtPlaylistSongs (both Community and Featured
  // playlists are real YouTube Music InnerTube playlist ids — no other
  // source), same "empty songs, autoLoadMore resolves it" pattern
  // MixScreen's other real callers already use elsewhere in the app.
  Widget _buildPlaylistResultTile(
    BuildContext context,
    SearchPlaylistResult playlist,
  ) {
    return AurumPressable(
      scaleAmount: 0.97,
      onTap: () {
        AurumHaptics.light();
        _dismissKeyboard();
        AurumDepthRoute.to(
          context,
          MixScreen(
            mixId: playlist.id,
            mixName: playlist.title,
            artworkUrl: playlist.artworkUrl,
            emoji: '',
            songs: const [],
            autoLoadMore: () => ApiService.fetchYtPlaylistSongs(playlist.id),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AurumArtwork(url: playlist.artworkUrl, size: 56),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    playlist.author.isNotEmpty ? playlist.author : 'Playlist',
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 22),
          ],
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
    // FILTER FIX ("Songs/Albums/Artists chip select karo to bhi wahi All
    // wala mixed view dikhta hai — chip kaam hi nahi kar raha"): the chips
    // only ever drove _buildResults(), which is exclusively reached via
    // the `_results.isNotEmpty` branch below — i.e. only AFTER a submitted
    // search. The far more common path — live/typeahead results, which is
    // everything the user sees while just typing and never hitting
    // enter — went through _buildLivePanel() instead, a completely
    // separate widget tree that never looked at _activeFilter at all. So
    // picking "Songs" while still typing (the normal, fast way anyone
    // searches) visibly did nothing: you'd still see the full mixed
    // Artists+Albums+Songs stack underneath the chip row. Checking the
    // active filter FIRST, before deciding which underlying data source
    // (_results vs live _liveResults/_artistResults/_albumResults) to
    // read from, makes every chip apply immediately regardless of whether
    // a search has been submitted yet — exactly like Spotify/YouTube
    // Music, where the filter applies the instant you tap it, live typing
    // included.
    if (_activeFilter == SearchResultFilter.albums) {
      return _buildAlbumsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.artists) {
      return _buildArtistsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.communityPlaylists) {
      return _buildCommunityPlaylistsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.featuredPlaylists) {
      return _buildFeaturedPlaylistsFilterView(context);
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
          shaderCallback: (b) => AurumTheme.accentGradient.createShader(b),
          child: Text(l10n.searchTabSearch, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.2)),
        ),
      ]),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final focused = _focusNode.hasFocus;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // GLASS LOOK ("glass but ekdam lightweight, low end device"): a real
    // frosted-glass effect needs BackdropFilter(ImageFilter.blur), which
    // makes Skia re-blur everything BEHIND this widget on every single
    // frame it's visible — on a low-end Android GPU that's a guaranteed
    // jank source, worse the moment this bar scrolls or the keyboard
    // animates in/out underneath it. This gets the same "frosted glass"
    // read — soft translucent tint, a hairline light border catching an
    // edge like glass would, no hard flat fill — using only a static
    // gradient + border, which costs nothing beyond what a plain colored
    // Container already cost. No blur, no shader, no extra repaint layer.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: AnimatedContainer(
        duration: AurumMotion.durationOrZero(AurumMotion.medium1),
        curve: Curves.easeOut,
        // BUG FIX ("keyboard khulte hi search bar ekdam upar tak pill jaisa
        // ban jata hai"): this container had no height constraint at all —
        // it relied entirely on the TextField's own intrinsic content
        // height to size itself. The TextField's InputDecoration never set
        // isDense, so Flutter's default (non-dense) InputDecorator
        // reserves extra built-in vertical slack for a helper/error text
        // line even when none is ever shown here — normally a few pixels
        // of unnoticed padding, but this bar sits inside a Column that
        // reflows on every keyboard-open layout pass (the whole search
        // results/history area resizes as the keyboard's bottom inset
        // changes), and that reflow is what let this box's height balloon
        // visibly instead of settling back to its normal compact size,
        // giving exactly the "ekdam upar tak pill" symptom. Pinning an
        // explicit height here (44, matching this app's other compact
        // search/nav bars — see the height: 44 pill elsewhere in this
        // file) means this bar's size can never depend on the
        // TextField's variable intrinsic height at all, keyboard open or
        // not. isDense: true below removes the same extra slack at its
        // source too, as defense in depth.
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [Colors.white.withOpacity(0.10), Colors.white.withOpacity(0.04)]
                // LIGHT-MODE FIX ("awkward na lage"): light theme's bg
                // (#F5F3ED, a soft cream) sits very close to white already —
                // a white-tinted gradient at 0.55→0.28 opacity barely reads
                // as glass there, it just looks like a flat washed-out
                // card with almost no depth against a near-white page.
                // Using the app's own dark card tone (bgCard, #0D0D14) at
                // low opacity instead gives the frosted panel actual
                // contrast against the cream background — visibly "glassy"
                // rather than nearly invisible — while staying just as
                // cheap (still a static gradient, no blur).
                : [
                    AurumTheme.darkBgCard.withOpacity(0.06),
                    AurumTheme.darkBgCard.withOpacity(0.03),
                  ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: focused
                ? AurumTheme.accentOf(context).withOpacity(0.6)
                : (isDark ? Colors.white.withOpacity(0.14) : Colors.black.withOpacity(0.08)),
            width: focused ? 1.3 : 0.7,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: AurumTheme.accentOf(context).withOpacity(0.16),
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
            // DIRECT FIX ("box mai click krte hi history aa jaye"): the
            // focus-listener (_onFocusChange) only fires setState when
            // _showHistory's value actually flips — if the field was
            // already focused (or the listener's async focus-gained
            // event is simply slow/flaky), tapping back into an empty
            // box with real history sometimes left the Explore landing
            // showing instead of history. Setting it directly here, on
            // the real tap gesture, makes it immediate and doesn't wait
            // on any focus-change callback timing.
            if (_controller.text.trim().isEmpty && _history.isNotEmpty && !_showHistory) {
              setState(() => _showHistory = true);
            }
          },
          onChanged: _onChanged,
          onSubmitted: _search,
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
            prefixIcon: Icon(Icons.search_rounded,
                color: focused ? AurumTheme.accentOf(context) : AurumTheme.textMutedOf(context), size: 20),
            // Right side: a back arrow whenever the user is "inside"
            // search (focused, typing, viewing history, or looking at
            // results) — a guaranteed one-tap way back to the
            // Explore/Suggestions landing, since focus-based auto-return
            // isn't reliable on its own (the field can stay focused
            // without a fresh focus-gained event firing again). When
            // there's also text typed, the clear(X) sits right next to
            // it — clearing text alone (keep the keyboard open, stay in
            // search) is still a separate, more common gesture than
            // fully backing out.
            suffixIcon: (focused || _controller.text.isNotEmpty || _showHistory)
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_controller.text.isNotEmpty)
                        AurumPressable(
                          scaleAmount: 0.82,
                          onTap: _clearSearch,
                          child: Icon(Icons.close_rounded, color: AurumTheme.textMutedOf(context), size: 18),
                        ),
                      AurumPressable(
                        scaleAmount: 0.82,
                        onTap: _goToLanding,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10, right: 4),
                          child: Icon(Icons.arrow_back_rounded, color: AurumTheme.textMutedOf(context), size: 20),
                        ),
                      ),
                    ],
                  )
                : null,
            border: InputBorder.none,
            // BUG FIX (part of the "pill grows tall on keyboard open" fix
            // above): isDense removes InputDecorator's default extra
            // vertical slack, which combined with the parent
            // AnimatedContainer's fixed height:44 above stops this bar
            // from ever being able to grow taller than its intended
            // compact size, keyboard open or not. contentPadding reduced
            // from vertical:14 to vertical:10 to actually fit within that
            // fixed 44px height alongside the 20px icons and ~20px text
            // line — the old vertical:14 (28px total) plus text line
            // would have exceeded 44px and clipped/overflowed now that
            // the container can no longer silently grow to accommodate it.
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
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
                child: Text(l10n.searchClearAll, style: TextStyle(color: AurumTheme.accentOf(context).withOpacity(0.8), fontSize: 12)),
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
      // FILTER FIX: same "Songs chip still shows Artists/Albums" bug as
      // _buildBody above — this header must only appear on the 'all'
      // chip. When the Songs chip is active (the only other filter that
      // reaches this live panel; Albums/Artists chips are intercepted
      // earlier in _buildBody and never reach here at all), this must be
      // a clean songs-only list, exactly like the submitted-search
      // _buildResults() branch already does via showArtistAlbumHeader.
      final showArtistAlbumHeaderLive = _activeFilter == SearchResultFilter.all &&
          (_artistResults.isNotEmpty || _albumResults.isNotEmpty);
      final artistAlbumHeaderCount = showArtistAlbumHeaderLive ? 1 : 0;
      final headerCount = (_liveLoading ? 1 : 0)
          + (hasSuggestions ? _suggestions.length + (hasLive ? 1 : 0) : 0)
          + (hasLive ? 1 : 0); // the "Songs" section label itself
      final tailCount = query.isNotEmpty ? 1 : 0;
      final totalCount = artistAlbumHeaderCount + headerCount + (hasLive ? _liveResults.length : 0) + tailCount;

      // SMOOTH FIX: same RepaintBoundary isolation as the submit-search
      // results list below — this live-typing list scrolls independently
      // of the header/search bar above it, so it shouldn't repaint them.
      content = RepaintBoundary(child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: totalCount,
        // PERF: bounds how much off-screen content gets pre-built while
        // scrolling — same tuning as the submit-search results list below.
        cacheExtent: 600,
        itemBuilder: (context, rawI) {
          var i = rawI;
          // SCROLL/FREEZE FIX ("scroll bhi nahi ho raha... See all pe
          // stuck"): Artists/Albums used to be siblings of Expanded(content)
          // in a non-scrolling Column below — an unbounded Artists list or
          // an expanded Albums Wrap would overflow that fixed Column
          // instead of scrolling. Folding them in as this list's own first
          // item means the whole live panel (artists + albums + songs)
          // scrolls together, and "See all" just makes this one item
          // taller instead of breaking the layout.
          if (showArtistAlbumHeaderLive) {
            if (i == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildArtistSection(context),
                  _buildAlbumSection(context),
                ],
              );
            }
            i--;
          }
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
              // size. SIZE FIX: SongTile's cover art went 50→64→58px
              // app-wide across two rounds of feedback, which settled
              // its real row height at 86 (20 vertical padding + the
              // 66px artwork box AurumStackedArtwork draws at size+8
              // headroom) — updated so this fixed height matches the
              // tile's actual current size instead of clipping it,
              // while keeping the same "skip subtree measurement" perf
              // win this convention exists for.
              return SizedBox(
                height: 86,
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
      ));
    }

    return KeyedSubtree(
      key: const ValueKey('live'),
      // BUGFIX ("search mein artist bhi aaye" — nahi aata tha, real mein):
      // the Musify-style Artists section (see _buildArtistSection) is now
      // folded directly into the scrollable `content` ListView above (see
      // the showArtistAlbumHeaderLive branch) instead of sitting outside
      // it in a fixed Column — see that branch's doc comment for why.
      child: content,
    );
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

  // "Top results" header — ArchiveTune-style: a short gold accent bar
  // plus a bold title, sitting above the first results list (matches the
  // reference screenshot's "▎Top results" section header, distinct from
  // the smaller uppercase _sectionLabel used for "You might also like").
  Widget _topResultsHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              gradient: AurumTheme.accentGradient,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Top results',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
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
      leading: Icon(Icons.travel_explore_rounded, color: AurumTheme.accentOf(context), size: 20),
      title: Text(l10n.searchSeeAllResultsFor(query), style: TextStyle(color: AurumTheme.accentOf(context), fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(Icons.arrow_forward_ios_rounded, color: AurumTheme.accentOf(context).withOpacity(0.6), size: 14),
      dense: true,
      onTap: () => _search(query),
    );
  }

  // ── Results ──────────────────────────────────────────────────

  Widget _buildResults() {
    final l10n = AppLocalizations.of(context)!;
    // FILTER BRANCH ("SimpMusic jaisa — albums/artists apna clean section,
    // mixed list mein nahi"): a non-'all' chip swaps the ENTIRE results
    // area for a dedicated, single-type list instead of the mixed
    // Artists-row + Albums-row + Songs-list layout below. Songs reuses
    // the existing mixed-list machinery (it's already just a song list),
    // Albums/Artists get their own clean, text-forward views built for
    // this — see _buildAlbumsFilterView/_buildArtistsFilterView above.
    if (_activeFilter == SearchResultFilter.albums) {
      return _buildAlbumsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.artists) {
      return _buildArtistsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.communityPlaylists) {
      return _buildCommunityPlaylistsFilterView(context);
    }
    if (_activeFilter == SearchResultFilter.featuredPlaylists) {
      return _buildFeaturedPlaylistsFilterView(context);
    }
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

    // SCROLL/FREEZE FIX ("scroll bhi nahi ho raha... See all pe stuck ho ja
    // raha hai"): _buildArtistSection and _buildAlbumSection used to be
    // siblings of Expanded(ListView) inside a plain, non-scrolling Column.
    // Both are UNBOUNDED-height widgets once expanded — the Artists section
    // is a vertical list of full-width rows with no cap, and Albums' "See
    // all" swaps its bounded 190px horizontal strip for an unbounded Wrap
    // grid. With more artists/albums now available (Saavn fallback), that
    // Column simply overflowed its fixed space instead of scrolling —
    // which is exactly what read as "stuck"/frozen and "can't scroll".
    // Fix: fold both sections INTO the scrollable ListView as its own
    // leading item, so the whole page (artists + albums + songs) scrolls
    // together as one unit and an expanded Wrap just makes that first item
    // taller instead of overflowing anything.
    final showArtistAlbumHeader = _activeFilter == SearchResultFilter.all &&
        (_artistResults.isNotEmpty || _albumResults.isNotEmpty);
    final showTopResultsHeader = _activeFilter == SearchResultFilter.all &&
        (_results.isNotEmpty || showArtistAlbumHeader);
    final headerItemCount = (showTopResultsHeader ? 1 : 0) + (showArtistAlbumHeader ? 1 : 0);

    return Stack(
      children: [
        RepaintBoundary(
          child: ListView.builder(
            key: const ValueKey('results'),
            physics: const BouncingScrollPhysics(),
            cacheExtent: 800,
            itemCount: headerItemCount + itemCount,
            padding: const EdgeInsets.only(bottom: 80),
            itemBuilder: (_, rawIndex) {
              if (showTopResultsHeader && rawIndex == 0) {
                return _topResultsHeader(context);
              }
              final afterTopIndex = rawIndex - (showTopResultsHeader ? 1 : 0);
              if (showArtistAlbumHeader && afterTopIndex == 0) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildArtistSection(context),
                    _buildAlbumSection(context),
                  ],
                );
              }
              final i = afterTopIndex - (showArtistAlbumHeader ? 1 : 0);
            // CRASH FIX: _results/itemCount mismatch during scroll+update
            // race. itemCount was computed from _results.length at build()
            // time, but setState() can update _results mid-scroll — i can
            // exceed new _results.length. Bounds check prevents RangeError.
            if (i >= _results.length + (showRelatedHeader ? 1 : 0) + _relatedResults.length) {
              return const SizedBox.shrink();
            }
            if (i < _results.length) {
              // SIZE FIX: see the live-panel SizedBox above for why this
              // is 86 now — same SongTile height reasoning.
              return SizedBox(
                height: 86,
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
            // SIZE FIX: see the live-panel SizedBox above for why this
            // is 86 now — same SongTile height reasoning.
            return SizedBox(
              height: 86,
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

  // MUSIFY-STYLE ("same aisa chahiye" — reference: Musify app search UI):
  // vertical list, not a horizontal scroll row — each artist is a full-width
  // row (circular avatar, name, "Artist" subtitle, trailing chevron),
  // exactly the same row shape as a song result below it, under a labeled
  // section header with a small leading icon. Replaces the earlier
  // Spotify-style horizontal-scroll row + separate "Top Result" hero card
  // per explicit direction to match Musify's simpler vertical-list pattern
  // instead.
  // CAP FIX ("aisa na lage ki artists hi khatam nahi ho rahe" —
  // ApiService.searchArtists() fetches up to 12 artists (see limit: 12 in
  // api_service.dart), and this section used to render every single one
  // as a full-width, uncapped Column above the Songs list. At ~72px per
  // row, 12 artists is ~860px — on a typical phone that pushes the entire
  // Songs section (the thing most people actually searched for) off the
  // bottom of the first screen, so the user has to scroll past a wall of
  // artist rows before seeing a single song. Real reference apps
  // (Spotify, Musify) cap this row count and let the section stay a
  // small, glanceable block instead of dominating the results. Capping
  // here (not by lowering the API's own limit) keeps ArtistScreen /
  // any other future consumer of the full 12-result list unaffected —
  // this is purely how many of them SearchScreen chooses to *render*.
  static const int _maxVisibleArtists = 4;

  Widget _buildArtistSection(BuildContext context) {
    if (_artistResults.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    // SPOTIFY-STYLE cap: this section only ever shows the first
    // _maxVisibleArtists rows — "See all" (below) no longer expands this
    // same list inline, it jumps straight to the dedicated Artists chip
    // view instead (see the button's own comment), so there's no
    // "expanded" state left to track here anymore.
    final hasMore = _artistResults.length > _maxVisibleArtists;
    final visible = hasMore
        ? _artistResults.sublist(0, _maxVisibleArtists)
        : _artistResults;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              Icon(Icons.person_rounded, color: AurumTheme.accentOf(context), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.libraryArtists,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // NAV FIX ("See all pe click kro to seedha Artists tab pe le
              // jaye, cool animation ke sath" — this used to just expand
              // more rows inline on the SAME mixed page. That's fine for a
              // "show a few more" action, but the user wants See all to
              // behave as a real shortcut into the dedicated Artists chip
              // view (_buildArtistsFilterView) — same clean, full list
              // that chip already shows, just reached in one tap from
              // here instead of having to go find the chip row above.
              // AurumHaptics.selection() (not .light()) matches the exact
              // feedback the chip itself fires on tap — same physical
              // "switching a mode" feel — and setState (not a Navigator
              // push) means it rides the SAME AnimatedSwitcher/chip
              // AnimatedContainer transitions already wired for chip taps,
              // so no separate animation needed: the existing cross-fade
              // + chip color/gradient swap IS the "cool" transition.
              if (hasMore)
                GestureDetector(
                  onTap: () {
                    AurumHaptics.selection();
                    setState(() => _activeFilter = SearchResultFilter.artists);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Text(
                      l10n.commonSeeAll,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ...List.generate(visible.length, (i) {
          final a = visible[i];
          return _buildArtistListTile(context, a);
        }),
      ],
    );
  }

  Widget _buildArtistListTile(BuildContext context, ArtistSimple a) {
    return AurumPressable(
      onTap: () {
        AurumHaptics.light();
        Navigator.push(
          context,
          AurumDepthRoute(
            builder: (_) => ArtistScreen(artistId: a.id, artistName: a.name),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            ClipOval(child: AurumArtwork(url: a.imageUrl, size: 56)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.name,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Artist',
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context), size: 22),
          ],
        ),
      ),
    );
  }

  // ── Albums section ("Spotify jaisa ekdam", horizontal artwork-card row)

  static const int _maxVisibleAlbums = 10;

  Widget _buildAlbumSection(BuildContext context) {
    if (_albumResults.isEmpty) return const SizedBox.shrink();
    // SPOTIFY-STYLE ALBUMS ROW: unlike the Artists section (vertical list
    // of full-width rows), Spotify's own Albums search-result section is
    // a horizontally-scrolling row of square artwork cards with title +
    // artist underneath — this mirrors that exactly using the shape
    // _AlbumCard already established for the Browse tab, just fed
    // real search-result albums instead of curated browse categories.
    // "See all" here expands into a wrapped grid inline (same one-way,
    // no-collapse behavior as the Artists section) rather than opening a
    // new screen, keeping the search screen self-contained.
    final hasMore = _albumResults.length > _maxVisibleAlbums;
    final visible = hasMore
        ? _albumResults.sublist(0, _maxVisibleAlbums)
        : _albumResults;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Row(
            children: [
              Icon(Icons.album_rounded, color: AurumTheme.accentOf(context), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Albums',
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // NAV FIX: same pattern as Artists' See all above — jumps
              // straight into the dedicated Albums chip view instead of
              // just expanding more cards inline on this mixed page.
              if (hasMore)
                GestureDetector(
                  onTap: () {
                    AurumHaptics.selection();
                    setState(() => _activeFilter = SearchResultFilter.albums);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Text(
                      l10n.commonSeeAll,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        // ALWAYS the horizontal scroll row now — "See all" jumps straight
        // to the dedicated Albums chip view (see button above) instead of
        // expanding into a wider grid inline, so this section never needs
        // to render as anything other than the compact horizontal strip.
        SizedBox(
          height: 190,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: visible.length,
            itemBuilder: (context, i) => _AlbumCard(
              album: visible[i],
              onTap: () => _openAlbumFromSearch(context, visible[i]),
            ),
          ),
        ),
      ],
    );
  }

  void _openAlbumFromSearch(BuildContext context, BrowseAlbum album) {
    AurumHaptics.light();
    Navigator.push(
      context,
      AurumDepthRoute(
        builder: (_) => AlbumScreen(
          albumId: album.collectionId,
          albumName: album.name,
          artworkUrl: album.artworkUrl,
        ),
      ),
    );
  }

  // ── Empty state ──────────────────────────────────────────────

  Widget _buildEmpty(BuildContext context) {
    // Explore/Suggestions landing — ArchiveTune-style: a pill segmented
    // switcher ALWAYS renders first (fixed position, never conditional on
    // any data having loaded yet) so switching tabs never shifts or
    // reflows anything above it — this was the actual cause of the
    // "upar niche upar niche" jump: the switcher used to only appear once
    // mood-grid data had loaded, so tapping Suggestions before that
    // finished made the whole switcher vanish.
    return Column(
      key: const ValueKey('explore'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLandingSwitcher(context),
        Expanded(
          child: _landingTabIndex == 0
              ? _buildExploreGrid(context)
              : _buildSuggestionsLanding(context),
        ),
      ],
    );
  }

  // Segmented "Explore / Suggestions" switcher — matches the reference's
  // two-tab landing (Explore shows Mood & Genres, Suggestions shows the
  // user's own Unique Songs / Unique Artists).
  Widget _buildLandingSwitcher(BuildContext context) {
    Widget tab(String label, int index) {
      final selected = _landingTabIndex == index;
      return Expanded(
        child: _PressScale(
          onTap: () {
            if (selected) return;
            setState(() => _landingTabIndex = index);
          },
          child: AnimatedContainer(
            duration: AurumMotion.durationOrZero(AurumMotion.medium1),
            curve: Curves.easeOut,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: selected ? AurumTheme.accentGradient : null,
              color: selected ? null : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AurumTheme.accentOf(context).withOpacity(0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected
                    ? Colors.black
                    : AurumTheme.textMutedOf(context),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.6),
        ),
        child: Row(children: [tab('Explore', 0), const SizedBox(width: 4), tab('Suggestions', 1)]),
      ),
    );
  }

  Widget _buildExploreGrid(BuildContext context) {
    final sections = _moodSections;
    if (sections == null || sections.isEmpty) {
      return const Center(child: AurumMorphLoader());
    }
    // Flatten every section's tiles into one combined grid (dedup by
    // title) rather than just the first section's — a single section
    // alone can come back under 30 tiles from InnerTube, and this tab
    // needs a full, "kam se kam 30" grid, not a short preview pointing
    // to a separate "See all" screen.
    final seenTitles = <String>{};
    final tiles = <MoodGenreCategory>[];
    for (final section in sections) {
      for (final tile in section.items) {
        if (seenTitles.add(tile.title)) tiles.add(tile);
      }
    }
    return SingleChildScrollView(
      key: const ValueKey('explore_grid'),
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Mood & Genres',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: tiles.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2.1,
              ),
              itemBuilder: (context, i) {
                final tile = tiles[i];
                final color = tile.color != null
                    ? Color(tile.color!).withAlpha(255)
                    : AurumTheme.bgCardOf(context);
                return _ExploreMoodTile(
                  title: tile.title,
                  color: color,
                  artworkUrl: tile.artworkUrl,
                  onTap: () {
                    AurumHaptics.selection();
                    _dismissKeyboard();
                    AurumDepthRoute.to(
                      context,
                      MoodGenreDetailScreen(category: tile, tileColor: color),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Suggestions landing: real InnerTube-backed recommendations, same
  // sources Home's own personalized rows use — see _SuggestionsLanding
  // below for the actual data plumbing.
  Widget _buildSuggestionsLanding(BuildContext context) {
    return const _SuggestionsLanding();
  }
}

// Real recommendation data for the Search screen's "Suggestions" tab —
// deliberately mirrors Home's own personalized sections 1:1 rather than
// inventing a new source:
//   • "Unique Songs"   -> ApiService.fetchYouMightAlsoLike(seedVideoId),
//     the exact same InnerTube "related videos" call powering Home's
//     "You might also like" row (see _YouMightAlsoLikeSection in
//     home_screen.dart), seeded from the user's most-recently-played
//     song.
//   • "Unique Artists" -> ApiService.fetchSimilarArtistChips(name), the
//     exact same InnerTube "Fans might also like" related-artists call
//     powering Home's "Similar to <Artist>" circular rows (see
//     _SimilarArtistsSection), seeded from
//     RecommendationEngine.rotatingAffinityArtists — same on-device
//     listening-affinity ranking Home uses. Real photos included
//     (ArtistSimple.imageUrl), rendered with the same AurumStackedArtwork
//     circular avatar Home's own artist chips use — not a fallback
//     letter-circle.
//   • "Top Albums"     -> ApiService.searchAlbumsYtOnly(seedArtist), a
//     real InnerTube album search (YT-only, no Saavn) for the same seed
//     artist used for the artists row.
// A user with no listening history yet sees a plain empty message rather
// than any of this — there is no history to seed real recommendations
// from, so nothing here is shown as a guess.
class _SuggestionsLanding extends StatefulWidget {
  const _SuggestionsLanding();

  @override
  State<_SuggestionsLanding> createState() => _SuggestionsLandingState();
}

class _SuggestionsLandingState extends State<_SuggestionsLanding> {
  List<Song>? _songs;
  List<({String artistName, List<ArtistSimple> related})>? _artistRows;
  List<BrowseAlbum>? _albums;
  bool _failed = false;
  String? _seedVideoId;
  // Guards against the genuine double-fetch this widget can otherwise
  // trigger: initState() calls _load() once, then didChangeDependencies()
  // (which always runs right after initState on first mount) can call it
  // again once _seedVideoId is actually set — unlike Home's single-seed
  // _YouMightAlsoLikeSection (whose _load() cheaply no-ops until its one
  // seed is ready), this widget's _load() has a second independent seed
  // (rotatingAffinityArtists) that's very likely already non-empty on
  // that first initState() call, so both calls can end up doing real
  // network work. Each _load() call captures its own generation; only
  // the most recent one is allowed to commit its results.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Same "track the latest play" pattern _YouMightAlsoLikeSection uses
    // on Home — a song finishing playback doesn't remount this tab, so
    // the seed is re-checked on every dependency change instead of only
    // once in initState.
    final latest = context.watch<RecentlyPlayedProvider>().history.firstOrNull;
    final latestId = latest?.id;
    if (latestId != null && latestId != _seedVideoId) {
      _seedVideoId = latestId;
      _load();
    }
  }

  Future<void> _load() async {
    final myGeneration = ++_loadGeneration;
    final seedVideoId = _seedVideoId;
    final seedArtists = RecommendationEngine.rotatingAffinityArtists(count: 3);
    if ((seedVideoId == null || seedVideoId.isEmpty) && seedArtists.isEmpty) {
      // No listening history at all yet — nothing real to recommend from.
      if (mounted && myGeneration == _loadGeneration) setState(() => _failed = true);
      return;
    }
    try {
      final futureSongs = (seedVideoId != null && seedVideoId.isNotEmpty)
          ? ApiService.fetchYouMightAlsoLike(seedVideoId)
          : Future.value(<Song>[]);
      final futureArtistRows = Future.wait(
        seedArtists.map((a) => ApiService.fetchSimilarArtistChips(a)),
      );
      final futureAlbums = seedArtists.isNotEmpty
          ? ApiService.searchAlbumsYtOnly(seedArtists.first, limit: 8)
          : Future.value(<BrowseAlbum>[]);
      final songs = await futureSongs;
      final artistRowsRaw = await futureArtistRows;
      final albums = await futureAlbums;
      if (!mounted || myGeneration != _loadGeneration) return;
      final artistRows = artistRowsRaw.where((r) => r != null).map((r) => r!).toList();
      setState(() {
        _songs = songs;
        _artistRows = artistRows;
        _albums = albums;
        _failed = songs.isEmpty && artistRows.isEmpty && albums.isEmpty;
      });
    } catch (_) {
      if (mounted && myGeneration == _loadGeneration) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
        child: Center(
          child: Text(
            'Play a few songs and your suggestions will show up here',
            textAlign: TextAlign.center,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
          ),
        ),
      );
    }
    final songs = _songs;
    final artistRows = _artistRows;
    final albums = _albums;
    if (songs == null || artistRows == null || albums == null) {
      return const Center(child: AurumMorphLoader());
    }

    // Flatten every artist row's chips into one combined strip — this
    // tab shows a single "Unique Artists" row (not one row per seed
    // artist like Home does), so duplicates across seeds are dropped by
    // id.
    final seenArtistIds = <String>{};
    final uniqueArtists = <ArtistSimple>[];
    for (final row in artistRows) {
      for (final a in row.related) {
        if (seenArtistIds.add(a.id)) uniqueArtists.add(a);
      }
    }

    return SingleChildScrollView(
      key: const ValueKey('suggestions_landing'),
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (songs.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Unique Songs',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            ...List.generate(songs.length, (i) {
              final song = songs[i];
              return SongTile(
                key: ValueKey('unique_song_${song.id}'),
                song: song,
                queue: songs,
                index: i,
                showIndex: true,
                displayIndex: i + 1,
              );
            }),
          ],
          if (uniqueArtists.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Unique Artists',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            FadedHorizontalList(
              height: 132,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                physics: const BouncingScrollPhysics(),
                cacheExtent: 500,
                itemCount: uniqueArtists.length,
                itemBuilder: (context, i) =>
                    _SuggestionArtistChip(key: ValueKey(uniqueArtists[i].id), artist: uniqueArtists[i]),
              ),
            ),
          ],
          if (albums.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Top Albums',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                physics: const BouncingScrollPhysics(),
                cacheExtent: 500,
                itemCount: albums.length,
                itemBuilder: (context, i) => _AlbumCard(
                  key: ValueKey(albums[i].collectionId),
                  album: albums[i],
                  onTap: () {
                    AurumHaptics.light();
                    Navigator.push(
                      context,
                      AurumDepthRoute(
                        builder: (_) => AlbumScreen(
                          albumId: albums[i].collectionId,
                          albumName: albums[i].name,
                          artworkUrl: albums[i].artworkUrl,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Small standalone circular artist chip for the Suggestions tab — same
// visual language as home_screen.dart's private _ArtistChip (real photo
// via AurumStackedArtwork, name below), kept as its own tiny class here
// since _ArtistChip itself is file-private to home_screen.dart.
class _SuggestionArtistChip extends StatelessWidget {
  final ArtistSimple artist;
  const _SuggestionArtistChip({super.key, required this.artist});

  Future<void> _open(BuildContext context) async {
    AurumHaptics.selection();
    final id = artist.id.isNotEmpty ? artist.id : await ApiService.resolveArtistId(artist.name);
    if (id == null || !context.mounted) return;
    AurumDepthRoute.to(context, ArtistScreen(artistId: id, artistName: artist.name));
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AurumPressable(
        scaleAmount: 0.94,
        onTap: () => _open(context),
        child: Container(
          width: 96,
          margin: const EdgeInsets.only(right: 14),
          child: Column(
            children: [
              AurumStackedArtwork(url: artist.imageUrl, size: 90, circular: true),
              const SizedBox(height: 8),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Compact tile for the Explore landing grid — visually matches
// MoodsGenresScreen's own tile card so tapping through feels seamless.
class _ExploreMoodTile extends StatelessWidget {
  final String title;
  final Color color;
  final String? artworkUrl;
  final VoidCallback onTap;

  const _ExploreMoodTile({
    required this.title,
    required this.color,
    required this.onTap,
    this.artworkUrl,
  });

  @override
  Widget build(BuildContext context) {
    final art = artworkUrl;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (art != null && art.isNotEmpty) ...[
                const SizedBox(width: 10),
                Transform.rotate(
                  angle: 0.25,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      imageUrl: art,
                      width: 46,
                      height: 46,
                      fit: BoxFit.cover,
                      memCacheWidth: 92,
                      memCacheHeight: 92,
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


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
      duration: AurumMotion.durationOrZero(AurumMotion.short1),
      reverseDuration: AurumMotion.durationOrZero(AurumMotion.medium1),
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

class _AlbumCard extends StatelessWidget {
  final BrowseAlbum album;
  final VoidCallback onTap;
  const _AlbumCard({super.key, required this.album, required this.onTap});

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
            child: Stack(
              children: [
                AurumArtwork(url: album.artworkUrl, size: 130),
                // FIX ("kisse aata hai search pr bata na" — surface each
                // album search result's actual source): BrowseAlbum
                // already carries isFromYoutube (set true by
                // _searchAlbumsAttempt's YT leg, left false by
                // BrowseAlbum.fromSaavn's Saavn leg), so this is just
                // reading an existing field, not guessing anything.
                Positioned(
                  left: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      album.isFromYoutube ? 'YT' : 'Saavn',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
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
              border: Border.all(color: AurumTheme.accentOf(context).withOpacity(0.3), width: 1.5),
            ),
            child: ClipOval(
              child: artist.imageUrl.isEmpty
                  ? Icon(Icons.person_rounded, color: AurumTheme.accentOf(context).withOpacity(0.7), size: 28)
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
