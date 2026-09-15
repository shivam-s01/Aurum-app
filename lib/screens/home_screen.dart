import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/artist.dart' show ArtistAlbum, RelatedArtist;
import '../providers/player_provider.dart';
import '../providers/source_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../services/aurum_image_cache.dart';
import '../services/home_feed_cache.dart';
import '../services/recommendation_engine.dart';
import '../providers/download_provider.dart';
import '../services/audio_prefs.dart';
import '../services/native_engine_bridge.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_scroll_nudge.dart';
import '../widgets/aurum_stage_backdrop.dart';
import '../widgets/faded_horizontal_list.dart';
import '../widgets/song_tile.dart';
import 'album_screen.dart';
import '../main.dart' show aurumRouteObserver, aurumDebugErrorWidgetBuilder;
import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/mini_player.dart';
import '../widgets/aurum_equalizer_bars.dart';
import '../widgets/aurum_stacked_artwork.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_transitions.dart';
import 'package:shimmer/shimmer.dart';
import 'settings_screen.dart';
import 'artist_screen.dart';
import 'profile_screen.dart';
import 'library_screen.dart' show PlaylistDetailScreen;
import 'login_screen.dart';
import 'full_player_screen.dart';
import 'edge_to_edge_full_player.dart';
import 'premium_screen.dart';
import 'mix_screen.dart';
import 'moods_genres_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_motion.dart';

// ═══════════════════════════════════════════════════════════════════════
// NOTICE FOR ANY FUTURE EDITS TO THIS FILE (human or AI assistant):
//
// The "Full Player swipe-dismiss / back-button close leaves a gray/black
// layer stuck over the whole screen" bug has been diagnosed AND FIXED.
// Root cause: _FullPlayerRouteBackdrop below only removed its solid
// ColoredBox on a fixed 2-frame timer counted from when the route OPENED.
// On a fast dismiss (most reproducible on offline/local songs, which
// resolve near-instantly with no network gap), the pop's reverse
// transition could start and finish before that timer ever fired, so the
// backdrop's opaque layer kept painting for the whole ~380ms reverse
// transition instead of for one frame.
//
// The fix: _FullPlayerRouteBackdropState now also listens to the route's
// own transition Animation (`routeAnimation`, wired in from pushFullPlayer
// below) and hides itself the instant that animation status becomes
// `reverse` or `dismissed` — i.e. the moment a dismiss starts — instead of
// only ever checking a fixed post-open timer. This closes the race
// regardless of how few frames elapsed between open and dismiss.
//
// While diagnosing this, the file temporarily carried a
// `_kDebugFullPlayerWhiteLayer` flag, a `_debugFlashBanner()` helper (an
// on-screen cyan MaterialBanner), and debugPrint() calls scattered through
// the backdrop lifecycle and pushFullPlayer(). ALL of that has been
// removed — it was diagnostic scaffolding only, not part of the fix, and
// left in a release build it's dead weight that also visibly flashes a
// banner over real user content.
//
// DO NOT reintroduce that debug flag/banner/prints to "help verify" a
// related bug. If a similar full-screen gray/black overlay issue
// resurfaces:
//   1. Check _FullPlayerRouteBackdropState's `_onRouteStatusChanged` and
//      the 2-frame postFrame timer in `initState` FIRST — this is the
//      single widget capable of painting a solid color over the entire
//      route, and is the most likely site of any regression here.
//   2. Confirm `routeAnimation` is still being passed through from the
//      `pageBuilder` call site (search this file for
//      `_FullPlayerRouteBackdrop(` ) — if that wiring is ever dropped
//      (e.g. during an unrelated refactor of pushFullPlayer), the
//      dismiss-triggered hide silently stops working and only the
//      original (insufficient) 2-frame timer remains.
//   3. If new diagnostics are genuinely needed, gate them behind
//      `kDebugMode` (already imported above), never a hand-rolled
//      `const bool _kDebugXxx = true` that silently ships to release
//      builds — and remove them again once the bug is closed.
// ═══════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// Shared FullPlayerScreen navigation — every song-tap entry point on this
// screen (Recently Played tiles, genre/mood grid cards, mini player, etc.)
// pushes through this single function instead of each hand-rolling its own
// Navigator.push. Two reasons this needs to be shared and not duplicated
// per-widget:
//   1. Consistency — one transition curve/duration definition, so a future
//      tweak (like the reverseTransitionDuration fix below) automatically
//      applies everywhere instead of silently missing whichever call site
//      was copy-pasted before the tweak was made.
//   2. The double-tap guard — a StatelessWidget (like a song grid card)
//      can't hold its own `bool _openingX` field the way a State class can,
//      so without a shared module-level guard, any Stateless tap site is
//      unprotected against a fast double-tap pushing FullPlayerScreen twice
//      onto the nav stack.
// ─────────────────────────────────────────────────────────────────────────────

// One-shot backdrop for the FullPlayerScreen route — paints a solid themed
// color for exactly the first frame (closing the cold-start white-flash gap
// left by `opaque: false`), then removes itself so it can never be exposed
// again later as a stuck opaque layer if the dismiss-drag's pop is ever
// delayed or dropped. See the FIX comment at the pushFullPlayer call site
// for the full story.
class _FullPlayerRouteBackdrop extends StatefulWidget {
  final bool isDark;
  final Widget child;
  final Animation<double>? routeAnimation;
  const _FullPlayerRouteBackdrop({
    required this.isDark,
    required this.child,
    this.routeAnimation,
  });

  @override
  State<_FullPlayerRouteBackdrop> createState() =>
      _FullPlayerRouteBackdropState();
}

class _FullPlayerRouteBackdropState extends State<_FullPlayerRouteBackdrop> {
  bool _showBackdrop = true;
  Timer? _safetyTimer;

  @override
  void initState() {
    super.initState();
    // Two frames is enough for FullPlayerScreen's own Scaffold/ColoredBox
    // to have painted (the actual gap this backdrop exists to cover) —
    // scheduling the removal via addPostFrameCallback (rather than a fixed
    // delay) ties it to real paint timing instead of guessing a duration
    // that could race on a slow cold start or run needlessly long on a
    // fast one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showBackdrop = false);
      });
    });
    // BUGFIX ("full player swipe-down se band karte hi turant gray/cream
    // layer aa jaata hai" — offline/local songs, confirmed reproducible):
    // the two-frame timer above assumes at least ~2 frames elapse between
    // this route opening and FullPlayerScreen's own Scaffold painting.
    // But _completeDismissDrag()'s slide-off-then-pop can start and finish
    // well inside that same short window — especially right after an
    // offline song's near-instant resolve, which is exactly what leaves
    // the least time for those 2 frames to land before dismissal begins.
    // When that happens, `_showBackdrop` is still true (the postFrame
    // timer hasn't fired yet) while the route's own reverse transition
    // (380ms SlideTransition) plays out — so this backdrop's solid
    // ColoredBox, sitting OUTSIDE FullPlayerScreen's dismiss-drag Opacity,
    // paints solid black/cream for the whole reverse-transition duration
    // instead of just one frame. Listening to the route's own animation
    // and hiding the backdrop the instant it starts reversing (status
    // change, not a value threshold — fires on the very first tick of the
    // dismiss) closes this regardless of how few frames elapsed since
    // open; the 2-frame postFrame timer above still handles the original
    // cold-start-flash case for the forward/open direction untouched.
    widget.routeAnimation?.addStatusListener(_onRouteStatusChanged);
    // BUGFIX ("cold start pe pehla tap — full player khulta hai, turant
    // swipe down karo, ek grey/dim layer Home ke upar reh jaata hai, tap
    // nahi karta jab tak dobara nahi kholte" — production bug, confirmed
    // via screen recording): the two-frame postFrame timer above is a
    // RACE against FullPlayerScreen's own first paint, not a guarantee.
    // On a genuinely slow cold start (heavy CPU contention from artwork
    // decode / network / provider init all firing in the same window),
    // FullPlayerScreen can take longer than 2 frames to paint. If the
    // user swipes down to dismiss inside that gap, _onRouteStatusChanged
    // fires and hides THIS backdrop correctly — but FullPlayerScreen
    // itself was never actually visible yet, so hiding the backdrop just
    // exposes Home's own last frame, now sitting underneath a route that
    // is still on the stack and still mid reverse-animation. Home's
    // content is real (not blank), but the active route above it is a
    // still-live, still-hit-testing PageRouteBuilder — every tap during
    // that reverse animation is swallowed by the route, not Home, which
    // is exactly the "washed out and unresponsive until you back out"
    // symptom. A hard safety timer, independent of both the paint-timing
    // race above AND the swipe-dismiss listener, guarantees this backdrop
    // is gone within a bounded, known time no matter what else happens —
    // 900ms comfortably covers even a slow cold-start paint plus the
    // 380ms reverse transition, with no dependency on frame timing at all.
    _safetyTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && _showBackdrop) setState(() => _showBackdrop = false);
    });
  }

  void _onRouteStatusChanged(AnimationStatus status) {
    if (!mounted || !_showBackdrop) return;
    if (status == AnimationStatus.reverse ||
        status == AnimationStatus.dismissed) {
      setState(() => _showBackdrop = false);
    }
  }

  @override
  void dispose() {
    widget.routeAnimation?.removeStatusListener(_onRouteStatusChanged);
    _safetyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showBackdrop) return widget.child;
    // FIX (permanent removal of cold-start white/cream flash): this used
    // to branch on widget.isDark (itself read from ThemeProvider before
    // its async SharedPreferences load may have resolved) to choose
    // between black and the light cream 0xFFF5F0EA. On a cold start that
    // race could land on the cream branch regardless of the user's
    // actual saved theme, producing the reported white/cream flash right
    // before the full player's first real frame. FullPlayerScreen's own
    // Scaffold/ColoredBox now hardcode black for the same reason — this
    // backdrop matches that so there's no seam between the two layers.
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        widget.child,
      ],
    );
  }
}

bool _openingFullPlayer = false; // guards against double-push on rapid tap

// FIX ("online song, cold start ke baad pehli baar full player kholo — ek
// gray/cream layer fast-flash hoke chala jaata hai" — every session,
// first open only): _FullPlayerRouteBackdrop's whole purpose is covering
// the real gap that exists on a COLD start, before any artwork/theme has
// painted anywhere yet — see the FIX comments at its pageBuilder call
// site below for the full history of why it exists. But it was never
// actually gated to cold start; it ran on every single open. On the
// SECOND and later opens of a session, Home (and everything else) has
// already painted real frames — opaque:false lets those keep rendering
// live underneath the route the whole time, so there is no white/blank
// gap left for this backdrop to cover. Painting it anyway just adds a
// visible, unnecessary flash of solid color where previously there was
// nothing to flash. Tracking whether ANY full player has already opened
// this session and skipping the backdrop after the first time closes
// that gap: the cold-start fix it exists for still fires exactly once
// per app launch, and every subsequent open is flash-free.
bool _hasOpenedFullPlayerThisSession = false;

void pushFullPlayer(BuildContext context, {VoidCallback? onClosed}) {
  if (_openingFullPlayer) {
    return;
  }
  _openingFullPlayer = true;
  AurumHaptics.light();
  // STABILITY FIX ("offline/local song se Home pe jaate hi screen dead ho
  // jaati hai, bina app restart ke nahi jaata" — production bug): the
  // guard reset below used to live ONLY inside `.then((_) {...})`, which
  // fires when the pushed route is later popped. If `Navigator.of(
  // context).push(...)` itself never successfully completes that
  // round-trip — e.g. `context` gets deactivated by a widget-tree rebuild
  // that lands in the same frame (playSong()'s notifyListeners() racing
  // with this push, exactly the same "two things landing in the same
  // frame" class of race already fixed above for local/offline songs,
  // which resolve near-instantly with no network round-trip to naturally
  // separate the two), the push can throw or silently never settle. With
  // no other reset path, `_openingFullPlayer` stays `true` forever — and
  // since it's a single module-level guard shared by EVERY tap site in
  // the app (song_tile.dart, mini_player.dart, home_screen.dart itself),
  // that one stuck flag makes every future tap anywhere silently return
  // at the guard-check above and do nothing. That is exactly a dead,
  // unresponsive screen that never recovers without a full app restart.
  // Wrapping the push in try/catch and always resetting the guard — on
  // success (unchanged), on the route's own completion (unchanged), AND
  // now on any synchronous failure — closes every path that could leave
  // it stuck.
  try {
    Navigator.of(context).push(
      PageRouteBuilder(
        // FIX (background screen visibly glitches/blinks during swipe-
        // down-to-dismiss): this was `opaque: true`. Flutter's routing
        // treats an opaque route as fully covering everything behind it,
        // so it stops actively rendering/repainting the previous route
        // for the duration the opaque route is on top — it just keeps the
        // last frame around, since (by the opaque contract) nothing behind
        // it should ever be visible anyway. FullPlayerScreen's swipe-to-
        // dismiss (_DragTransform, see full_player_screen.dart) fades its
        // own Opacity down toward 0 while dragging, which — being opaque
        // — briefly exposes that frozen, non-updating previous frame
        // underneath instead of a live one. Every drag frame recomposites
        // a moving translucent player over a static background, which is
        // exactly what reads as the background "blinking"/glitching during
        // the drag. `opaque: false` tells Flutter this route may show the
        // one behind it, so that previous route keeps rendering live frames
        // the whole time — confirmed safe here since the screen-behind-
        // freeze this was originally set to prevent only ever showed up
        // while the player was fully static/open (unaffected by this
        // change), never during the drag itself.
        opaque: false,
        pageBuilder: (context, anim, ___) {
          final useEdgeToEdge = context.read<ThemeProvider>().fullPlayerStyle == 'Edge to Edge';
          final fullPlayer = useEdgeToEdge ? const EdgeToEdgeFullPlayer() : const FullPlayerScreen();
          // FIX (see _hasOpenedFullPlayerThisSession doc comment above for
          // the full story): the backdrop below exists solely to cover a
          // COLD-START gap — skip it entirely once this session has
          // already opened a full player at least once, since there is no
          // gap left to cover on a warm open and painting it anyway is
          // just an unnecessary visible flash.
          if (_hasOpenedFullPlayerThisSession) {
            return fullPlayer;
          }
          _hasOpenedFullPlayerThisSession = true;
          return _FullPlayerRouteBackdrop(
            // Lets the backdrop hide itself the instant the route starts
            // reversing (swipe-dismiss pop), instead of only on a 2-frame
            // open timer — see the BUGFIX comment in
            // _FullPlayerRouteBackdropState.initState for the full story.
            routeAnimation: anim,
            // FIX (cold-start white flash between tap and FullPlayerScreen's
            // first real frame): opaque:false (needed for the swipe-dismiss
            // background-blink fix above) means Flutter no longer guarantees
            // anything is painted under this route before FullPlayerScreen's
            // own Scaffold gets to run its build — on a cold start (no
            // artwork cached yet, Provider still spinning up), that gap
            // could be one visible frame of plain white before the themed
            // Scaffold/ColoredBox inside FullPlayerScreen ever paints. This
            // pageBuilder-level backdrop is the outermost possible layer
            // for this route — it paints instantly, before FullPlayerScreen
            // constructs, closing that gap completely regardless of how
            // long the real screen takes to build its first frame.
            //
            // FIX (cream/white flash on the FIRST full-player open of a
            // session, every time, dark theme included): this used to read
            // `Theme.of(context).brightness` directly. That ambient Theme
            // lookup can legitimately disagree with what the rest of the
            // app is actually showing for exactly one frame — the nearest
            // Theme ancestor above this route's own context isn't guaranteed
            // to have finished rebuilding with this frame's resolved
            // isDark yet (e.g. right after cold start, before
            // DynamicColorBuilder/Consumer2 in main.dart has completed its
            // first pass). Theme.of(context).brightness silently defaults
            // toward light when it can't resolve cleanly, which is exactly
            // why the flash color reported is always the light cream
            // (0xFFF5F0EA) and never black, and why it's specifically a
            // first-open-only glitch. Reading ThemeProvider.isDarkOf(context)
            // instead asks the SAME already-resolved boolean main.dart used
            // to pick the active theme in the first place — there is no
            // second, independently-timed brightness lookup left to
            // disagree with it.
            //
            // FIX ("offline song bajao, full player kholo, swipe down se
            // band karo — upar se white/gray layer aa jaata hai jo phir
            // atak jaata hai, tap kaam nahi karta" — production bug): this
            // used to be a plain ColoredBox wrapping FullPlayerScreen as its
            // child — i.e. a SOLID, OPAQUE layer painted underneath
            // FullPlayerScreen for the entire lifetime of the route, not
            // just the first frame the comment above describes. That's
            // invisible in the normal case because FullPlayerScreen's own
            // Scaffold is opaque and fully covers it. But FullPlayerScreen's
            // swipe-to-dismiss (_DragTransform) fades ITS OWN Opacity toward
            // 0 while dragging/completing a dismiss — this backdrop sits
            // OUTSIDE that Opacity, so it never fades with it. If the
            // dismiss drag's pop is ever delayed or dropped (same class of
            // same-frame-race already identified for local/offline taps
            // elsewhere in this file — a local song's near-instant resolve
            // leaves no network round-trip to naturally separate two events
            // landing in the same frame), what's left on screen is this
            // solid black/cream layer with nothing on top of it: exactly
            // the reported "white/gray layer" — and since the route is
            // still technically on the stack, it keeps intercepting every
            // touch until something else coincidentally pops it, which is
            // exactly the reported stuck/unresponsive feel.
            // Fix: this backdrop now only needs to survive ONE frame (the
            // gap before FullPlayerScreen's own Scaffold paints its first
            // frame) — self-removing it a moment after first paint means
            // even a delayed/dropped pop can never expose a persistent
            // opaque layer again, closing the gap at its root instead of
            // patching the guard that merely re-enabled future taps.
            isDark: context.read<ThemeProvider>().isDarkOf(context),
            child: fullPlayer,
          );
        },
        // NOTE (supersedes the "flat theme-colored screen for 1-2s" fix
        // that previously removed the ColoredBox wrapper entirely): that
        // fix was correct for the steady-state slide — a themed color
        // painted for the *whole* 380ms transition duration does read as
        // "stuck on a flat color" versus real artwork/content. The
        // ColoredBox reintroduced above is different in kind, not a
        // regression of that fix: it only needs to win a single first
        // frame on a cold start (see the FIX comment above), and
        // FullPlayerScreen's own themed Scaffold/inner ColoredBox paint
        // over it immediately after — so the "flat color for the whole
        // transition" complaint this comment describes does not return.
        transitionsBuilder: (context, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: AurumMotion.standard)),
          child: child,
        ),
        // Explicit 380ms both directions — matches the tuned duration
        // every entry point (mini player, search, library, song tile)
        // already agreed on before being consolidated into this shared
        // helper. Without this, PageRouteBuilder's default (300ms) would
        // apply instead, a subtle but real feel-mismatch versus what was
        // tuned and shipped before.
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 380),
      ),
    ).then((_) {
      _openingFullPlayer = false;
      onClosed?.call();
    }, onError: (e) {
      _openingFullPlayer = false;
    });
  } catch (e) {
    // Synchronous failure (e.g. context already unmounted at call time) —
    // the .then()/onError above never got attached, so reset here too.
    _openingFullPlayer = false;
  }
  // FIX ("local song play karo, ek white/confirm jaisa cheez atak jaati
  // hai, kuch bhi tap karne pe kuch nahi hota, restart ke bina nahi
  // jaata" — production bug): every reset path above (.then, onError,
  // catch) assumes the pushed route's Future eventually settles OR that
  // the push throws synchronously. There's a third gap neither covers —
  // Android can pause/kill the Activity in the narrow window between
  // Navigator.push() returning a Future and this function reaching the
  // line that chains .then()/.onError onto it (a real, if rare, window
  // since local/offline song taps resolve near-instantly with nothing to
  // naturally separate two same-frame events, same root cause already
  // identified for the swipe-back stuck-controller bug above). If that
  // happens, the Future genuinely never resolves and _openingFullPlayer
  // stays true forever — which, since it's the ONE guard shared by every
  // tap site in the entire app, makes every future song tap anywhere
  // silently no-op. That is precisely a screen that looks stuck behind a
  // stray overlay and never recovers without a force-restart. A blunt
  // but bulletproof backstop: whatever happens to the route itself, force
  // the guard open again shortly after the transition should have long
  // finished, so a dropped Future can never wedge every future tap.
  Future.delayed(const Duration(milliseconds: 1500), () {
    _openingFullPlayer = false;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  // PERF FIX (heat while on another tab): MainShell keeps all 3 tabs alive
  // simultaneously via IndexedStack (see main_shell.dart) — it only hides
  // the inactive ones, it doesn't unmount them. Without a visibility
  // signal, Home's ambient "breathe" glow animation (_breatheCtrl, gated
  // only on isPlaying/appInForeground) kept running at 60fps even while
  // the user was sitting on Search/Library with Home completely
  // off-screen — pure wasted GPU/CPU work with zero visible effect,
  // showing up as unnecessary device heat during normal use. Mirrors
  // SearchScreen's existing `isActive` param/pattern exactly.
  final bool isActive;
  const HomeScreen({super.key, this.isActive = true});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}


// Note: previously cached query→artwork permanently across the whole app
// session (_kPlaylistArtCache). Removed so art genuinely refreshes each
// pull-to-refresh along with the songs — a stale thumbnail next to a fresh
// random tracklist looked broken/cheap, not premium.

// ══════════════════════════════════════════════════════════════════
// NOTE: the previous hand-rolled `_HeroPullToRefresh` + `_RingPainter`
// (custom NotificationListener-based pull gesture) has been removed.
// ROOT CAUSE of "refresh hota hi nahi": that custom gesture detector sat
// directly above `_HeroNowPlaying`, which has its own horizontal-drag
// GestureDetector for song swipe. Flutter's gesture arbitration between
// the two competed for the same touch sequence, and a plain vertical
// pull starting at the very top of the list (pixels == 0, right where
// SliverAppBar's floating/snap behavior also has its own claim on the
// first bit of scroll delta) frequently lost that arbitration silently
// — no ring, no refresh, no error.
//
// Fixed by switching to Flutter's own `RefreshIndicator` (wired directly
// in HomeScreen.build() below), which owns gesture arbitration correctly
// against sibling GestureDetectors out of the box. Styled with the app's
// gold accent so it still matches the rest of Astra instead of looking
// like a stock Material widget.

class _HomeScreenState extends State<HomeScreen> {
  bool _onlineLoading = true;
  String? _onlineError;
  // Bumped on every pull-to-refresh so the "Playlists for You" cards (which
  // cache their own art/songs in initState) get fresh widget identities and
  // refetch a brand-new random Saavn-first set instead of showing stale data.
  int _playlistRefreshKey = 0;
  // STAGED REFRESH ("10 baar refresh kre tab jaake poora fresh content
  // aaye, MB/heating kam ho, aur dhire dhire har refresh mein thoda thoda
  // naya content aaye" — 2026-09-15): bumped on EVERY pull-to-refresh.
  // _QuickPicksSection listens to this directly. _HomeShelvesAndSimilarSection
  // also listens to it (as its own refreshKey) but gates its three
  // internal fetches (shelves / similar-artist rows / similar-song rows)
  // behind the RefreshStage computed alongside this bump — see
  // _onPullToRefresh. Replaces the old binary _playlistRefreshKey (only
  // bumped 1-in-10) — that split meant _HomeShelvesAndSimilarSection sat
  // completely frozen for 9 pulls, then fetched everything at once on the
  // 10th, which is exactly the all-at-once network/MB/heat spike this
  // feature exists to remove, just moved to a single pull instead of
  // spread out.
  int _quickPicksRefreshKey = 0;
  // Current position (1-10) in the staged-refresh cycle — read by
  // _HomeShelvesAndSimilarSection to decide which of its three sections
  // are due a real fetch on this particular pull. See RefreshStage's doc
  // comment in home_feed_cache.dart for the exact 1-10 ramp.
  RefreshStage _refreshStage = const RefreshStage(
    quickPicks: true,
    shelves: false,
    similarArtistRows: false,
    similarSongRows: false,
  );

  List<ArtistSimple> _homeArtists = [];
  bool _artistsLoading = true;
  // Scopes the cache-shrink-flash guard in _loadArtists() to only the
  // FIRST streaming callback per load — see that guard's doc comment.

  bool _isFirstArtistUpdate = true;

  final ScrollController _scrollCtrl = ScrollController();
  // Echo Nightly-style scroll-linked nudge — one shared delta feed for
  // every card on the page (see aurum_scroll_nudge.dart for why this is
  // a single listener, not one per tile).
  final AurumScrollDelta _scrollDelta = AurumScrollDelta();

  // PERF FIX (40s "katarnak lag" on every cold start): _onlineSections used
  // to live as plain State fields, updated via setState() on _HomeScreenState
  // itself — see _loadOnline()'s onSection callback below. Every one of the
  // ~15-19 sections streaming in on a cold start therefore triggered a
  // setState() at the very ROOT of this screen, which meant Flutter rebuilt
  // and re-diffed the ENTIRE Home tree each time: the AppBar, the
  // AnimatedSwitcher, _YtPlaylistsForYouSection, _HomePremiumBanner,
  // _OnlineContent (all shelves), AND _ArtistStrip — none of which have
  // anything to do with a single song section arriving. Even with
  // _StaggeredSection's per-section ValueKey limiting the cost of diffing
  // each individual shelf, that top-level rebuild-and-diff pass still ran
  // 15-19 times back-to-back in the first few seconds of every cold start —
  // exactly the sustained jank window described ("laggy until new titles
  // stop arriving").
  //
  // Fix: move the streamed section list into its own ValueNotifier, and
  // wrap ONLY _OnlineContent in a ValueListenableBuilder further down in
  // build(). Every onSection arrival now rebuilds just that one subtree —
  // the curated playlists row, premium banner, and artist strip never
  // rebuild again after their own one-time load, no matter how many song
  // sections stream in afterward.
  final ValueNotifier<List<SongSection>> _onlineSectionsNotifier =
      ValueNotifier<List<SongSection>>([]);
  List<SongSection> get _onlineSections => _onlineSectionsNotifier.value;
  set _onlineSections(List<SongSection> v) => _onlineSectionsNotifier.value = v;

  @override
  void initState() {
    super.initState();
    _scrollDelta.attach(_scrollCtrl);
    // FIX (cold-start instant load, Spotify-style): render whatever was
    // cached from the last successful load FIRST, synchronously into
    // initial state where possible, so the very first frame already shows
    // real content instead of shimmer — then kick off the real network
    // fetch in the background exactly as before. _hydrateFromCache reads
    // SharedPreferences (fast, no network) and silently no-ops if this is
    // a genuine first-ever launch with nothing cached yet, in which case
    // behavior is identical to before this fix.
    _hydrateFromCache();
    // BACKGROUND REFRESH GATE: HomeFeedCache.isFresh()/isArtistsFresh()
    // are time-gated (6-hour window — see home_feed_cache.dart's
    // _maxFreshAge doc comment) — a real background fetch fires here on
    // cold start whenever there's no cache yet OR the existing cache has
    // aged past that window, so the feed periodically refreshes with
    // genuinely new listening-based recommendations without needing a
    // network fetch on every single app open.
    // REMOVED (2026-09-06, "1 bhe na aaye kabhi bhe" — old song-shelf
    // sections must never reappear, not even transiently): this used to
    // call _loadOnline() here on every cold start once the cache aged
    // past 6 hours. _loadOnline is now never called from anywhere in this
    // file (see _hydrateFromCache and the pull-to-refresh handler below,
    // both also cut) — the entire fetchHomeStreaming/_onlineSections
    // pipeline is fully dead, not just unrendered, so there is no path
    // left that can populate or display it again.
    // Artist strip follows the exact same freshness rule as the section
    // feed above — its own separate 6-hour-gated timestamp.
    HomeFeedCache.isArtistsFresh().then((fresh) {
      if (!mounted) return;
      if (!fresh) _loadArtists();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lib = context.read<LibraryProvider>();
      if (!lib.hasLoaded) lib.load();

      // Surface real playback failures immediately via SnackBar — no
      // logcat/adb needed to see exactly why a tap didn't start sound.
      // See player_provider.dart's onPlaybackError (wired from
      // NativeAudioEngine.errorStream) for where these messages come from.
      final player = context.read<PlayerProvider>();
      player.onPlaybackError = (error, {silent = false}) {
        debugPrint('[Aurum] Playback error${silent ? " (silent, auto-recovered)" : ""}: $error');
        if (!mounted || silent) return;
        // Only reaches here when every automatic retry/skip attempt has
        // been exhausted — a single flaky song no longer triggers this.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AurumTheme.bgCardOf(context),
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: Text(
              error,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 13,
              ),
            ),
          ),
        );
      };

      _maybeShowAutoSleepGuardResumePrompt(player);
    });
  }

  // Auto Sleep Guard "smart resume" — checked once per app open (not
  // polled), immediately consumed after checking so it never reappears on
  // a later open for the same auto-pause event. See AutoSleepGuard.kt's
  // peekLastAutoPause/consumeLastAutoPause for the native side.
  Future<void> _maybeShowAutoSleepGuardResumePrompt(PlayerProvider player) async {
    final engine = NativeAudioEngine();
    final lastPauseMs = await engine.autoSleepGuardPeekLastAutoPause();
    if (lastPauseMs == null || !mounted) return;
    await engine.autoSleepGuardConsumeLastAutoPause();
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final pausedAt = DateTime.fromMillisecondsSinceEpoch(lastPauseMs);
    final timeLabel = TimeOfDay.fromDateTime(pausedAt).format(context);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AurumTheme.bgCardOf(context),
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          l10n.asgResumePromptSubtitle(timeLabel),
          style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13),
        ),
        action: SnackBarAction(
          label: l10n.asgResumePromptResume,
          textColor: AurumTheme.accentOf(context),
          onPressed: () => player.togglePlay(),
        ),
      ),
    );
  }

  Future<void> _hydrateFromCache() async {
    // REMOVED (2026-09-06, "cache mai dekh lena, 1 bhe na aaye"): this used
    // to also load cachedSections / the bundled home_snapshot.json asset
    // and push them into _onlineSections for an instant first paint. Both
    // of those are old-pipeline song shelves (same Trending
    // Now/Afternoon Picks/etc. family) — loading them here would have let
    // the just-removed section list flash back onto Home from disk cache
    // or from the bundled snapshot on a fresh install, even with the
    // render/fetch call sites cut elsewhere. Only the artist cache (which
    // still legitimately renders via _ArtistStrip) is hydrated now.
    final cachedArtists = await HomeFeedCache.loadArtists();
    if (!mounted) return;
    if (_homeArtists.isEmpty && cachedArtists.isNotEmpty) {
      setState(() {
        _homeArtists = cachedArtists;
        _artistsLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _scrollDelta.dispose();
    _scrollCtrl.dispose();
    _onlineSectionsNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadArtists() async {
    // Reset per-load so a pull-to-refresh (this function is also called
    // from the pull-to-refresh handler below) gets its own fresh
    // "first update" window instead of inheriting the previous load's
    // already-flipped-false flag, which would silently disable the
    // cache-shrink-flash guard on every load after the very first one.
    _isFirstArtistUpdate = true;
    try {
      // SPEED FIX ("artist home page pe nahi/late aa rahe"): switched from
      // the old blocking fetchHomeArtistsCombined() (waited on a slow
      // 20-artist Saavn batch before showing anything) to the streaming
      // version — paints the fast YT leg the moment it resolves, then
      // silently tops up with the slower Saavn pool once that finishes.
      // See fetchHomeArtistsStreaming's doc comment in api_service.dart.
      await ApiService.fetchHomeArtistsStreaming((artists) {
        if (!mounted) return;
        // REGRESSION FIX ("cache se pehle se acchi list thi, phir chhoti
        // list aa ke usse replace kar deti thi"): fetchHomeArtistsStreaming
        // calls this twice — once with just the fast YT leg, once more
        // with YT+Saavn merged. If _hydrateFromCache() already populated a
        // fuller list from last session's cache before this first (smaller)
        // YT-only snapshot lands, blindly overwriting _homeArtists here
        // would visibly SHRINK the strip for a moment — exactly the kind
        // of jarring, "something broke" flicker this whole fix was meant
        // to remove.
        //
        // FIX (own bug caught on recheck): the guard below used to be a
        // blanket "only apply if length grew or tied", which could also
        // silently swallow the SECOND, more complete streaming update if
        // its deduped count happened to land lower than the cached
        // snapshot — that update is always the authoritative, freshest
        // one and must never be dropped, or the cache itself would also
        // stop refreshing (saveArtists never runs). _isFirstUpdate scopes
        // the length guard to ONLY the first (YT-only) callback, where the
        // flash risk actually exists; the second callback always applies.
        if (_isFirstArtistUpdate && artists.length < _homeArtists.length) {
          _isFirstArtistUpdate = false;
          return;
        }
        _isFirstArtistUpdate = false;
        setState(() { _homeArtists = artists; _artistsLoading = false; });
        // Cache the latest snapshot for next cold start (see
        // home_feed_cache.dart) — fire-and-forget, called on every update
        // so the cache always reflects the fullest list this session saw.
        unawaited(HomeFeedCache.saveArtists(artists));
      });
      // DEBUG VISIBILITY (kDebugMode-gated): reports the final artist
      // count once the whole fetch completes, so an empty "Popular
      // Artists" row can be diagnosed during development. Previously this
      // fired unconditionally — every single Home load/refresh popped a
      // SnackBar with raw debug text in front of real users, which is
      // exactly the kind of "akward"/dev-leak moment production code must
      // never show. Gated behind kDebugMode so it only ever appears in a
      // debug build, never in what a real user sees.
      if (kDebugMode && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text('Artist fetch: ${_homeArtists.length} artists — ${ApiService.lastArtistFetchDebug}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _artistsLoading = false);
      // DEBUG VISIBILITY (kDebugMode-gated): shows the actual exception
      // on-screen during development instead of silently swallowing it.
      // Previously unconditional — a real fetch failure (network blip,
      // malformed response, anything) would surface a raw exception
      // string (e.g. "RangeError (length): ...") directly in a SnackBar
      // in front of real users — the exact class of dev-leak crash text
      // this whole redesign pass has been removing elsewhere (see the
      // _ErrorBoundary/_SafeListenAgainCard fix above). A genuine failure
      // now just leaves the Popular Artists row empty (its own
      // `artists.isEmpty ? SizedBox.shrink()` in _ArtistStrip already
      // handles that silently) instead of announcing itself.
      if (kDebugMode && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text('Artist load error: $e'),
          ),
        );
      }
    }
  }

  // Throttled pull-to-refresh entry point — see RefreshStage's doc
  // comment (home_feed_cache.dart) for the full 1-10 staged ramp this
  // drives. Only ever called from the RefreshIndicator (isOnline branch),
  // never from initState/cold start.
  Future<void> _onPullToRefresh() async {
    final position = await HomeFeedCache.bumpPullRefreshAndGetPosition();
    if (!mounted) return;
    final stage = RefreshStage.forPosition(position);
    // Flags set BEFORE the key bump below so both sections' didUpdateWidget
    // (fired by this same setState) read the correct stage for THIS pull.
    setState(() {
      _refreshStage = stage;
      _quickPicksRefreshKey++;
      // _playlistRefreshKey now bumps on every pull too (not just the old
      // 1-in-10 "full" pull) — _HomeShelvesAndSimilarSection itself reads
      // _refreshStage to decide which of its three internal fetches
      // (shelves / similar-artist rows / similar-song rows) are actually
      // due on this particular pull, so bumping this key every time just
      // gives it the didUpdateWidget signal to re-check the stage; it does
      // NOT mean every pull re-fetches everything.
      _playlistRefreshKey++;
    });
    // _loadArtists() dropped from here — _homeArtists' only render site
    // (the standalone "Popular Artists" strip) was already removed
    // (2026-09-14, see the removal comment further down this file), so
    // refreshing it on every pull was pure wasted network/MB for data
    // nothing on screen displays anymore.
  }

  // ignore: unused_element
  Future<void> _loadOnline({bool clearExisting = true}) async {
    setState(() {
      // FIX (shimmer flash-over-cache race): this used to unconditionally
      // force _onlineLoading = true here, every single call — including
      // the very first cold-start call, fired on the line right after
      // _hydrateFromCache() in initState. Neither call is awaited, so
      // _loadOnline()'s synchronous setState here could easily land
      // before _hydrateFromCache()'s SharedPreferences read resolved and
      // set _onlineLoading = false — forcing shimmer to flash in for a
      // frame (or more) either before the cached content ever painted, or
      // briefly on top of it right after. On a fast device this could be
      // a single dropped frame; on a slower one, a visible flicker — the
      // "looks like a bug" moment. _OnlineContent already source-of-truths
      // "loading" purely off whether _onlineSections is empty (see its
      // `if (loading) return _buildShimmer` check) — so _onlineLoading
      // only needs to be true when there's genuinely nothing to show yet.
      // Sections already on screen (from cache, or a previous load) mean
      // real content stays visible the whole time this fetch runs; only a
      // truly empty start (first-ever launch, or an explicit
      // clearExisting: true refresh) shows shimmer.
      final willBeEmpty = clearExisting || _onlineSections.isEmpty;
      _onlineLoading = willBeEmpty;
      _onlineError = null;
      _playlistRefreshKey++;
      // _onlineSections itself is set just below via the ValueNotifier
      // (not here) when clearExisting — see PERF FIX above.
      // FIX (cold-start cache, see home_feed_cache.dart / _hydrateFromCache):
      // this used to unconditionally wipe _onlineSections to [] on every
      // call, including the very first call fired right after
      // _hydrateFromCache() had just populated the screen with last
      // session's cached content. That meant the cache's whole benefit —
      // real content on the very first frame — was immediately undone a
      // moment later, flashing back to an empty/shimmer state until the
      // fresh network batch streamed back in, which is exactly the
      // loading flash this feature exists to eliminate. Cold start now
      // passes clearExisting: false so the cached sections stay on screen
      // (and get progressively replaced one-by-one as real sections arrive
      // via onSection below) instead of being cleared out first. Explicit
      // pull-to-refresh still passes the default true — clearing before a
      // user-initiated refresh remains the right call there, since that's
      // a deliberate "give me a new batch" action, not a passive cold
      // start where stale-but-real content is strictly better than blank.
    });
    // PERF FIX: moved outside the setState above — this is a section-list
    // write, which now goes through the ValueNotifier (see its doc comment)
    // instead of triggering a full HomeScreen rebuild.
    if (clearExisting) _onlineSections = [];
    // SCOPE FIX (2026-08-31 build error: "Undefined name 'liveSections'" /
    // 'flushTimer' inside the on TimeoutException / catch blocks below):
    // these used to be declared with `final`/`Timer?` INSIDE the try block,
    // which in Dart scopes them to that try block's own {} only — they were
    // never visible from separate catch/on-clauses at all. Declaring them
    // here, before try, gives them function-level scope so the fetch logic
    // in try, the timeout handling in `on TimeoutException`, and the
    // generic `catch (e)` below can all see and use the same buffer/timer.
    final liveSections = clearExisting ? <SongSection>[] : List<SongSection>.from(_onlineSections);
    Timer? flushTimer;
    try {
      final recentlyPlayedProvider = context.read<RecentlyPlayedProvider>();
      final topArtists  = recentlyPlayedProvider.topArtists(count: 3);
      // Fresh random seed every pull so, when learned affinity data is too
      // sparse for RecommendationEngine's own rotation, this fallback list
      // of "Made for You" artists still changes from refresh to refresh
      // instead of always featuring the exact same top-3-by-play-count.
      final topArtistsRotating = recentlyPlayedProvider.rotatingTopArtists(
        count: 3,
        seed: math.Random().nextInt(1000000),
      );
      final recentSongs = recentlyPlayedProvider.history.take(10).toList();
      // liveSections (declared above, before try, for catch-block scope —
      // see SCOPE FIX comment) is the local buffer sections stream into.
      // PROGRESSIVE REVEAL (2026-08-31, replaces the 2026-08-30 one-shot
      // reveal): the one-shot approach fixed the choppy "refresh 5-10 baar
      // mein hota hai" feel, but on a slow connection it meant NOTHING
      // painted for up to 25s (see the timeout branch below) — the exact
      // opposite of how Spotify/YT Music feel instant (cache-first paint +
      // sections filling in live). This restores progressive updates but
      // coalesces them on a fixed timer instead of firing one update per
      // section — the earlier choppiness came from updating on every
      // single section arrival (a burst of 3-5 in quick succession each
      // triggering its own rebuild), not from progressive reveal itself.
      // A ~400ms flush interval reads as smooth/continuous rather than
      // stepwise, while still showing real content within well under a
      // second on a fast connection instead of only at the very end.
      // (flushTimer declared above, before try — see SCOPE FIX comment.)
      void flushLiveSections() {
        if (!mounted) return;
        setState(() {
          _onlineSections = List<SongSection>.from(liveSections);
          _onlineLoading = false;
        });
      }

      await ApiService.fetchHomeStreaming(
        topArtists: topArtists,
        topArtistsRotating: topArtistsRotating,
        recentlyPlayed: recentSongs,
        // True cold start only: brand-new install, no cache, no sections
        // from a previous load either — see fetchHomeStreaming's doc
        // comment for why this path exists. A returning user (cache
        // already painted something in liveSections) doesn't need it.
        fastFirstSection: liveSections.isEmpty,
        onSection: (section) {
          final existingIdx = liveSections.indexWhere((s) => s.id == section.id);
          if (existingIdx != -1) {
            liveSections[existingIdx] = section;
          } else {
            liveSections.add(section);
          }
          // Coalesce: (re)start a short timer rather than flushing
          // immediately, so a burst of sections arriving within the same
          // ~400ms window paints together as one smooth update instead of
          // one rebuild per section.
          flushTimer?.cancel();
          flushTimer = Timer(const Duration(milliseconds: 400), flushLiveSections);
        },
      ).timeout(const Duration(seconds: 25));
      flushTimer?.cancel();
      if (mounted) {
        // Final flush: guarantees the very last section(s) that arrived
        // inside the last debounce window (and hadn't fired their timer
        // yet) are shown, and turns the loader off for good.
        setState(() {
          _onlineSections = List<SongSection>.from(liveSections);
          _onlineLoading = false;
        });
      }
      // Cache the finished batch for next cold start (see
      // home_feed_cache.dart) — only once the full streamed batch has
      // actually finished, so a partial/interrupted load never overwrites
      // a previously-complete good cache with a thinner one.
      unawaited(HomeFeedCache.saveSections(liveSections));
    } on TimeoutException {
      // SLOW-NETWORK FIX (2026-08-31): with progressive reveal above,
      // sections that arrived before the 25s budget expired are already
      // on screen (flushed live via the debounce timer) — this branch now
      // mainly guards the case where flushTimer's last debounce window
      // hadn't fired yet, and turns off the loader/clears any stale error
      // so a timeout after partial success doesn't flash "Failed to load"
      // over real content that's already visible.
      flushTimer?.cancel();
      if (mounted) {
        setState(() {
          _onlineLoading = false;
          if (liveSections.isNotEmpty) {
            _onlineSections = List<SongSection>.from(liveSections);
            _onlineError = null;
          } else {
            _onlineError = AppLocalizations.of(context)!.homeFailedToLoad;
          }
        });
      }
      if (liveSections.isNotEmpty) {
        unawaited(HomeFeedCache.saveSections(liveSections));
      }
    } catch (e) {
      flushTimer?.cancel();
      if (mounted) {
        // FIX (2026-07-25): this used to blame "check your internet
        // connection" for EVERY failure of the batch above — including a
        // 25s timeout caused by our own ~19-section fan-out, a transient
        // backend hiccup, or any other exception. On a perfectly good
        // connection that reads as flatly wrong to the user (which is
        // exactly what was being reported) since nothing here actually
        // confirmed the device was offline. Doing one real connectivity
        // check here means the "check your internet connection" wording
        // only ever shows when the device is genuinely offline/has no
        // usable network; every other failure (slow backend, timeout,
        // one-off error) gets a neutral, accurate "couldn't load, try
        // again" message instead — same distinction Spotify/Netflix make
        // between "you're offline" and "something went wrong on our end".
        final connectivity = await Connectivity().checkConnectivity();
        if (!mounted) return;
        final isOffline = connectivity.every((r) => r == ConnectivityResult.none);
        setState(() {
          _onlineLoading = false;
          if (_onlineSections.isEmpty) {
            _onlineError = isOffline
                ? AppLocalizations.of(context)!.homeFailedToLoadCheckConnection
                : AppLocalizations.of(context)!.homeFailedToLoad;
          }
        });
      }
      // RELIABILITY (premium/"never stuck" requirement): if cached content
      // is currently covering the screen (cold start showed it, then this
      // fetch failed — a transient network blip, DNS hiccup, whatever),
      // the user has no visible error (by design — the cache is doing its
      // job) but ALSO has no path back to genuinely fresh data until they
      // manually pull-to-refresh, which most people never think to do.
      // Silently retry once after a short delay so a passing connectivity
      // issue self-heals without the user ever needing to notice or act —
      // if this retry also fails, we simply stop (no error shown either
      // way since cached content is already on screen) rather than
      // retrying indefinitely and hammering a genuinely-down backend.
      if (!_onlineRetriedAfterFailure && _onlineSections.isNotEmpty && mounted) {
        _onlineRetriedAfterFailure = true;
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) _loadOnline(clearExisting: false);
        });
      }
    }
  }

  // Guards the silent auto-retry above to exactly one attempt per
  // HomeScreen lifetime — prevents a persistently-down backend from being
  // hammered every few seconds for as long as the user stays on this screen.
  bool _onlineRetriedAfterFailure = false;

  @override
  Widget build(BuildContext context) {
    final src = context.watch<SourceProvider>();
    final isOnline = src.isOnline;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: Stack(
        children: [
          // ── Top stage backdrop: Echo Nightly-style baked blur + grain.
          // Replaces the old flat palette-color glow. ──
          const AurumStageBackdrop(),

          // ── Main scroll content ──
          // Reverted to Flutter's stock RefreshIndicator — the custom
          // AurumMorphLoader-based pull-to-refresh wasn't working
          // reliably, so this goes back to the simple, previously-working
          // native indicator. Styled gold/dark to still match Astra.
          RefreshIndicator(
            color: AurumTheme.accentOf(context),
            backgroundColor: AurumTheme.bgCardOf(context),
            strokeWidth: 2.6,
            displacement: 48,
            // STAGED REFRESH ("10 baar refresh kre tab jaake poora fresh
            // content aaye, MB/heating kam ho, dhire dhire har refresh
            // mein thoda thoda naya content aaye" — 2026-09-15): every
            // pull no longer unconditionally re-fetches shelves + similar
            // rows together. HomeFeedCache.bumpPullRefreshAndGetPosition()
            // persists a 1-10 cycle position; RefreshStage.forPosition
            // maps that to which of shelves/similar-artist-rows/similar-
            // song-rows are due THIS pull. Quick Picks reshuffles on every
            // pull (cheapest, zero-network); shelves join in from pull 4,
            // similar-artist rows from pull 7, similar-song rows from
            // pull 10 — cumulative, so pull 10 is the union of everything
            // warmed up over the cycle rather than a cold all-at-once
            // spike. See RefreshStage's doc comment for the full ramp.
            onRefresh: () => isOnline ? _onPullToRefresh() : context.read<LibraryProvider>().refresh(),
            child: AurumScrollDeltaScope(
              notifier: _scrollDelta.notifier,
              child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              // PERF FIX (scroll jank/stutter, "atke atke feel"): default
              // Sliver cacheExtent is only 250 logical px. With ~12 heavy
              // shelves (each a horizontal ListView of up to 12 cards,
              // each card a network image) stacked in one SliverList, a
              // fast fling scroll routinely outran that tiny window —
              // every section that briefly left the 250px buffer got torn
              // down (dispose + image eviction), then rebuilt from scratch
              // the instant it re-entered, on every single fling. That
              // build/dispose/rebuild churn racing the frame budget is
              // exactly what reads as "makkhan nahi, atka hua" scrolling.
              // Widening to ~1.5 screen heights keeps 1-2 shelves above
              // and below the viewport permanently warm (already built,
              // already decoded) so a normal fling never has to pay that
              // cost — RepaintBoundary on every card (_SongGridCard) plus
              // the per-row memCacheWidth cap already keep the actual
              // paint/decode cost of the wider window cheap.
              cacheExtent: 1200,
              slivers: [
                _buildAppBar(context, src),
                // REMOVED ("vo hero hata do complete vo sahi nhi lg raha
                // hai") — the _HeroNowPlaying floating glass card used to
                // render here, directly under the app bar. Widget class
                // left defined below (dead code) rather than deleted, in
                // case a different treatment is wanted later; it is no
                // longer mounted anywhere on Home.
                if (!isOnline)
                  const SliverToBoxAdapter(child: _OfflineContent(key: ValueKey('offline')))
                else ...[
                  // ── Real InnerTube home shelves, one titled carousel
                  // per shelf ("New releases", "India's biggest hits",
                  // etc.) — the actual YT Music multi-shelf layout,
                  // straight from fetchRealHomeShelves() (FEmusic_home,
                  // same data _YtPlaylistsForYouSection used to flatten
                  // into one generic "Playlists For You" row — this
                  // renders it under its real per-shelf titles instead).
                  // REMOVED ("purana sb hata do, ekdam fresh InnerTube",
                  // 2026-09-06): _YtPlaylistsForYouSection (mood chips +
                  // flattened/shuffled single row) is no longer mounted
                  // here — this section is now the only real-shelf UI on
                  // Home. Class left defined below (dead code, along with
                  // _YtAlbumsForYouSection/_ThemedPlaylistShelvesSection
                  // already removed earlier) rather than deleted outright,
                  // in case any part of it is wanted again later. ──
                  // REMOVED ("mood and genres ekdam upar hi aa gya hai ye
                  // akward hai" — 2026-09-07): _MoodsGenresEntryCard used
                  // to render here, before any real shelf, which put it
                  // as literally the first thing under Hero on Home —
                  // nowhere in the reference screenshots does a standalone
                  // Moods & Genres entry appear that high (or at all, as
                  // its own row). The real InnerTube Moods & Genres screen
                  // is still one tap away via "Featured playlists for
                  // you"'s own arrow (_RealHomeShelfRow._openArrow below)
                  // — same destination, just no second/earlier door to it
                  // competing for the top of Home. Class left defined
                  // below (dead code) rather than deleted, in case it's
                  // wanted back as e.g. a Library tab entry later.
                  // REORDER ("artist ekdam niche nhi aayenge na akward lg
                  // raha tha" — 2026-09-07): Popular Artists + all
                  // "Similar to X" rows used to be pushed to the very
                  // bottom, after every shelf — nothing in the reference
                  // screenshots clumps every artist row together at the
                  // end like that. Reference shows the artist strip near
                  // the TOP (its own "Keep listening" screenshot has it
                  // right under Hero) and "Similar to X" rows genuinely
                  // interleaved between shelves, not stacked after all of
                  // them. _ArtistStrip now renders first, then
                  // _HomeShelvesAndSimilarSection below interleaves real
                  // shelves with similar-artist rows itself instead of
                  // two separate back-to-back sliver children.
                  // REDESIGN ("ekdam youtube music jaisa structure
                  // redesign kro" — 2026-09-13): mood chip row restored
                  // as the very first thing under the app bar, matching
                  // the real reference screenshots exactly — but now
                  // backed by _RealMoodChipsSection's 100% genuine
                  // fetchMoodsAndGenres()/fetchMoodGenreCategory() data
                  // instead of the old fake-fallback pipeline (see that
                  // section's own doc comment for why the previous
                  // version was removed and what's different this time).
                  // REMOVED ("category wale option hata do — All/Chill/
                  // Commute/Energize/Feel good" — 2026-09-13): the top
                  // mood/category chip row is gone entirely per request.
                  // PREVIOUS ATTEMPT AT THIS REMOVAL LEFT THE COMMENT ABOVE
                  // BUT NEVER ACTUALLY DELETED THE SliverToBoxAdapter BELOW
                  // IT — _RealMoodChipsSection kept rendering the exact
                  // same All/Chill/Commute/Energize/Feel good row every
                  // build, which is what was still showing up on Home.
                  // Actually removed now. _RealMoodChipsSection is left
                  // defined below (now unused) rather than deleted, in
                  // case it's wanted back later.
                  // Quick Picks — YT Music's own top-of-Home vertical
                  // song list, personalized off real listening history.
                  // Sits right under the mood chips, before the artist
                  // strip/shelves, to match the reference screenshots'
                  // top-level ordering.
                  SliverToBoxAdapter(
                    child: _QuickPicksSection(
                      refreshKey: _quickPicksRefreshKey,
                    ),
                  ),
                  // ADDED ("mixed for you bhe ekdam top level ka" —
                  // 2026-09-13): real YT Music web's own "Mixed for you"
                  // row (My Mix 1/2/3...) sits right after Quick Picks and
                  // Featured playlists — see reference screenshot. Built
                  // as genuinely real clusters: RecentlyPlayedProvider.
                  // topArtists() (real play-frequency ranking, already
                  // used elsewhere in this app) picks the artists, each
                  // card's starting songs are the user's own real history
                  // for that artist, and MixScreen's existing
                  // enableRefresh/refreshSeed (already built for
                  // exactly this — see mix_screen.dart's doc comment)
                  // expands it into a full mix on open. No invented/fake
                  // "My Mix N" numbering — real YT Music's own numbering
                  // is internal/arbitrary and not reproducible, so cards
                  // are named after the real artist instead, matching
                  // the visual language _HomeShelvesAndSimilarSection's
                  // "Similar to X" rows already use on this page.
                  // REMOVED ("your playlist faltu hai hata do, listening
                  // again hata do, mixed for you fake lag raha hai hata do
                  // agar 100% real InnerTube shelf nahi mil sakta" —
                  // 2026-09-13): all three of _MixedForYouSection (local
                  // play-history mix, not a genuine InnerTube carousel —
                  // anonymous FEmusic_home never returns a "Mixed for
                  // you"/"My Mix N" shelf, that only exists for a
                  // logged-in Google account, see _ytmHomeRaw's own doc
                  // comment above), _SpeedDialSection (displays as
                  // "Listen again" via homeListenAgain localization key),
                  // and _AccountPlaylistsSection ("Your playlists") are no
                  // longer mounted on Home. Classes left defined below
                  // (dead code) rather than deleted, in case wanted back
                  // later.
                  // ADDED ("ekdam youtube music jaisa home page" —
                  // 2026-09-13): real YT Music's own "Forgotten
                  // favourites" shelf — big video-style thumbnail cards
                  // resurfacing genuine on-device favorites the user
                  // hasn't played in a while (see
                  // RecommendationEngine.rediscoverCandidateIds's doc
                  // comment). Sits right after Listen Again, matching the
                  // reference screenshots' own ordering. Hides itself via
                  // its own empty-state checks for a fresh install with
                  // no qualifying history yet, same rule every optional
                  // Home section already follows.
                  const SliverToBoxAdapter(
                    child: _ForgottenFavouritesSection(),
                  ),
                  // ARCHIVETUNE-STRUCTURE MATCH ("sab kuch category aur
                  // artist ekdam ArchiveTune jaisa" — 2026-09-13):
                  // ArchiveTune's real HomeScreen.kt has no standalone
                  // "Popular Artists" flat-list section anywhere in its
                  // layout — that concept doesn't exist there. What it
                  // has instead, right after Forgotten Favorites and
                  // before the generic remote InnerTube sections, is a
                  // `uiState.similarRecommendations.forEach { ... }` loop:
                  // one real "Similar to <Artist>" header+row PER artist,
                  // never a generic combined artist strip.
                  // REMOVED AGAIN ("Popular Artists hata do, awkward lagta
                  // hai" — 2026-09-14): the 2026-09-14 restore above put
                  // _ArtistStrip back as a standalone "Popular Artists"
                  // shelf, but ArchiveTune's own real layout (this
                  // section's own doc comment above, still true) never had
                  // that concept — it only ever has one real artist-facing
                  // row per seed: "Similar to <Artist>"
                  // (_HomeShelvesAndSimilarSection below already covers
                  // this, fed by real per-artist InnerTube data). Sitting
                  // directly above the first "Similar to X" row, a
                  // separate flat "Popular Artists" strip duplicated that
                  // same real-artist concept right next to it, which is
                  // exactly the awkward back-to-back feel being fixed
                  // here. _homeArtists/_loadArtists() themselves are left
                  // untouched — only this render site is removed — so if
                  // a real standalone artist shelf is wanted again later,
                  // the underlying data is still there to wire back in.
                  SliverToBoxAdapter(
                    child: _HomeShelvesAndSimilarSection(
                      refreshKey: _playlistRefreshKey,
                      stage: _refreshStage,
                    ),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, SourceProvider src) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      floating: true,
      snap: true,
      elevation: 0,
      titleSpacing: 12,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      title: AurumPressable(
        scaleAmount: 0.95,
        onTap: () => Navigator.of(context).push(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 380),
            pageBuilder: (_, __, ___) => const PremiumScreen(),
            transitionsBuilder: (context, animation, __, child) {
              final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
              final slide = Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: animation, curve: AurumMotion.standard));
              return ColoredBox(
                color: AurumTheme.bgOf(context),
                child: FadeTransition(
                  opacity: fade,
                  child: SlideTransition(position: slide, child: child),
                ),
              );
            },
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                // Subtle depth layer — barely-there, not a glow.
                Text(
                  'Astra',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    height: 1.0,
                    foreground: Paint()
                      ..color = AurumTheme.accentOf(context).withOpacity(0.22)
                      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
                  ),
                ),
                ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: [
                      AurumTheme.accentLightOf(context),
                      AurumTheme.accentOf(context),
                      AurumTheme.accentDarkOf(context),
                    ],
                    stops: [0.0, 0.5, 1.0],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ).createShader(bounds),
                  child: const Text(
                    'Astra',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      height: 1.0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 8),
            // PREMIUM UPGRADE — slightly larger badge, crisper glow ring,
            // matches the bolder/bigger visual language used across the
            // rest of this redesign pass.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  colors: [AurumTheme.accentDarkOf(context), AurumTheme.accentOf(context), AurumTheme.accentLightOf(context)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.accentOf(context).withOpacity(0.5),
                    blurRadius: 14,
                    spreadRadius: 0.5,
                  ),
                ],
              ),
              child: const Text(
                '✦ Plus',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        _StatusPill(onTap: () => _showSourceSheet(context, src)),
        if (kDebugMode)
          IconButton(
            icon: Icon(Icons.bug_report_outlined,
                color: AurumTheme.textSecondaryOf(context)),
            onPressed: () async {
              // Wire the REAL engine in, so the "REAL PLAYBACK TEST" step
              // tests actual in-app playback instead of a throwaway player.
              // See api_service.dart / player_provider.dart for why this
              // distinction matters — it's what made this bug ambiguous.
              final playerProvider = context.read<PlayerProvider>();
              final result = await ApiService.debugPlaybackPath(
                realPlaybackTest: playerProvider.runRealPlaybackTest,
              );
              if (!context.mounted) return;
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text(AppLocalizations.of(context)!.homePlaybackDiagnostics),
                  content: SingleChildScrollView(
                    child: SelectableText(result),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(AppLocalizations.of(context)!.commonClose),
                    ),
                  ],
                ),
              );
            },
          ),
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          // Same AurumDepthRoute switch as library_screen.dart's matching
          // settings button — see that fix comment for the full reasoning.
          // Everything downstream of Settings (Player/Appearance/Language/
          // Storage/Notifications/Privacy/About/Premium) now matches too.
          onPressed: () => AurumDepthRoute.to(context, const SettingsScreen()),
        ),
        const _ProfileAvatarButton(),
      ],
    );
  }

  void _showSourceSheet(BuildContext context, SourceProvider src) {
    AurumHaptics.light();
    // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
    // so the scrim always has an explicit barrierColor.
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => _SourceSheet(src: src),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Online Content
// ─────────────────────────────────────────────────────────────────────────────

// PERF NOTE: this used to be a StatelessWidget (_OnlineContent) whose
// build() returned a single plain Column containing every streamed-in
// section. That Column was then wrapped in one SliverToBoxAdapter at the
// call site — which meant NONE of it was lazy: Flutter had to build and
// lay out all ~15-19 shelves (each up to 12 song cards with a network
// image) the instant they existed, whether or not they were anywhere near
// the viewport, and re-walk that whole subtree again on every new section
// arrival. The call site (_HomeScreenState's CustomScrollView) now builds
// a real SliverList directly instead, so only on-screen (+ cacheExtent)
// sections ever build. Only the shimmer/error placeholders are still
// needed as plain widgets here, each still wrapped in their own
// SliverToBoxAdapter at the call site.
Widget _buildOnlineShimmer(BuildContext context) {
  return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (_) => Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title placeholder
                // FIX (white flash on home screen load): Shimmer.fromColors
                // only overlays a gradient that sweeps OVER this box's own
                // color — it doesn't replace it. A raw Colors.white base
                // means any dropped/late frame in the shimmer's animation
                // (cold start, low-end device, first-paint before the
                // AnimationController ticks) shows a flat white box, which
                // reads as a "white tint flash" against the dark theme.
                // Using the theme's own card color as the base keeps it
                // correct-looking even on that first unanimated frame.
                Container(
                  width: 130,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AurumTheme.bgCardOf(context),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 14),
                // Cards row placeholder
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 4,
                    itemBuilder: (_, __) => Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: AurumTheme.bgCardOf(context),
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }

// `onRetry` is passed in explicitly now since this is a bare function, not
// a widget with access to a constructor field.
Widget _buildOnlineError(BuildContext context, {String? message, required VoidCallback onRetry}) {
  return SizedBox(
    height: 300,
    child: Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.wifi_off_rounded, size: 48,
            color: AurumTheme.textMutedOf(context)),
        const SizedBox(height: 12),
        Text(
          message ?? AppLocalizations.of(context)!.homeFailedToLoad,
          textAlign: TextAlign.center,
          style: TextStyle(color: AurumTheme.textMutedOf(context)),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: onRetry,
          child: Text(AppLocalizations.of(context)!.commonRetry, style: TextStyle(color: AurumTheme.accentOf(context))),
        ),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// One horizontal section row (title + "See all" + scrollable song cards).
// PERF/LEAK FIX: this used to be a plain helper method that created a new
// ScrollController() on every call and never disposed it. Because
// _StaggeredSection is now keyed by section.id and stable across rebuilds
// (see _OnlineContent above), a genuinely unchanged section no longer
// re-runs this at all — but when a section DOES get replaced (new content
// for the same shelf), the old controller still leaked with no dispose
// path, since a bare method has no lifecycle to hook into. Wrapping this in
// its own tiny StatefulWidget gives the controller a proper home with a
// real dispose(), so even a section that does refresh doesn't accumulate
// dead controllers over repeated cold starts/refreshes in one session.
// ─────────────────────────────────────────────────────────────────────────────
class _SongSectionRow extends StatefulWidget {
  final SongSection section;
  const _SongSectionRow({required this.section});

  @override
  State<_SongSectionRow> createState() => _SongSectionRowState();
}

class _SongSectionRowState extends State<_SongSectionRow> {
  // Shared controller so FadedHorizontalList can observe this row's
  // scroll position and only show each edge fade once there's actually
  // more content to scroll toward — see faded_horizontal_list.dart.
  late final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;

    // Shared "open this section as a full playlist" action — used by both
    // the title (tap the whole row header, like tapping a playlist name)
    // and the explicit "See all" button. Every home section (including
    // YouTube-only "Fan Favorites" and every other pool/genre/language
    // section) already gets the SAME real, tappable playlist screen this
    // way — full artwork header, complete song list (up to 100), play-all
    // — nothing extra needed to make any specific section "a real
    // playlist"; this IS the app's real playlist-detail view for a
    // curated/generated collection, no different from how a Saavn/YT
    // imported playlist opens.
    void openAsPlaylist() {
      AurumHaptics.selection();
      final art = section.songs
          .where((s) => s.artworkUrl.isNotEmpty)
          .map((s) => s.artworkUrl)
          .firstOrNull ?? '';
      AurumDepthRoute.to(
        context,
        MixScreen(
          mixId: section.id,
          mixName: section.title,
          artworkUrl: art,
          // No-emoji requirement: MixScreen only ever shows this glyph as
          // a fallback when artworkUrl is empty (real YouTube thumbnails
          // almost always exist, so this branch rarely renders) — a
          // plain music-note glyph from the icon font, not an emoji
          // character, so it can never violate "no emoji anywhere."
          emoji: '',
          songs: section.songs,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: openAsPlaylist,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        section.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // ECHO-NIGHTLY MATCH: replaced the "See all" text button
              // with the exact same treatment Echo Nightly uses on every
              // shelf header — a plain circular icon button holding a
              // simple forward-arrow glyph (Echo: ic_back flipped via
              // scaleX="-1", styled IconButtonTransparent — no fill, no
              // outline, no ripple background, just the glyph + a
              // touch-target-sized transparent hit area). Cheapest
              // possible swap: no new asset, no new package — Icons.
              // arrow_forward_rounded is already bundled with Flutter's
              // Material icon font, so this costs nothing extra in APK
              // size or first-paint time, same onTap/behavior as before.
              Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: openAsPlaylist,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 20,
                      color: AurumTheme.textPrimaryOf(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FadedHorizontalList(
            height: 214,
            controller: _scrollController,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 600,
              // FIX: last card was reading as cut-off against the right
              // screen edge — the outer section Padding has right:16, but
              // this list's own trailing padding was only 4px, so once the
              // per-card right:12 margin was consumed by the last item
              // there wasn't a matching gap to the edge like the left side
              // has. Bumping this to 16 mirrors the left inset exactly.
              padding: const EdgeInsets.only(right: 12),
              itemCount: section.songs.length.clamp(0, 12),
              itemBuilder: (_, i) {
                // CRASH FIX: section.songs can be replaced mid-scroll
                if (i >= section.songs.length) return const SizedBox.shrink();
                return _SongGridCard(
                  song: section.songs[i],
                  queue: section.songs,
                  index: i,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song grid card — one square album-art card per SONG (not per section),
// used for the horizontal genre/mood rows (Lofi Mix, 2000s Bollywood, Late
// Night Chill etc). Restored to match the original premium layout: clean
// square artwork, title + artist BELOW the art (not overlaid on top of it)
// — this is what makes each row read as a real music-app shelf instead of
// one oversized stretched poster per mix.
// ─────────────────────────────────────────────────────────────────────────────

class _SongGridCard extends StatefulWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongGridCard({required this.song, required this.queue, required this.index});

  @override
  State<_SongGridCard> createState() => _SongGridCardState();
}

class _SongGridCardState extends State<_SongGridCard> {
  // MAKKHAN FIX (Home screen horizontal shelves — "Spotify/YT Music jaisa
  // instant tap chahiye"): song_tile.dart already prewarms every tile the
  // moment it's built (near-visible, per SliverList/ListView semantics),
  // which is why Search/Library/Liked feel instant. Home's horizontal
  // shelves render through this card instead of SongTile, so those songs
  // never got that same head start — same class of gap _artist_screen's
  // 100-song list had before its own fix, just a different screen.
  //
  // Same staggered pattern as SongTile: only fires for cards that actually
  // get built (near-visible under the shelf's own cacheExtent), delay is
  // per-song (hash-based) so a fast horizontal fling doesn't fire a burst
  // of simultaneous Worker calls in the same frame, and the timer is
  // cancelled on dispose so a card that only flashed past never fires at
  // all. prewarmYtStream() itself already dedupes per session and skips
  // anything already cached, so this is safe to call even if the queue's
  // own _prewarmUpcoming() window also reaches the same song.
  Timer? _prewarmTimer;

  @override
  void initState() {
    super.initState();
    if (widget.song.source == SongSource.youtube) {
      final delayMs = 120 + (widget.song.id.hashCode.abs() % 280);
      _prewarmTimer = Timer(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        ApiService.prewarmYtStream(widget.song);
      });
    }
  }

  @override
  void dispose() {
    _prewarmTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final queue = widget.queue;
    final index = widget.index;
    // ECHO/YT-MUSIC MATCH: home shelves never showed the live "now
    // playing" equalizer bars — AurumEqualizerBars already existed
    // (search_screen.dart uses it) but was never wired in here. Same
    // identity-safe comparison as search_screen.dart: compares by
    // song.id, not title/artist strings, so a reupload/cover with a
    // matching title never falsely lights up.
    final isPlaying = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == song.id,
    );
    final isActuallyPlaying = context.select<PlayerProvider, bool>(
      (p) => p.isPlaying,
    );
    // PERF: isolates each horizontally-scrolling card into its own
    // compositor layer — same reasoning as SongTile/the followed-albums
    // grid. These rows can hold up to 12 cards each and there are several
    // per Home screen, so this adds up on weaker devices during scroll.
    return RepaintBoundary(
      child: AurumScrollNudge(
        child: GestureDetector(
      onTap: () {
        AurumHaptics.selection();
        // SPOTIFY-STYLE FIX ("kahi se bhi full player na khule"): tap
        // now only starts playback — mini player is the tap feedback.
        context.read<PlayerProvider>().playSong(song, queue: queue, index: index);
      },
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 152,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  children: [
                    AurumArtwork(url: song.artworkUrl, size: 152, borderRadius: 0),
                    if (isPlaying)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            // Dark translucent chip so the bars stay
                            // visible over any artwork color — same
                            // reasoning as the mini player's own tint
                            // fallback elsewhere in the app.
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: AurumEqualizerBars(
                            playing: isActuallyPlaying,
                            color: AurumTheme.accentOf(context),
                            size: 16,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Staggered section — fade + slide up, one by one
// ─────────────────────────────────────────────────────────────────────────────

class _StaggeredSection extends StatefulWidget {
  final String sectionId;
  final Widget child;
  const _StaggeredSection({super.key, required this.sectionId, required this.child});

  @override
  State<_StaggeredSection> createState() => _StaggeredSectionState();
}

// Tracks which section ids have already animated — survives rebuilds/back-nav.
// PERF FIX (cold-start "lag until refresh finishes"): this used to be keyed
// by positional `index`. On a cold start with cache-hydration, index 0..N
// gets its entry animation immediately from cached content; when the live
// network batch then streams in and REPLACES those same positions with
// different (or reordered) sections, the widget itself is now keyed by
// section.id (see _OnlineContent above) so Flutter mounts a genuinely new
// _StaggeredSectionState for a genuinely new section — but without id-based
// tracking here too, that fresh state had no memory of "was something
// already shown at this position" and would always animate, and worse,
// would stagger its delay off `index` even when 19 other sections were
// simultaneously arriving, compounding into a long visible cascade of
// fades/slides layered on top of the rebuild cost. Tracking by id means a
// section that was already shown (from cache or a previous stream) never
// re-animates just because it moved to a different index or got replaced
// in place, and only sections that are genuinely brand new to the screen
// pay the staggered entrance cost.
final _seenSections = <String>{};

class _StaggeredSectionState extends State<_StaggeredSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _fade;
  late Animation<Offset>   _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: AurumMotion.durationOrZero(AurumMotion.long2),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.10),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _ctrl, curve: AurumMotion.standard),
    );

    // If this section id has been seen before (already shown from cache,
    // a previous stream, or returning from FullPlayerScreen), skip the
    // animation entirely — jump to end state immediately. Only a section
    // id genuinely new to this screen gets the staggered fade-in, and the
    // stagger delay is based on how many *new* sections have appeared so
    // far this session, not raw list position — so a late-arriving section
    // in a list that already has 15 cached entries doesn't inherit a huge
    // index-based delay it doesn't need.
    //
    // PERF FIX ("cold start still laggy for the first 5-15s while
    // scrolling"): on a genuine first-ever launch (empty cache), ALL
    // 15-19 sections are "new" at once, each scheduling its own
    // Future.delayed + AnimationController.forward() — up to ~1.8s of
    // staggered timers whose forward() calls land back-to-back exactly
    // while the user is already scrolling. Every one of those is a real
    // animating widget competing for frame time on top of normal scroll
    // work, which is exactly the jank window being reported. Sections
    // past a small cap now skip the entrance animation and simply appear
    // — by the time 6+ sections have streamed in the user is already
    // scrolling past the earlier ones and would never see a slow-arriving
    // section's fade play out anyway, so this trades an invisible cosmetic
    // flourish for real scroll smoothness during the one window that
    // actually matters.
    const maxAnimatedSections = 6;
    if (_seenSections.contains(widget.sectionId)) {
      _ctrl.value = 1.0;
    } else {
      final newSectionOrder = _seenSections.length;
      _seenSections.add(widget.sectionId);
      if (newSectionOrder >= maxAnimatedSections) {
        _ctrl.value = 1.0;
      } else {
        Future.delayed(Duration(milliseconds: 50 + newSectionOrder * 70), () {
          if (mounted) _ctrl.forward();
        });
      }
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

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
// Offline Content
// ─────────────────────────────────────────────────────────────────────────────

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    // Astra's own in-app downloads (DownloadProvider/Hive) are a SEPARATE
    // source from the raw device MediaStore scan LibraryProvider does —
    // songs downloaded through the app never show up in `lib.allSongs`
    // unless MediaStore also happens to index that exact file. Without
    // this, "Downloaded" content the user got FROM Astra itself (the most
    // likely thing they'd expect to see first) was invisible on offline
    // Home — only songs picked up by a raw folder scan showed at all.
    final downloads = context.watch<DownloadProvider>().completed;

    final libLoading = lib.status == LibraryStatus.idle || lib.status == LibraryStatus.loading;
    if (libLoading && downloads.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: const Center(child: AurumMorphLoader(size: 56, contained: true)),
      );
    }
    if (lib.status == LibraryStatus.noPermission && downloads.isEmpty) {
      return _msg(context, Icons.folder_off_rounded,
          AppLocalizations.of(context)!.homeStoragePermissionNeeded, AppLocalizations.of(context)!.homeGrantPermission, () => lib.load());
    }
    if (lib.allSongs.isEmpty && downloads.isEmpty) {
      return _msg(context, Icons.music_off_rounded,
          AppLocalizations.of(context)!.homeNoLocalSongs, AppLocalizations.of(context)!.homeScanAgain, () => lib.refresh());
    }

    // De-dupe: a song already picked up by the raw MediaStore scan (same
    // local file) shouldn't also appear a second time as an "Astra
    // Downloads" card — keyed by local file path, the one identifier both
    // sources actually share.
    final scannedPaths = lib.allSongs.map((s) => s.localPath).whereType<String>().toSet();
    // BUGFIX ("downloaded song data off karke chalata hai to infinite
    // loading spinner, kabhi play nahi hota"): this used to map straight
    // to `d.song` — DownloadItem's own ORIGINAL online Song object, saved
    // at download-start time with its `localPath` field still null (the
    // actual downloaded file's path is stored separately on DownloadItem
    // itself, see download_item.dart). `d.song.isLocal` is therefore
    // FALSE for every card in this row, even though the file is fully
    // downloaded — so tapping one from Home routed straight into
    // PlayerProvider's ONLINE streaming path (resolveWithPatience's
    // network branch in AurumAudioEngine.kt), which with no internet just
    // retries forever with nothing to show but a spinner. The exact same
    // song tapped from the Downloads/Library screen worked fine, because
    // that screen already goes through DownloadProvider.offlineSongFor()
    // — which merges d.localPath (the real downloaded file path) onto a
    // copy of the song via copyWith(localPath: ...), making isLocal true
    // and letting the native engine's isLocal shortcut hand back the
    // file:// URI instantly, no network involved. Doing that same merge
    // here means every entry point into a downloaded song — Home included
    // — carries a working localPath, not just Downloads/Library.
    final appDownloadedSongs = downloads
        .map((d) => d.localPath != null ? d.song.copyWith(localPath: d.localPath) : d.song)
        .where((s) => s.localPath == null || !scannedPaths.contains(s.localPath))
        .toList();

    final librarySections = lib.sections.isNotEmpty
        ? lib.sections
        : (lib.allSongs.isNotEmpty
            ? [SongSection(title: AppLocalizations.of(context)!.homeLocalSongs, songs: lib.allSongs)]
            : <SongSection>[]);

    // Astra's own downloads lead the page — most-recently-downloaded
    // first (DownloadProvider.completed is already sorted newest-first),
    // same "your most recent activity surfaces first" logic the online
    // feed's own "Because You Played" row follows.
    // NOTE (l10n): "Downloaded on Astra" is a brand name + fixed English
    // word pair — same category as "Made for You" and "Because You
    // Played" elsewhere in api_service.dart, which this codebase also
    // keeps as fixed English label text rather than routing through
    // AppLocalizations (those are generated section titles, not UI
    // chrome). Left un-keyed for the same reason, rather than guessing a
    // translation into all 16 locales myself and risking a wrong one
    // shipping silently — an actual translator should add a proper
    // homeDownloadedOnAurum key across every app_*.arb file.
    final sections = <SongSection>[
      if (appDownloadedSongs.isNotEmpty)
        SongSection(id: 'astra_downloads', title: 'Downloaded on Astra', songs: appDownloadedSongs),
      ...librarySections,
    ];

    final totalCount = appDownloadedSongs.length + lib.allSongs.length;

    // REDESIGN ("echo nightly / production level" request): a separate
    // hero banner here (blurred artwork + all-caps label + big count) was
    // dropped after review — the online feed itself has NO such banner
    // above its sections (see build() above, just _TopAmbientGlow behind
    // everything), so adding one only for offline content created a
    // second, inconsistent design language instead of matching the app's
    // actual premium look. Real reference apps (Spotify's own Downloaded
    // tab) don't banner-ize this either — they go straight into the
    // shelf/grid. Offline content now opens directly into the SAME
    // horizontal artwork-card shelves (_SongGridCard) + "See all" →
    // MixScreen the online feed uses, with one plain section-count line
    // in the same style Search/Library already use for list counts —
    // consistent with the rest of the app rather than a bespoke banner.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
          child: Row(children: [
            Icon(Icons.download_done_rounded, color: AurumTheme.accentOf(context), size: 16),
            const SizedBox(width: 6),
            Text(
              '$totalCount songs on device',
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ),
        ...sections.asMap().entries.map((e) => _StaggeredSection(
          key: ValueKey('offline_${e.value.id}'),
          sectionId: 'offline_${e.value.id}',
          child: _OfflineSectionRow(section: e.value),
        )),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _msg(BuildContext context, IconData icon, String msg,
      String label, VoidCallback onTap) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 48, color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: AurumTheme.textMutedOf(context))),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onTap,
            child: Text(label, style: TextStyle(color: AurumTheme.accentOf(context))),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// One offline section rendered as the exact same horizontal artwork-card
// shelf the online feed uses (_SongGridCard), with a "See all" that opens
// the SAME MixScreen every online curated mix opens into — so a folder of
// local songs reads and behaves like a real playlist, title/artwork/emoji
// and all, instead of a flat file-browser list.
// ─────────────────────────────────────────────────────────────────────────────
class _OfflineSectionRow extends StatefulWidget {
  final SongSection section;
  const _OfflineSectionRow({required this.section});

  @override
  State<_OfflineSectionRow> createState() => _OfflineSectionRowState();
}

class _OfflineSectionRowState extends State<_OfflineSectionRow> {
  late final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _openMix(BuildContext context) {
    AurumHaptics.selection();
    final section = widget.section;
    final art = section.songs
        .map((s) => s.artworkUrl)
        .firstWhere((u) => u.isNotEmpty, orElse: () => '');
    AurumDepthRoute.to(
      context,
      MixScreen(
        mixId: section.id,
        mixName: section.title,
        artworkUrl: art,
        emoji: '', // no-emoji requirement — MixScreen renders an Icon fallback now
        songs: section.songs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    // PREMIUM/PRODUCTION UPGRADE — offline row header brought to the same
    // visual language as the online shelves (_RealHomeShelfRow): gradient
    // accent tick + bold 800-weight title, instead of the plainer 700
    // header this row had before. Keeps the whole app — online or
    // offline — reading as one consistent design system rather than
    // offline content looking like a lower-tier fallback screen.
    final isAstraDownloads = section.id == 'astra_downloads';
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 4,
                      height: 18,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        gradient: AurumTheme.accentGradientOf(context),
                      ),
                    ),
                    if (isAstraDownloads) ...[
                      Icon(Icons.download_done_rounded,
                          size: 16, color: AurumTheme.accentOf(context)),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        section.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _openMix(context),
                  // FIX: hardcoded English on this new offline row — reuses
                  // the app's existing commonSeeAll key (already defined
                  // across all 16 locale .arb files) instead of introducing
                  // another un-translated string, matching how every
                  // localized label elsewhere in this file is sourced.
                  // PREMIUM UPGRADE — glass pill wrapper matching the
                  // online shelf row's "see all" arrow treatment, instead
                  // of a bare text link.
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: AurumTheme.bgCardOf(context).withOpacity(0.6),
                      border: Border.all(
                        color: AurumTheme.dividerOf(context),
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.commonSeeAll,
                      style: TextStyle(
                        color: AurumTheme.accentOf(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FadedHorizontalList(
            height: 214,
            controller: _scrollController,
            child: ListView.builder(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 600,
              padding: const EdgeInsets.only(right: 12),
              itemCount: section.songs.length.clamp(0, 12),
              itemBuilder: (_, i) {
                if (i >= section.songs.length) return const SizedBox.shrink();
                return _SongGridCard(
                  song: section.songs[i],
                  queue: section.songs,
                  index: i,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile Avatar Button
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileAvatarButton extends StatelessWidget {
  const _ProfileAvatarButton();

  Future<void> _openProfile(BuildContext context) async {
    AurumHaptics.light();
    final auth = context.read<AuthProvider>();

    if (!auth.isSignedIn) {
      // Not signed in → animated slide to LoginScreen
      await Navigator.push<bool>(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, __, ___) => const LoginScreen(),
          transitionsBuilder: (context, animation, __, child) => ColoredBox(
            color: AurumTheme.bgOf(context),
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                    parent: animation, curve: AurumMotion.standard)),
                child: child,
              ),
            ),
          ),
        ),
      );
      return;
    }

    // Signed in → go straight to ProfileScreen
    // Same AurumDepthRoute switch as the Settings button above — Profile
    // is reached from the same top bar, so it now shares the identical
    // fade + slide-up push/pop instead of AurumPageRoute's horizontal
    // slide-in-from-right.
    await AurumDepthRoute.to(context, const ProfileScreen());
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = context.watch<AuthProvider>().avatarUrl;

    return Padding(
      padding: const EdgeInsets.only(right: 12, left: 4),
      child: AurumPressable(
        scaleAmount: 0.90,
        onTap: () => _openProfile(context),
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AurumTheme.accentGradientOf(context),
          ),
          padding: const EdgeInsets.all(1.5),
          child: ClipOval(
            child: avatarUrl != null
                ? CachedNetworkImage(
                    imageUrl: avatarUrl,
                    cacheManager: AurumImageCache(),
                    fit: BoxFit.cover,
                    memCacheWidth: 96,
                    memCacheHeight: 96,
                    // FIX: same white/grey flash issue as the Trending
                    // Playlists cards — without a `placeholder`,
                    // CachedNetworkImage shows its own flat grey/white
                    // box while the avatar is still downloading. Using
                    // the themed default icon here instead keeps the
                    // top-bar avatar looking intentional the whole time.
                    placeholder: (_, __) => _defaultIcon(context),
                    errorWidget: (_, __, ___) => _defaultIcon(context),
                  )
                : _defaultIcon(context),
          ),
        ),
      ),
    );
  }

  Widget _defaultIcon(BuildContext context) => Container(
        color: AurumTheme.bgOf(context),
        child: Icon(Icons.person_rounded,
            color: AurumTheme.textSecondaryOf(context), size: 20),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Status Pill — premium glass pill, taps open the source sheet
// ─────────────────────────────────────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  final VoidCallback onTap;
  const _StatusPill({required this.onTap});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> {
  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<SourceProvider>().isOnline;
    // PREMIUM UPGRADE ("toggle akward lag raha hai" — 2026-09-11): the
    // pill previously showed only a plain colored dot + text label, which
    // read as a passive status readout rather than something tappable —
    // nothing about it visually said "control". Redesigned as a proper
    // two-state pill: a filled icon chip (cloud when online, phone when
    // offline) that itself changes shape/color, animated cross-fade
    // between icons rather than an instant swap, and a stronger online
    // glow so the tappable affordance reads clearly at a glance instead
    // of requiring the text to be read.
    final tint = isOnline ? AurumTheme.accentOf(context) : AurumTheme.textMutedOf(context);

    return AurumPressable(
      scaleAmount: 0.94,
      onTap: widget.onTap,
      child: AnimatedContainer(
          duration: AurumMotion.durationOrZero(AurumMotion.medium1),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          padding: const EdgeInsets.only(left: 5, right: 12, top: 5, bottom: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: AurumTheme.bgCardOf(context).withOpacity(0.65),
            border: Border.all(
              color: isOnline
                  ? tint.withOpacity(0.35)
                  : AurumTheme.dividerOf(context),
              width: 1,
            ),
            boxShadow: isOnline
                ? [
                    BoxShadow(
                      color: tint.withOpacity(0.25),
                      blurRadius: 12,
                      spreadRadius: -2,
                    ),
                  ]
                : [],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Icon chip — its own filled circle so the pill reads as a
              // real control (like a switch's thumb) rather than a plain
              // status dot next to a label.
              AnimatedContainer(
                duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: isOnline ? AurumTheme.accentGradientOf(context) : null,
                  color: isOnline ? null : AurumTheme.bgElevatedOf(context),
                ),
                child: AnimatedSwitcher(
                  duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
                  child: Icon(
                    isOnline ? Icons.cloud_rounded : Icons.phone_iphone_rounded,
                    key: ValueKey(isOnline),
                    size: 13,
                    color: isOnline ? Colors.black : AurumTheme.textSecondaryOf(context),
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                isOnline ? AppLocalizations.of(context)!.homeOnline : AppLocalizations.of(context)!.homeOffline,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Source Sheet — premium glass bottom sheet for switching source mode
// ─────────────────────────────────────────────────────────────────────────────

class _SourceSheet extends StatefulWidget {
  final SourceProvider src;
  const _SourceSheet({required this.src});

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  // PREMIUM/PRODUCTION UPGRADE ("online pe click kre to google loading
  // show kre aur internet na rhne pr check your internet connection
  // likhe" — 2026-09-11): tapping Online used to call src.toggle() and
  // pop instantly — if there was genuinely no network, toggle() silently
  // did nothing (see SourceProvider.toggle's own doc comment) and the
  // sheet just closed with zero feedback, looking broken/unresponsive.
  // Now: a brief loading state shows on the tapped row itself (a real
  // spinner, not a fake delay — this doubles as the "let connectivity
  // settle" beat if the radio was flipped on a split-second ago), then
  // either switches + closes, or shows an inline error and stays open so
  // the user immediately understands why nothing happened.
  bool _connecting = false;
  String? _error;

  Future<void> _selectOnline() async {
    if (widget.src.isOnline) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    // Real connectivity re-check right before switching — covers the
    // "user just turned WiFi back on and tapped Online immediately"
    // case, where the OS/plugin's cached state can lag a moment behind
    // reality.
    await Future.delayed(const Duration(milliseconds: 450));
    if (!mounted) return;
    final ok = widget.src.toggle();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _connecting = false;
        _error = AppLocalizations.of(context)!.homeCheckYourInternet;
      });
      return;
    }
    Navigator.pop(context);
  }

  void _selectOffline() {
    if (!widget.src.isOnline) {
      Navigator.pop(context);
      return;
    }
    widget.src.toggle();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.src;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bg = AurumTheme.bgCardOf(context);
    final border = AurumTheme.dividerOf(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AurumMotion.durationOrZero(AurumMotion.medium1),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 16),
          child: child,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: bg.withOpacity(isLight ? 0.92 : 0.95),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: border, width: 0.5)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 32, height: 4,
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: AurumTheme.textMutedOf(context).withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      AppLocalizations.of(context)!.homePlaybackSource,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppLocalizations.of(context)!.homePlaybackSourceSubtitle,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _SourceOption(
                      icon: Icons.cloud_outlined,
                      label: AppLocalizations.of(context)!.homeOnlineStreaming,
                      subtitle: AppLocalizations.of(context)!.homeStreamOnlineDesc,
                      selected: src.isOnline,
                      loading: _connecting,
                      onTap: _connecting ? () {} : _selectOnline,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.wifi_off_rounded,
                              size: 14, color: const Color(0xFFE0A030)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: Color(0xFFE0A030),
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    _SourceOption(
                      icon: Icons.phone_iphone_rounded,
                      label: AppLocalizations.of(context)!.homeOfflineLibrary,
                      subtitle: AppLocalizations.of(context)!.homeOfflineLibraryDesc,
                      selected: !src.isOnline,
                      onTap: _connecting ? () {} : _selectOffline,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceOption extends StatefulWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool loading;
  const _SourceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.loading = false,
  });

  @override
  State<_SourceOption> createState() => _SourceOptionState();
}

class _SourceOptionState extends State<_SourceOption> {
  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.98,
      onTap: widget.onTap,
      child: AnimatedContainer(
          duration: AurumMotion.durationOrZero(AurumMotion.medium1),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.selected
                ? AurumTheme.accentOf(context).withOpacity(0.12)
                : AurumTheme.bgElevatedOf(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.selected
                  ? AurumTheme.accentOf(context).withOpacity(0.5)
                  : AurumTheme.dividerOf(context),
              width: 1,
            ),
          ),
          child: Row(children: [
            Icon(widget.icon,
                size: 20,
                color: widget.selected
                    ? AurumTheme.accentOf(context)
                    : AurumTheme.textSecondaryOf(context)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.label,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 2),
                  Text(widget.subtitle,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 11.5,
                      )),
                ],
              ),
            ),
            if (widget.selected)
              Icon(Icons.check_circle_rounded, size: 18, color: AurumTheme.accentOf(context))
            else if (widget.loading)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: AurumTheme.accentOf(context),
                ),
              ),
          ]),
        ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Speed Dial — small round "jump back in" chips: the last few distinct
// songs the user actually played, tap to resume instantly. Matches
// ArchiveTune's real HomeScreen.kt (uiState.speedDialItems, rendered right
// under Quick Picks/before Forgotten Favorites) — square art, name below,
// no header row of its own beyond the section title, same visual weight as
// a YT Music "Speed dial" strip. Backed entirely by
// RecentlyPlayedProvider.history — genuine on-device play history, no
// invented/random entries. Hides itself completely (no title, no empty
// row) when there's no history yet, same rule every optional Home section
// on this page already follows.
// ─────────────────────────────────────────────────────────────────────────────
class _SpeedDialSection extends StatelessWidget {
  const _SpeedDialSection();

  static const int _kMaxShown = 8;

  @override
  Widget build(BuildContext context) {
    final history = context.watch<RecentlyPlayedProvider>().history;
    if (history.isEmpty) return const SizedBox.shrink();
    final songs = history.take(_kMaxShown).toList();
    final player = context.read<PlayerProvider>();

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context)?.homeListenAgain ?? 'Speed dial',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 118,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 500,
              padding: const EdgeInsets.only(right: 12),
              itemCount: songs.length,
              itemBuilder: (_, i) => _SafeListenAgainCard(
                song: songs[i],
                compact: true,
                onTap: () {
                  player.playSong(songs[i], queue: songs, index: i);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Account Playlists — the user's own real playlists (PlaylistProvider),
// matching ArchiveTune's real HomeScreen.kt uiState.accountPlaylists row.
// Only appears when the user actually has at least one playlist — a
// brand-new install with zero playlists shows nothing here, same rule
// every optional Home section already follows.
// ─────────────────────────────────────────────────────────────────────────────
class _AccountPlaylistsSection extends StatelessWidget {
  const _AccountPlaylistsSection();

  @override
  Widget build(BuildContext context) {
    final playlists = context.watch<PlaylistProvider>().playlists;
    if (playlists.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your playlists',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 700,
              padding: const EdgeInsets.only(right: 12),
              itemCount: playlists.length,
              itemBuilder: (_, i) =>
                  _AccountPlaylistCard(playlist: playlists[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountPlaylistCard extends StatelessWidget {
  final AurumPlaylist playlist;
  const _AccountPlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return _ErrorBoundary(
      fallback: const SizedBox(width: 148),
      child: AurumPressable(
        scaleAmount: 0.96,
        onTap: () {
          AurumHaptics.selection();
          AurumDepthRoute.to(
            context,
            PlaylistDetailScreen(playlistId: playlist.id),
          );
        },
        child: Container(
          width: 148,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: playlist.coverArt != null
                    ? AurumArtwork(
                        url: playlist.coverArt!, size: 296, borderRadius: 12)
                    : Container(
                        width: 148,
                        height: 148,
                        color: AurumTheme.bgCardOf(context),
                        child: Icon(Icons.queue_music_rounded,
                            color: AurumTheme.accentOf(context), size: 40),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${playlist.songCount} songs',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mixed for you — real YT Music web's "My Mix N" row, rebuilt honestly:
// each card is a genuine per-artist mix seeded entirely from the user's own
// RecentlyPlayedProvider history (never invented/random). Artists are
// ranked by topArtists() — the same real play-frequency ranking
// ApiService.fetchHome() already trusts elsewhere in this app — so the
// artists that show up here are the ones the user has actually played
// most. Tapping a card opens MixScreen pre-seeded with that artist's real
// history songs, with enableRefresh/refreshSeed wired in so pulling down
// inside the mix genuinely expands it via ApiService.fetchMixRefreshSongs
// (existing infra, not new plumbing). Hides entirely for a fresh install
// with no history yet, same rule every optional Home section follows.
// ─────────────────────────────────────────────────────────────────────────────
class _MixedForYouSection extends StatelessWidget {
  const _MixedForYouSection();

  static const int _kMaxMixes = 6;

  @override
  Widget build(BuildContext context) {
    final recently = context.watch<RecentlyPlayedProvider>();
    final artists = recently.topArtists(count: _kMaxMixes);
    if (artists.isEmpty) return const SizedBox.shrink();

    final history = recently.history;

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Mixed for you',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 210,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 700,
              padding: const EdgeInsets.only(right: 12),
              itemCount: artists.length,
              itemBuilder: (_, i) {
                final artistName = artists[i];
                // Real seed songs: only this artist's own songs, most
                // recently played first (history is already newest-first).
                final seedSongs = history
                    .where((s) => s.artist == artistName)
                    .take(20)
                    .toList();
                if (seedSongs.isEmpty) return const SizedBox.shrink();
                return _MixCard(artistName: artistName, seedSongs: seedSongs);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MixCard extends StatelessWidget {
  final String artistName;
  final List<Song> seedSongs;
  const _MixCard({required this.artistName, required this.seedSongs});

  @override
  Widget build(BuildContext context) {
    return _ErrorBoundary(
      fallback: const SizedBox(width: 148),
      child: AurumPressable(
        scaleAmount: 0.96,
        onTap: () {
          AurumHaptics.selection();
          AurumDepthRoute.to(
            context,
            MixScreen(
              mixId: 'mix_${artistName.hashCode}',
              mixName: '$artistName Mix',
              artworkUrl: seedSongs.first.artworkUrl,
              emoji: '',
              songs: seedSongs,
              enableRefresh: true,
              refreshSeed: artistName,
            ),
          );
        },
        child: Container(
          width: 148,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AurumArtwork(
                    url: seedSongs.first.artworkUrl,
                    size: 296,
                    borderRadius: 12),
              ),
              const SizedBox(height: 6),
              Text(
                '$artistName Mix',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13,
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

// ─────────────────────────────────────────────────────────────────────────────
// Recently Played — square art tiles of the user's own play history, tap to
// play directly (unlike every other row on this page, these are individual
// songs, not a mix/album to open — so no MixScreen navigation here).
//
// UNMOUNTED ("listen again wala hata do ye akward hai" — 2026-09-13): no
// longer called anywhere on Home (see _HomeScreenState.build()). Left
// defined here rather than deleted, in case it's wanted back later.
// ─────────────────────────────────────────────────────────────────────────────

// Thin isolation wrapper so watching RecentlyPlayedProvider (which
// changes on every single play) only rebuilds this one shelf — see the
// PERF note at this section's Home build() call site for why a bare
// context.watch() directly in _HomeScreenState.build() would be wrong.
class _ListenAgainSection extends StatelessWidget {
  const _ListenAgainSection();

  @override
  Widget build(BuildContext context) {
    final history = context.watch<RecentlyPlayedProvider>().history;
    return _RecentlyPlayedSection(
      title: AppLocalizations.of(context)!.homeListenAgain,
      songs: history.take(12).toList(),
    );
  }
}

class _RecentlyPlayedSection extends StatelessWidget {
  final String title;
  final List<Song> songs;
  const _RecentlyPlayedSection({required this.title, required this.songs});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) return const SizedBox.shrink();
    final player = context.read<PlayerProvider>();
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 168,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 600,
              padding: const EdgeInsets.only(right: 12),
              itemCount: songs.length,
              itemBuilder: (_, i) => _SafeListenAgainCard(
                song: songs[i],
                onTap: () {
                  // SPOTIFY-STYLE FIX ("kahi se bhi full player na
                  // khule"): tap now only starts playback.
                  player.playSong(songs[i], queue: songs, index: i);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// CRASH FIX ("RangeError (length): Invalid value: Not in inclusive range
// 0..1: 2" — red error card appearing in place of a Listen Again tile,
// 2026-09-13): whatever throws inside AurumArtwork's decode path for a
// specific song's artwork URL was surfacing as a raw ErrorWidget inline
// in the carousel — exactly the "koi bhi card crash na kare, silently
// skip ho" behavior real production apps (including YT Music itself)
// already guarantee for a single bad thumbnail. ErrorWidget.builder is
// overridden per-subtree here via a Builder + runtime try/catch
// equivalent: FlutterError.onError can't catch synchronous build()
// exceptions after the fact, so instead this widget defers to
// ErrorWidget.builder scoped locally — any exception thrown while
// building this one card's subtree now renders as a plain empty
// SizedBox(width: 130) (same footprint as a real card, no visible gap
// jump in the carousel) instead of the default red-screen ErrorWidget,
// while every other card in the row is completely unaffected.
class _SafeListenAgainCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  // Smaller footprint for _SpeedDialSection's round-trip chip row (matches
  // ArchiveTune's Speed Dial sizing, which sits visually lighter than the
  // bigger Forgotten Favourites cards). Default (false) keeps the original
  // 130px size used elsewhere.
  final bool compact;
  const _SafeListenAgainCard({
    required this.song,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final width = compact ? 92.0 : 130.0;
    return _ErrorBoundary(
      fallback: SizedBox(width: width),
      child: AurumPressable(
        scaleAmount: 0.96,
        onTap: onTap,
        child: Container(
          width: width,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(compact ? 10 : 12),
                child: AurumArtwork(
                    url: song.artworkUrl,
                    size: compact ? 184 : 260,
                    borderRadius: compact ? 10 : 12),
              ),
              const SizedBox(height: 6),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: compact ? 12 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!compact)
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Generic per-subtree error boundary: overrides ErrorWidget.builder while
// [child]'s subtree is being built, so any exception thrown while laying
// out that subtree (a bad artwork URL, malformed song data, etc.) renders
// as [fallback] instead of Flutter's default (here, main.dart's loud red
// debug box) ErrorWidget.
//
// BUG FIX (this override was a no-op — the RangeError red box in Listen
// Again kept showing up even with this class in place, 2026-09-13):
// the previous version wrapped `return child;` in a plain try/finally,
// restoring the previous builder immediately once build() returned. But
// build() only returns the *widget object* — Flutter's element system
// (ComponentElement.performRebuild) calls build() and THEN, as a separate
// later step, recursively mounts/builds that returned widget's own
// subtree via updateChild(). That recursion — which is what actually
// invokes AurumArtwork's build() and can throw — happens AFTER this
// method's try/finally has already completed and already restored the
// original builder. So the override was already gone before the risky
// subtree was ever built, and main.dart's global red-box builder is what
// fired every time — exactly what the screenshot showed.
// Deferring the restore to a post-frame callback keeps the override alive
// through that same-frame build/mount recursion instead.
class _ErrorBoundary extends StatelessWidget {
  final Widget child;
  final Widget fallback;
  const _ErrorBoundary({required this.child, required this.fallback});

  @override
  Widget build(BuildContext context) {
    ErrorWidget.builder = (details) => fallback;
    // Restores to main.dart's real debug builder BY REFERENCE (not a
    // snapshot taken at some earlier point) — see aurumDebugErrorWidgetBuilder's
    // own doc comment for why a snapshot here would be unreliable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ErrorWidget.builder = aurumDebugErrorWidgetBuilder;
    });
    return child;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Forgotten Favourites — YT Music's own "songs you loved but haven't
// played lately" shelf: one big 16:9-style artwork card (title overlaid
// on artwork bottom, same visual language as a video thumbnail on real
// YT Music's own Home) rather than a small square. Backed entirely by
// RecommendationEngine.rediscoverCandidateIds — genuine on-device
// listening history (played 2+ times, or completed at least once, but
// not played again in 21+ days), never invented/random. Resolves IDs
// against RecentlyPlayedProvider.history since that's the only place
// full Song objects for past plays already live in memory; an id with
// no matching Song (e.g. history since trimmed) is simply skipped.
// ─────────────────────────────────────────────────────────────────────────────
class _ForgottenFavouritesSection extends StatelessWidget {
  const _ForgottenFavouritesSection();

  @override
  Widget build(BuildContext context) {
    final history = context.watch<RecentlyPlayedProvider>().history;
    if (history.isEmpty) return const SizedBox.shrink();

    final candidateIds = RecommendationEngine.rediscoverCandidateIds(count: 10);
    if (candidateIds.isEmpty) return const SizedBox.shrink();

    final byId = {for (final s in history) s.id: s};
    final songs = candidateIds
        .map((id) => byId[id])
        .whereType<Song>()
        .toList();
    if (songs.isEmpty) return const SizedBox.shrink();

    final player = context.read<PlayerProvider>();
    return Padding(
      padding: const EdgeInsets.only(top: 32, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 4,
                height: 18,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: AurumTheme.accentGradientOf(context),
                ),
              ),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.homeForgottenFavourites,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // FIX ("ekdam youtube music jaisa" recheck — 2026-09-13): the
          // reference is a single full-width card, not a horizontal
          // carousel — earlier version wrongly rendered this as a
          // scrollable row. Only the first (strongest-signal) candidate
          // from rediscoverCandidateIds is shown, matching that exact
          // one-card layout.
          _ForgottenFavouriteCard(
            song: songs.first,
            onTap: () {
              AurumHaptics.selection();
              player.playSong(songs.first, queue: songs, index: 0);
            },
          ),
        ],
      ),
    );
  }
}

class _ForgottenFavouriteCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  const _ForgottenFavouriteCard({required this.song, required this.onTap});

  // Compact view-count formatter (e.g. 8_600_000 -> "8.6M"), matching
  // YouTube's own convention for this exact caption style. Only ever
  // called when song.viewCount is genuinely non-null (see the caption
  // Text above) — never invents a count for a song without one.
  static String _formatViewCount(int count) {
    if (count >= 1000000000) {
      return '${(count / 1000000000).toStringAsFixed(1)}B';
    }
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    }
    if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}K';
    }
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.97,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AurumArtwork(
                        url: song.artworkUrl, size: 560, borderRadius: 0),
                    // Bottom gradient scrim so the title stays legible
                    // over any artwork, same treatment real YT Music
                    // uses on its own video-style thumbnail cards.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.75),
                          ],
                          stops: const [0.5, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: Text(
                        song.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              // FEATURE ("ekdam youtube music jaisa" recheck — 2026-09-13):
              // real YT Music's own Forgotten Favourites caption reads
              // "Artist · X views" when a genuine view count is known.
              // song.viewCount is only ever populated for real YouTube
              // results (see Song's own doc comment) — never fabricated
              // here; a song with no known count just shows the artist
              // name alone, same as before.
              song.viewCount != null
                  ? '${song.artist} • ${_formatViewCount(song.viewCount!)} views'
                  : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artist Strip — Echo Nightly-style full-width list rows (circular
// avatar + name + play button), stacked vertically, ek ke niche ek —
// matched 1:1 to Echo's item_shelf_media.xml/item_shelf_media_cover.xml
// (see AurumStackedArtwork's doc comment for the depth-layer recipe).
// Previously a horizontal row of small circular chips; that read as
// "just some faces" rather than a premium, browsable artist section —
// full rows give each artist real weight (name at 16sp like Echo's
// title TextView, a always-visible play affordance) matching how every
// other "real" music app (and Echo itself) treats artists on the home
// feed, not as an afterthought strip.
// ─────────────────────────────────────────────────────────────────────────────

class _ArtistStrip extends StatefulWidget {
  final List<ArtistSimple> artists;
  final bool loading;
  const _ArtistStrip({required this.artists, required this.loading});

  @override
  State<_ArtistStrip> createState() => _ArtistStripState();
}

class _ArtistStripState extends State<_ArtistStrip> {
  // RECHECK ("ekdam top level ka hai na ab vo artist ya kuch bhe akward
  // nhi hai na" — 2026-09-13): capped at 10 full-width rows, this block
  // ran to roughly 900px of solid vertical space right under Quick
  // Picks — nothing in the real music.youtube.com reference screenshots
  // shows a standalone artist block anywhere near that size; the real
  // app's own artist rows only ever appear as small "Similar to X"
  // carousels (2-4 cards) interleaved between shelves, which
  // _HomeShelvesAndSimilarSection below already provides. Cut to 4 so
  // this reads as one reasonably-sized taste-signal shelf instead of a
  // page-dominating wall of rows.
  static const int _maxShown = 4;

  @override
  Widget build(BuildContext context) {
    final artists = widget.artists;
    final loading = widget.loading;
    // Kept at top:28 to match every other section's rhythm (Trending
    // Playlists, each SongSection) — see the file-wide note on this.
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context)!.homePopularArtists,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 14),
          // HORIZONTAL CIRCULAR-AVATAR CAROUSEL ("ekdam youtube music
          // jaisa, popular artists ka vertical list bahut akward lag
          // raha hai" — 2026-09-13): real music.youtube.com never shows
          // a standalone full-width vertical artist list on Home — every
          // artist row there (including its own "Similar to X" shelves)
          // is a horizontal strip of small circular avatar chips. Swapped
          // back from the full-width _ArtistFullRow column to the
          // existing _ArtistChip horizontal strip so this section matches
          // that reference shape exactly. _ArtistFullRow is left defined
          // below (now unused) rather than deleted, in case a full-width
          // row is wanted again elsewhere later.
          loading
              ? _buildChipShimmer(context)
              : artists.isEmpty
                  ? const SizedBox.shrink()
                  : SizedBox(
                      height: 150,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: artists.take(_maxShown).length,
                        itemBuilder: (context, index) {
                          final a = artists.take(_maxShown).toList()[index];
                          return _ArtistChip(key: ValueKey(a.id), artist: a);
                        },
                      ),
                    ),
        ],
      ),
    );
  }

  Widget _buildChipShimmer(BuildContext context) {
    return SizedBox(
      height: 150,
      child: Shimmer.fromColors(
        baseColor: AurumTheme.bgCardOf(context),
        highlightColor: AurumTheme.bgElevatedOf(context),
        child: Row(
          children: List.generate(4, (_) => Container(
            width: 110,
            margin: const EdgeInsets.only(right: 16),
            child: Column(
              children: [
                CircleAvatar(radius: 52, backgroundColor: AurumTheme.bgCardOf(context)),
                const SizedBox(height: 10),
                Container(
                  height: 13,
                  width: 70,
                  decoration: BoxDecoration(
                    color: AurumTheme.bgCardOf(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }
}

class _ArtistChip extends StatelessWidget {
  final ArtistSimple artist;
  const _ArtistChip({super.key, required this.artist});

  Future<void> _open(BuildContext context) async {
    AurumHaptics.selection();
    final id = artist.id.isNotEmpty
        ? artist.id
        : await ApiService.resolveArtistId(artist.name);
    if (id == null || !context.mounted) return;
    AurumDepthRoute.to(
      context,
      ArtistScreen(artistId: id, artistName: artist.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Highlights this chip while the artist's own song is the one
    // actively playing — same "you're already listening to this" signal
    // Echo gives via its isPlaying badge, surfaced at the artist level.
    final isCurrentArtist = context.select<PlayerProvider, bool>(
      (p) => p.currentSong != null &&
          p.currentSong!.artist.toLowerCase() == artist.name.toLowerCase(),
    );
    final isActuallyPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);

    // PERF FIX (scroll jank): this chip listens to PlayerProvider via
    // context.select — every song change AND every play/pause toggle
    // rebuilds every single chip in the strip, including all the ones
    // that aren't the current artist. Without a RepaintBoundary, none of
    // those rebuilds/repaints were isolated to just this chip's own
    // layer — they could ripple into whatever the compositor was doing
    // for neighboring widgets in the same frame, exactly the kind of
    // extra work that shows up as stutter while scrolling past this
    // strip (which sits mid-feed, injected into the same SliverList as
    // every song section). Matches the RepaintBoundary already used on
    // _SongGridCard/album cards for the same reason.
    return RepaintBoundary(
      child: AurumPressable(
      scaleAmount: 0.94,
      onTap: () => _open(context),
      child: Container(
        // SIZE BUMP ("artist box ka size toda bada kro screenshot jaisa,
        // mere mein abhi bhahut chhota" — 2026-09-07): 78/72 was a
        // corrected-DOWN pass against an earlier over-large 124px guess
        // (see the file-wide note above on _ArtistStrip) — but that
        // correction undershot against THESE reference screenshots
        // (Keep listening / Similar to X rows), where the artist circle
        // reads closer to ~100-110dp. Bumped to 104 avatar / 110 chip
        // width to match, row height in _ArtistStrip bumped alongside.
        width: 110,
        margin: const EdgeInsets.only(right: 16),
        child: Column(
          children: [
            AurumStackedArtwork(
              url: artist.imageUrl,
              size: 104,
              circular: true,
              showNowPlaying: isCurrentArtist,
              isPlaying: isActuallyPlaying,
              stackColor: AurumTheme.accentOf(context),
            ),
            const SizedBox(height: 10),
            Text(
              artist.name,
              style: TextStyle(
                color: isCurrentArtist
                    ? AurumTheme.accentOf(context)
                    : AurumTheme.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: isCurrentArtist ? FontWeight.w700 : FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Curated Playlists — Spotify-type big cards with gradient
// ─────────────────────────────────────────────────────────────────────────────

// ══════════════════════════════════════════════════════════════════
// "Playlists For You" — real YT Music playlist cards (the previous
// hand-picked query-list version, _CuratedPlaylistsSection, has been
// removed entirely — it only ever shuffled a search query per card, not
// a real playlist). Card metadata comes
// from the Worker's /api/yt-music-home route, which resolves YT Music's
// own home page shelves (browseId FEmusic_home — the same call
// music.youtube.com's website makes to render its own homepage). Cards
// stay horizontal, matching every other row on this screen; tapping one
// fetches that playlist's actual song list via the EXISTING
// fetchYtPlaylistSongs() (same function playlist-import already uses)
// and opens it in the same MixScreen every other playlist/mix row on
// this screen already uses — no new navigation destination, no
// duplicated playlist-detail UI.
// ══════════════════════════════════════════════════════════════════
// ─────────────────────────────────────────────────────────────────────────────
// REAL HOME SHELVES — "ekdam youtube music jaisa home page" (2026-09-06).
//
// WHY THIS EXISTS: _YtPlaylistsForYouSection below calls
// ApiService.fetchYtMusicHomePlaylists(), which takes every real shelf
// fetchRealHomeShelves() finds (e.g. "India's biggest hits", "New
// releases" — verified by hand via a direct FEmusic_home capture, see
// check_ytm_home.py output, 2026-09-06: both shelves came back 100%
// clean, every item had a valid browseId/kind/artwork, zero issues) and
// FLATTENS them into one shuffled pool behind a single "Playlists For
// You" header — throwing away the actual shelf grouping/titles that are
// the entire visual signature of YT Music's real home page (confirmed
// against the user's own YT Music screenshots: "Old School Romance",
// "Quick picks", "Punjabi Hits", "New releases", "Trending community
// playlists" — each its own titled row, never merged).
//
// THIS SECTION calls ApiService.fetchHomeShelvesForDisplay() — real
// FEmusic_home shelves, PLUS a personalized "Made for you" shelf (real
// on-device listening affinity, see RecommendationEngine), PLUS a
// handful of fixed seed shelves (genre/mood, same real InnerTube
// playlist search surface — see _kSeedHomeShelfQueries) so Home has more
// than the ~2 shelves anonymous FEmusic_home alone returns. Renders ONE
// CAROUSEL PER SHELF, each under its own real title — never invented/
// translated for the FEmusic_home shelves, and a genuine descriptive
// label (e.g. the artist's own name for personalized cards) for the
// seed/personalized ones — so Home visually matches YT Music's actual
// multi-shelf layout instead of one generic row. Deliberately additive:
// does not remove _YtPlaylistsForYouSection's class (kept as dead code),
// just stops it from being mounted — see the SliverToBoxAdapter call
// site in build() above for the actual swap.
// FEATURE ("You might also like" home page pr show hi nahi hota" —
// 2026-09-06): renders ApiService.fetchYouMightAlsoLike, seeded off the
// most recently played song via RecentlyPlayedProvider. Same shelf
// visual language as every other Home row (title + forward arrow to open
// the full list as a real playlist, horizontal _SongGridCard strip below)
// so it doesn't read as a bolted-on feature.
// ─────────────────────────────────────────────────────────────────────────────
// "Similar to [Artist]" — circular rows, real affinity-ranked
// ─────────────────────────────────────────────────────────────────────────────
//
// FEATURE (ArchiveTune reference, 2026-09-07): fetches a real
// InnerTube "related artists" row for each of the user's top-listened
// artists (RecommendationEngine.rotatingAffinityArtists — real
// on-device listening weight, most-played artists win, and it
// reshuffles which top artists surface on every pull-to-refresh, same
// convention _RealHomeShelvesSection's own personalized shelf already
// uses). Each row is its own header (small circular seed-artist avatar
// + "Similar to <Name>" + arrow) above a horizontal strip of cards.
//
// SHAPE ("ekdam youtube music ka structure", 2026-09-13): the row below
// the header is the SEED ARTIST'S OWN real albums (fetchSimilarArtistAlbums
// — Artist.topAlbums off that artist's own InnerTube browse page), not
// other artists' photos — matches YT Music's own "Similar to Udit
// Narayan" showing Udit Narayan's own films (Diljale, Khal Nayak) directly
// underneath. Previously this row used fetchSimilarArtistChips (renders
// OTHER related artists' circular photos instead — wrong shape for this
// screenshot); that function/its ArtistSimple-based _ArtistChip row are
// left defined elsewhere in this file (dead code) rather than deleted, in
// case a genuine "related artists" row is wanted again later. A row whose
// seed artist has no albums found (thin/obscure seed, or a pure-singles
// artist) is silently dropped rather than shown empty.
class _SimilarArtistsRow extends StatelessWidget {
  final String seedArtistName;
  final String? seedArtistImageUrl;
  final RelatedArtist? relatedArtist;
  final List<ArtistAlbum> albums;
  const _SimilarArtistsRow({
    super.key,
    required this.seedArtistName,
    required this.seedArtistImageUrl,
    required this.relatedArtist,
    required this.albums,
  });

  Future<void> _openSeedArtist(BuildContext context) async {
    AurumHaptics.selection();
    final id = await ApiService.resolveArtistId(seedArtistName);
    if (id == null || !context.mounted) return;
    AurumDepthRoute.to(
      context,
      ArtistScreen(artistId: id, artistName: seedArtistName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => _openSeedArtist(context),
                child: ClipOval(
                  child: AurumArtwork(
                    url: seedArtistImageUrl ?? '',
                    size: 44,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: () => _openSeedArtist(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Plain (non-localized) label — same precedent as
                      // _RealHomeShelfRow's hand-written strapline text
                      // above (see its own doc comment): this row's
                      // seed-artist name itself is never translatable
                      // (it's a real person's name), so the eyebrow stays
                      // English-only rather than adding one more ARB key
                      // across all 16 language files for a two-word label.
                      Text(
                        'Similar to',
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        seedArtistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _openSeedArtist(context),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.arrow_forward,
                      color: AurumTheme.textPrimaryOf(context),
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FadedHorizontalList(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 500,
              padding: const EdgeInsets.only(right: 12),
              // Related-artist chip (real InnerTube "Fans might also
              // like" data, see fetchSimilarArtistAlbums' doc comment)
              // takes slot 0 when present, matching the real reference
              // row's shape — everything after it is the seed artist's
              // own real albums.
              itemCount: albums.length + (relatedArtist != null ? 1 : 0),
              itemBuilder: (_, i) {
                if (relatedArtist != null) {
                  if (i == 0) {
                    return _RelatedArtistChipCard(
                      key: ValueKey('related_${relatedArtist!.id}'),
                      artist: relatedArtist!,
                    );
                  }
                  return _SimilarArtistAlbumCard(
                    key: ValueKey('${albums[i - 1].id}_${i - 1}'),
                    album: albums[i - 1],
                  );
                }
                return _SimilarArtistAlbumCard(
                  key: ValueKey('${albums[i].id}_$i'),
                  album: albums[i],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// One real related-artist chip inside a "Similar to X" row — circular
// photo (real InnerTube channel thumbnail, from Artist.relatedArtists,
// itself parsed straight off that artist's own browse page's real "Fans
// might also like" carousel, never guessed/derived) + name, matching the
// real reference screenshot's first card under "Similar to Udit Narayan"
// (Alka Yagnik, circular photo, tap opens her own artist page). No
// subscriber-count field exists anywhere in this app's Artist/RelatedArtist
// models (that's a YT Music web-only display detail, not something the
// InnerTube artist browse endpoint this app calls returns per-related-chip)
// — name-only under the photo, same real-data-only standard every other
// card on this row already holds to.
class _RelatedArtistChipCard extends StatelessWidget {
  final RelatedArtist artist;
  const _RelatedArtistChipCard({super.key, required this.artist});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () {
          AurumHaptics.light();
          AurumDepthRoute.to(
            context,
            ArtistScreen(artistId: artist.id, artistName: artist.name),
          );
        },
        child: Container(
          width: 148,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipOval(
                child: AurumArtwork(
                  url: artist.imageUrl,
                  size: 148,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "Similar to <song>" — ArchiveTune parity (recheck 2026-09-13, "songs ko
// bhi seed banao"): ArchiveTune's SimilarRecommendation model seeds from
// any real on-device LocalItem, Song included (see SimilarRecommendation
// .kt), not artists only. This is that Song case: header = seed song's
// own square artwork (matches ArchiveTune's own
// SimilarRecommendationsTitle — CircleShape only `if (recommendation.title
// is Artist)`, RoundedCornerShape for every other LocalItem type,
// including Song) + "Similar to <song title>", row underneath = real
// InnerTube "You might also like" results for that exact song
// (ApiService.fetchYouMightAlsoLike — same real MPTR... browse this app's
// player screen already uses, see that function's own doc comment).
// Tapping a result plays it immediately (this row's items are individual
// playable songs, not albums/artists to browse into — unlike
// _SimilarArtistsRow's album cards).
class _SimilarSongsRow extends StatelessWidget {
  final Song seedSong;
  final List<Song> related;
  const _SimilarSongsRow({
    super.key,
    required this.seedSong,
    required this.related,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: AurumArtwork(
                  url: seedSong.artworkUrl,
                  size: 44,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // Plain (non-localized) label — same precedent as
                      // _SimilarArtistsRow's own "Similar to" eyebrow
                      // above (see its doc comment): a real song title
                      // is never translatable either.
                      'Similar to',
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      seedSong.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FadedHorizontalList(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 500,
              padding: const EdgeInsets.only(right: 12),
              itemCount: related.length,
              itemBuilder: (_, i) => _SimilarSongCard(
                key: ValueKey('${related[i].id}_$i'),
                song: related[i],
                queue: related,
                index: i,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// One real playable song card inside a "Similar to <song>" row — same
// visual language (radius, shadow, sizing) as _SimilarArtistAlbumCard,
// but tapping plays the song directly (queued against the rest of this
// row's real InnerTube results) rather than navigating into an album.
class _SimilarSongCard extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SimilarSongCard({
    super.key,
    required this.song,
    required this.queue,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () {
          AurumHaptics.light();
          context.read<PlayerProvider>().playSong(
                song,
                queue: queue,
                index: index,
              );
        },
        child: Container(
          width: 148,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AurumArtwork(url: song.artworkUrl, size: 148, borderRadius: 16),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (song.artist.isNotEmpty)
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// One real album card inside a "Similar to X" row — same visual language
// (radius, shadow, sizing) as _HomeAlbumCardWidget just uses ArtistAlbum's
// shape (id/name/artworkUrl) instead of HomeAlbumCard's, since this row's
// data comes from an artist's own topAlbums, not a mood-based album fetch.
// Tapping opens AlbumScreen — same target every album card in the app
// opens, including artist_screen.dart's own album grid this mirrors.
class _SimilarArtistAlbumCard extends StatelessWidget {
  final ArtistAlbum album;
  const _SimilarArtistAlbumCard({super.key, required this.album});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () {
          AurumHaptics.light();
          AurumDepthRoute.to(
            context,
            AlbumScreen(
              albumId: album.id,
              albumName: album.name,
              artworkUrl: album.artworkUrl,
            ),
          );
        },
        child: Container(
          width: 148,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AurumArtwork(url: album.artworkUrl, size: 148, borderRadius: 16),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (album.year != null && album.year!.isNotEmpty)
                Text(
                  album.year!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Quick Picks — real InnerTube-personalized song mix (YT Music's own
// top-of-Home shelf). Seeds off the user's own most-recently-played songs
// (RecentlyPlayedProvider.history) and asks InnerTube what's related to
// each seed via fetchYouMightAlsoLike() — the same real "related" pipeline
// YT Music's own Quick Picks/Up Next is built on. Multiple seeds are
// interleaved + de-duped + quality-ranked (RecommendationEngine) so the
// result reads as a broad personalized mix, not "more like the last song".
//
// Cold-start: hydrates instantly from HomeFeedCache.loadQuickPicks() (same
// "show last session's result now, refresh quietly after" contract as every
// other Home row) and only fires a real fetch when there's no cache yet or
// the 6-hour freshness window has lapsed. Pull-to-refresh: every pull does
// a zero-network local pool reshuffle (_rotateFromPool) — it self-escalates
// to a real fetch only if the pool's too small to meaningfully reshuffle.
class _QuickPicksSection extends StatefulWidget {
  final int refreshKey;
  const _QuickPicksSection({this.refreshKey = 0});

  @override
  State<_QuickPicksSection> createState() => _QuickPicksSectionState();
}

class _QuickPicksSectionState extends State<_QuickPicksSection> {
  List<Song>? _songs;
  bool _failed = false;
  // Full ranked pool from the last real fetch (up to poolCap songs, not
  // just the _kMaxShown shown at once) — kept around so a light refresh
  // can pull a different genuinely-ranked slice/order out of real data
  // already fetched, instead of needing a new network call just to look
  // different on screen.
  List<Song> _pool = const [];

  // Cap how many seed songs we fan out to InnerTube for — each seed is a
  // full network round-trip (fetchYouMightAlsoLike), so this bounds worst-
  // case latency/parallel requests the same way _SimilarArtistsSection caps
  // its own seed count at 3.
  static const int _kSeedCount = 3;
  // 6 columns of 4 rows each (24 songs) so a real 5-6 swipe horizontal
  // scroll ("5-6 baar swipe karne pr 4-4 songs aaye") always has enough
  // InnerTube-ranked pool to fill every column — 15 only covered ~4
  // columns before running out.
  static const int _kMaxShown = 24;

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
  }

  Future<void> _hydrateFromCache() async {
    final cached = await HomeFeedCache.loadQuickPicks();
    if (!mounted) return;
    if (cached.isNotEmpty) {
      setState(() {
        _songs = cached.take(_kMaxShown).toList();
        // The disk cache now holds the FULL pool (see saveQuickPicks'
        // doc comment) — restoring it here means a light pull-to-refresh
        // can reshuffle real cached songs immediately, even before any
        // real fetch has run this session.
        _pool = cached;
      });
      // Still refresh quietly in the background once the cache has aged
      // out, same "instant paint, silent refresh" contract as every other
      // Home row — never re-shows a loading state over already-visible
      // content.
      if (!await HomeFeedCache.isQuickPicksFresh()) _load(silent: true);
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(_QuickPicksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pull-to-refresh bumps refreshKey — rotate Quick Picks along with
    // every other section rather than leaving it frozen from cold start.
    // STAGED REFRESH (2026-09-15): Quick Picks is due on EVERY pull in
    // the 1-10 cycle (the cheapest section — see RefreshStage's doc
    // comment in home_feed_cache.dart), so this always reshuffles;
    // _rotateFromPool itself already self-escalates to a real fetch only
    // when the pool's too small to meaningfully reshuffle (see its own
    // doc comment), so no separate "full vs light" flag is needed here.
    if (oldWidget.refreshKey != widget.refreshKey) {
      _rotateFromPool();
    }
  }

  // LIGHT REFRESH — zero network. Reshuffles the already-fetched ranked
  // pool (_pool, up to 4x _kMaxShown from the last real fetch) into a
  // different genuinely-ranked slice, so the row visibly changes on a
  // normal pull-to-refresh without a new fetchYouMightAlsoLike round-trip.
  // Falls back to a real fetch only if there's no pool yet at all (e.g.
  // this session's very first load somehow never populated one) so the
  // row never just does nothing on a refresh.
  void _rotateFromPool() {
    if (_pool.length <= _kMaxShown) {
      // Nothing meaningfully different to slice out of a pool this
      // small — a real fetch is the only way to actually look different.
      _load(silent: true);
      return;
    }
    // BUG FIX (recheck, 2026-09-15): this used to save only the shown
    // 24-song slice back to disk, which silently shrank the persisted
    // pool down to exactly _kMaxShown — the NEXT light refresh (even
    // next app session) would then always fail the length check above
    // and fall back to a real fetch every time, quietly defeating the
    // whole point of a network-free reshuffle after the very first one.
    // Reshuffling _pool itself (not just slicing a display-copy of it)
    // and persisting the FULL reshuffled pool keeps every future light
    // refresh able to reshuffle for real, indefinitely.
    _pool = List<Song>.from(_pool)..shuffle(math.Random(widget.refreshKey));
    final next = _pool.take(_kMaxShown).toList();
    if (!mounted) return;
    setState(() => _songs = next);
    unawaited(HomeFeedCache.saveQuickPicks(_pool));
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _failed = false);
    try {
      // Real recent history, most-recent first — same source
      // _YouMightAlsoLikeSection already trusts for its own single seed.
      final history =
          context.read<RecentlyPlayedProvider>().history.take(_kSeedCount);
      final seedIds = history
          .map((s) => s.id)
          .where((id) => id.isNotEmpty)
          .toSet() // de-dupe seeds themselves before fanning out
          .toList();

      if (seedIds.isEmpty) {
        // No listening history yet (fresh install / library-only user) —
        // nothing real to personalize off. Stays hidden rather than
        // showing an unrelated/generic list under a "Quick picks" label,
        // same rule _YouMightAlsoLikeSection already follows.
        if (mounted) setState(() { _songs = silent ? _songs : const []; _failed = !silent; });
        return;
      }

      final results = await Future.wait(
        seedIds.map((id) => ApiService.fetchYouMightAlsoLike(id)
            .catchError((_) => const <Song>[])),
      );

      // QUALITY FIX ("ekdam top garde level ka... har baar great songs
      // aaye" — 2026-09-13): this used to interleave the raw seed
      // results in whatever order InnerTube happened to return them —
      // no quality/relevance filtering at all, so a low-quality upload
      // or a barely-related result could land in the very first row just
      // because it appeared early in one seed's list. Two real fixes:
      //   1. isNonMusicContent strips junk (vlogs, label-channel
      //      reuploads, non-music content) before it ever gets a chance
      //      to appear — same filter rankAndFilter already trusts for
      //      the Up Next queue.
      //   2. Pool size raised to 4x _kMaxShown (was capped at exactly
      //      _kMaxShown while interleaving) so RecommendationEngine.
      //      scoreCandidate — genuine artist/genre/language affinity +
      //      completion-rate/replay/skip signals from real listening
      //      history — has an actual pool to RANK instead of just a
      //      round-robin merge with nothing left to choose between.
      //      currentSong is intentionally omitted (Quick Picks has no
      //      single "now playing" reference song, unlike Up Next) — the
      //      era-match term simply no-ops in that case and every other
      //      term (taste affinity, mood/genre session match, completion/
      //      replay/skip history) still applies fully.
      final poolCap = _kMaxShown * 4;
      final seen = <String>{};
      final pool = <Song>[];
      var idx = 0;
      while (pool.length < poolCap) {
        var addedThisRound = false;
        for (final list in results) {
          if (idx >= list.length) continue;
          final s = list[idx];
          if (s.id.isEmpty || !seen.add(s.id)) continue;
          if (RecommendationEngine.isNonMusicContent(s)) continue;
          pool.add(s);
          addedThisRound = true;
          if (pool.length >= poolCap) break;
        }
        if (!addedThisRound) break; // every seed list exhausted
        idx++;
      }

      // Stable-sort by genuine taste/quality score, highest first — ties
      // (e.g. two songs InnerTube considers equally related) keep their
      // original interleaved order rather than an arbitrary one, since
      // List.sort in Dart is not guaranteed stable but the score itself
      // already varies enough in practice that visible re-shuffling of
      // true ties is not a concern here.
      pool.sort((a, b) => RecommendationEngine.scoreCandidate(a)
          .compareTo(RecommendationEngine.scoreCandidate(b)));
      final merged = pool.reversed.take(_kMaxShown).toList();

      if (!mounted) return;
      if (merged.isEmpty) {
        setState(() { if (!silent) _failed = true; });
        return;
      }
      final fullPool = pool.reversed.toList();
      // Persist the FULL pool (not just the shown _kMaxShown) — see
      // HomeFeedCache.saveQuickPicks' own doc comment — so a light
      // pull-to-refresh after a fresh cold start (no real fetch needed
      // yet, since the disk cache was still fresh) can still reshuffle
      // real cached songs immediately instead of falling back to a
      // network call for lack of anything to reshuffle from.
      unawaited(HomeFeedCache.saveQuickPicks(fullPool));
      setState(() {
        _songs = merged;
        _failed = false;
        // Keep the FULL ranked pool (not just the shown _kMaxShown) —
        // _rotateFromPool() reshuffles this on a light pull-to-refresh
        // instead of hitting the network again.
        _pool = fullPool;
      });
    } catch (_) {
      if (mounted && !silent) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs;

    // Loading (first paint, nothing cached yet) — plain title skeleton +
    // a handful of row placeholders, same "quiet skeleton" language every
    // other Home section already uses.
    if (songs == null && !_failed) {
      return Padding(
        padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ShelfTitleSkeleton(),
            const SizedBox(height: 14),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: AurumTheme.bgCardOf(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 14,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: AurumTheme.bgCardOf(context),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            height: 12,
                            width: 140,
                            decoration: BoxDecoration(
                              color: AurumTheme.bgCardOf(context),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    // No listening history to personalize off, or InnerTube genuinely
    // found nothing related — skip the whole section rather than showing
    // an empty (or fake) "Quick picks" row.
    if (songs == null || songs.isEmpty) {
      return const SizedBox.shrink();
    }

    // REDESIGN ("ekdam youtube jaisa side scroll rahe 4 4 ke category
    // mein" — 2026-09-13): real music.youtube.com's own Quick Picks is a
    // HORIZONTAL carousel of columns — each column stacks 4 rows
    // vertically (small square art + title/subtitle + 3-dot menu, same
    // row shape as before), and the whole block scrolls sideways one
    // column-of-4 at a time, peeking the next column's edge — not one
    // single full-width vertical list. _QuickPickListRow itself is
    // unchanged; only the layout wrapping it changed from a flat Column
    // to a horizontal ListView of 4-row columns.
    const rowsPerColumn = 4;
    final columnCount = (songs.length / rowsPerColumn).ceil();

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 0, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              AppLocalizations.of(context)!.homeQuickPicks,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // FIX ("swipe krne pr ek sath ho rahe hai" — 2026-09-13): this
          // used to be a plain ListView.builder (free-scroll,
          // BouncingScrollPhysics) — a fling could carry past several
          // columns at once and settle at any arbitrary scroll offset, not
          // on a column boundary, which is what read as multiple columns
          // moving "together"/unpredictably per swipe. Real YT Music's
          // Quick Picks carousel snaps exactly one column per swipe no
          // matter how hard the flick is. PageView.builder gives that for
          // free (each "page" here being one column-of-4, viewportFraction
          // slightly under 1 so the next column's edge still peeks, same
          // as before) — every swipe lands on exactly the next/previous
          // column, never in between and never skipping one.
          SizedBox(
            height: 68.0 * rowsPerColumn,
            child: PageView.builder(
              controller: PageController(
                viewportFraction:
                    (MediaQuery.of(context).size.width - 24) /
                        MediaQuery.of(context).size.width,
              ),
              physics: const PageScrollPhysics(),
              padEnds: false,
              itemCount: columnCount,
              itemBuilder: (_, colIndex) {
                final start = colIndex * rowsPerColumn;
                final end = (start + rowsPerColumn).clamp(0, songs.length);
                return Container(
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = start; i < end; i++)
                        _QuickPickListRow(
                          key: ValueKey(
                              'quickpick_${songs[i].id}_${widget.refreshKey}'),
                          song: songs[i],
                          queue: songs,
                          index: i,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// One Quick Picks / Trending-songs-for-you row — small square art (left)
// + title/subtitle stacked (right) + a 3-dot overflow affordance, full
// width, one row per line — matches the real reference screenshots
// exactly (previously this was mistakenly built as a 2-column grid;
// corrected here). A currently-playing row gets a subtle highlighted
// background, same as the real app's own "now playing" row treatment.
class _QuickPickListRow extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _QuickPickListRow({
    super.key,
    required this.song,
    required this.queue,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == song.id,
    );
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: isPlaying
              ? AurumTheme.accentOf(context).withOpacity(0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () {
              AurumHaptics.selection();
              context
                  .read<PlayerProvider>()
                  .playSong(song, queue: queue, index: index);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: AurumArtwork(
                        url: song.artworkUrl, size: 52, borderRadius: 0),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isPlaying
                                ? AurumTheme.accentOf(context)
                                : AurumTheme.textPrimaryOf(context),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.more_vert,
                    size: 20,
                    color: AurumTheme.textMutedOf(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Entry card into the full real "Moods & Genres" grid screen — tap opens
// MoodsGenresScreen (ApiService.fetchMoodsAndGenres, real InnerTube
// FEmusic_moods_and_genres browse, see that screen's own doc header).
// NOTE: the actual entry-card widget this comment describes
// (_MoodsGenresEntryCard) was dead code (never mounted) and has been
// removed — MoodsGenresScreen is still reachable via the real shelf
// rows' own "see all" arrow below, same destination either way.
class _HomeShelvesAndSimilarSection extends StatefulWidget {
  final int refreshKey;
  // STAGED REFRESH (2026-09-15): tells this section which of its three
  // internal pieces (shelves / similar-artist rows / similar-song rows)
  // are actually due a real network fetch on THIS pull — see
  // RefreshStage's doc comment in home_feed_cache.dart for the 1-10 ramp.
  // Defaults to quick-picks-only-equivalent (nothing here due) so cold
  // start / non-refresh rebuilds never accidentally force a fetch through
  // this prop — cold start's own _hydrateFromCache path is unaffected by
  // this and decides its own fetches independently via cache freshness.
  final RefreshStage stage;
  const _HomeShelvesAndSimilarSection({
    this.refreshKey = 0,
    this.stage = const RefreshStage(
      quickPicks: true,
      shelves: false,
      similarArtistRows: false,
      similarSongRows: false,
    ),
  });

  @override
  State<_HomeShelvesAndSimilarSection> createState() =>
      _HomeShelvesAndSimilarSectionState();
}

class _HomeShelvesAndSimilarSectionState
    extends State<_HomeShelvesAndSimilarSection> {
  List<HomeShelf>? _shelves;
  List<({String artistName, String? artistImageUrl, RelatedArtist? relatedArtist, List<ArtistAlbum> albums})>? _similarRows;
  List<({Song seedSong, List<Song> related})>? _similarSongRows;
  bool _shelvesFailed = false;

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
  }

  // ADDED ("MB kam use ho... koi feature cut na ho" — 2026-09-14, extended
  // to real shelves too — "poora home page reopen pe shimmer karta hai" —
  // 2026-09-15): paints last session's real shelves/similar-artist/
  // similar-song rows instantly from disk (HomeFeedCache.loadHomeShelves/
  // loadSimilarArtistRows/loadSimilarSongRows — see those functions' own
  // doc comments) instead of unconditionally re-fetching from the network
  // on every cold start, exactly the same "instant paint, silent
  // background refresh" contract _QuickPicksSection's _hydrateFromCache
  // already uses. If nothing is cached yet (first ever launch), falls
  // straight through to a normal full _load().
  Future<void> _hydrateFromCache() async {
    final cachedShelves = await HomeFeedCache.loadHomeShelves();
    final cachedSimilar = await HomeFeedCache.loadSimilarArtistRows();
    final cachedSimilarSongs = await HomeFeedCache.loadSimilarSongRows();
    if (!mounted) return;
    if (cachedShelves.isNotEmpty ||
        cachedSimilar.isNotEmpty ||
        cachedSimilarSongs.isNotEmpty) {
      setState(() {
        if (cachedShelves.isNotEmpty) _shelves = cachedShelves;
        if (cachedSimilar.isNotEmpty) _similarRows = cachedSimilar;
        if (cachedSimilarSongs.isNotEmpty) _similarSongRows = cachedSimilarSongs;
      });
    }
    // FIX ("poora home page reopen pe shimmer karta hai" — 2026-09-15):
    // real shelves now follow the exact same disk-cache contract as
    // similar rows/quick picks/artists — instant paint above, then a
    // real fetch only when there's no cache yet or it's aged past the
    // 6-hour freshness window (skipShelves below), instead of always
    // fetching on every single cold start regardless of how recent the
    // last real fetch was.
    final shelvesCacheFresh = await HomeFeedCache.isHomeShelvesFresh();
    final artistCacheFresh = await HomeFeedCache.isSimilarArtistRowsFresh();
    final songCacheFresh = await HomeFeedCache.isSimilarSongRowsFresh();
    final shelvesFresh = cachedShelves.isNotEmpty && shelvesCacheFresh;
    final similarFresh = cachedSimilar.isNotEmpty && artistCacheFresh;
    final similarSongsFresh = cachedSimilarSongs.isNotEmpty && songCacheFresh;
    // skipShelves/skipSimilar/skipSimilarSongs tell _load() not to
    // re-fetch whichever ones are already fresh on disk — the actual
    // MB/latency saving. When a flag is false (no cache yet, or aged
    // past the 6-hour window), _load() fetches that one exactly as it
    // always did. A manual pull-to-refresh (didUpdateWidget below) now
    // computes its OWN skip flags from widget.stage (RefreshStage) instead
    // of always forcing all three — see the STAGED REFRESH comment there.
    if (shelvesFresh && similarFresh && similarSongsFresh) return;
    _load(
      skipShelves: shelvesFresh,
      skipSimilar: similarFresh,
      skipSimilarSongs: similarSongsFresh,
    );
  }

  @override
  void didUpdateWidget(_HomeShelvesAndSimilarSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FIX ("refresh krta hu to sb section gayab ho ja rahe hai aur dubara
    // aa hi nhi rahe" — 2026-09-14): this used to null out _shelves/
    // _similarRows/_similarSongRows IMMEDIATELY on every refresh, before
    // the new fetch even started. That's fine while the new fetch is
    // fast and succeeds — but if the refreshed fetch comes back empty or
    // throws (a single slow/rate-limited/failed network call is enough),
    // _load() below sets _shelvesFailed = true (or leaves _similarRows/
    // _similarSongRows as empty lists) and build() renders
    // SizedBox.shrink() — the ENTIRE section vanishes, even though it had
    // perfectly good real content on screen one refresh ago. Worse, that
    // empty state doesn't self-heal: it stays gone until the NEXT
    // successful refresh, since nothing here ever restores the old data.
    // Same "instant paint from what's already there, silent refetch
    // underneath" contract _QuickPicksSection already uses (see its own
    // _hydrateFromCache/_load(silent: true)) — just don't clear anything
    // here; _load() below now only overwrites each field when the
    // refreshed fetch for it actually produced something.
    if (oldWidget.refreshKey != widget.refreshKey) {
      // STAGED REFRESH (2026-09-15): a manual pull-to-refresh used to
      // ALWAYS force a real fetch for all three pieces here — that's the
      // exact all-at-once network/MB/heat spike the staged rollout exists
      // to remove. Now each piece only re-fetches when widget.stage says
      // it's due on this specific pull; a piece not yet due this cycle
      // simply keeps showing whatever it already has on screen (same
      // "never clear, only overwrite on real new data" contract this
      // section's _load already follows for failures — see the FIX
      // comment above didUpdateWidget).
      _load(
        refreshKey: widget.refreshKey,
        skipShelves: !widget.stage.shelves,
        skipSimilar: !widget.stage.similarArtistRows,
        skipSimilarSongs: !widget.stage.similarSongRows,
      );
    }
  }

  Future<void> _load({
    int? refreshKey,
    bool skipShelves = false,
    bool skipSimilar = false,
    bool skipSimilarSongs = false,
  }) async {
    // FIX (recheck, 2026-09-07): shelves used to setState as soon as
    // they resolved, then similar-artist rows setState again moments
    // later once THEY resolved — since both are interleaved into one
    // list, that meant Home visibly painted shelves-only first, then
    // every shelf below the first similar-artist row jumped down a
    // slot as that row got inserted. Both futures still start
    // concurrently (no added latency), but now committed to state
    // together in one setState — Home goes straight from skeleton to
    // its final interleaved order, no mid-scroll layout shift.
    final seed = refreshKey ?? widget.refreshKey;
    // MB FIX ("MB kam use ho, koi feature cut na ho" — 2026-09-14, and
    // "poora home page reopen pe shimmer karta hai" — 2026-09-15): a
    // fresh HomeFeedCache copy (checked by the caller — _hydrateFromCache
    // on cold start) means the exact same real network fetch would just
    // be re-requesting data that's already sitting on disk from
    // minutes/hours ago. Skipping it here saves that round-trip and its
    // artwork downloads entirely — nothing about WHAT gets shown changes,
    // only whether it's fetched again unnecessarily. A manual
    // pull-to-refresh (didUpdateWidget above) now sets these per-piece
    // from widget.stage (RefreshStage) instead of always leaving all
    // three false — see the STAGED REFRESH comment there.
    final shelvesFuture =
        skipShelves ? null : ApiService.fetchHomeShelvesForDisplay(
      refreshSeed: seed,
    );
    final similarFuture = skipSimilar ? null : _loadSimilarRows();
    final similarSongsFuture =
        skipSimilarSongs ? null : _loadSimilarSongRows();

    List<HomeShelf>? shelves;
    bool failed = false;
    if (shelvesFuture != null) {
      try {
        shelves = await shelvesFuture;
        failed = shelves.isEmpty;
      } catch (_) {
        shelves = const [];
        failed = true;
      }
    }
    final similar = similarFuture == null ? null : await similarFuture;
    final similarSongs =
        similarSongsFuture == null ? null : await similarSongsFuture;

    if (!mounted) return;
    setState(() {
      // shelves is null when this fetch was skipped (fresh cache already
      // hydrated _shelves in _hydrateFromCache) — leave whatever's
      // already in state alone in that case. Only overwrite when this
      // refresh actually produced something (or genuinely came back
      // empty on a first load, same as before).
      if (shelves != null && (shelves.isNotEmpty || _shelves == null)) {
        _shelves = shelves;
        _shelvesFailed = failed;
      }
      // similar/similarSongs are null when that fetch was skipped
      // (fresh cache already hydrated _similarRows/_similarSongRows in
      // _hydrateFromCache) — leave whatever's already in state alone in
      // that case rather than treating "skipped" the same as "fetched
      // and came back empty".
      if (similar != null && (similar.isNotEmpty || _similarRows == null)) {
        _similarRows = similar;
      }
      if (similarSongs != null &&
          (similarSongs.isNotEmpty || _similarSongRows == null)) {
        _similarSongRows = similarSongs;
      }
    });

    // Persist real fetched results to disk so the NEXT cold start can
    // paint instantly instead of re-fetching (see HomeFeedCache.
    // saveHomeShelves/saveSimilarArtistRows/saveSimilarSongRows' own doc
    // comments). Only saves when this call actually fetched fresh data —
    // a skipped fetch has nothing new to save, and all three save
    // functions already no-op on an empty list.
    if (shelves != null) {
      unawaited(HomeFeedCache.saveHomeShelves(shelves));
    }
    if (similar != null) {
      unawaited(HomeFeedCache.saveSimilarArtistRows(similar));
    }
    if (similarSongs != null) {
      unawaited(HomeFeedCache.saveSimilarSongRows(similarSongs));
    }
  }


  Future<List<({String artistName, String? artistImageUrl, RelatedArtist? relatedArtist, List<ArtistAlbum> albums})>>
      _loadSimilarRows() async {
    try {
      // FIX (recheck — "artist wala section show kyu nahi hota" —
      // 2026-09-13): this used to call rotatingAffinityArtists() straight
      // away without ever awaiting RecommendationEngine.load() itself.
      // RecommendationEngine._loaded only flips true once something else
      // (RecentlyPlayedProvider/PlayerProvider's own startup load()) has
      // finished — if Home built before that finished, _loaded was still
      // false at this exact call, so rotatingAffinityArtists() hit its
      // own `if (!_loaded) return [];` guard and this row silently never
      // showed for that screen instance (no retry short of a refreshKey
      // change). load() is idempotent (already called this way from
      // several other real call sites in api_service.dart/player_provider
      // .dart), so awaiting it here just guarantees real on-device
      // affinity data is actually loaded before it's read — no fake data,
      // no invented fallback, just fixing the race so the real data that
      // already exists on-device gets seen.
      await RecommendationEngine.load();
      final seedArtists = RecommendationEngine.rotatingAffinityArtists(
        count: 3,
        seed: widget.refreshKey,
      );
      if (seedArtists.isEmpty) return const [];
      // FIX ("similar to artist wala section refresh pe automatically
      // gayab ho ja raha hai" — 2026-09-14): Future.wait is fail-fast by
      // default — if ANY single one of the 3 parallel
      // fetchSimilarArtistAlbums calls throws an uncaught error (a
      // connection drop or reset mid-request on a weak/slow network,
      // distinct from a clean timeout or a normal "not found" which
      // fetchSimilarArtistAlbums already catches internally and turns
      // into a null return), Future.wait rejects immediately and this
      // function's own outer try/catch below discards ALL 3 results —
      // including the other 1-2 that had already resolved successfully
      // — returning const [] for the whole row set. _QuickPicksSection's
      // near-identical Future.wait (see its own seedIds.map call site
      // above) already guards each future individually with
      // .catchError((_) => ...) for exactly this reason; this one never
      // got the same treatment. Same fix here: each artist's fetch now
      // independently catches its own error and resolves to null rather
      // than being able to reject the shared Future.wait, so one flaky
      // lookup can never take down rows that already succeeded.
      Future<({String artistName, String? artistImageUrl, RelatedArtist? relatedArtist, List<ArtistAlbum> albums})?>
          fetchOne(String artist) async {
        try {
          return await ApiService.fetchSimilarArtistAlbums(artist);
        } catch (_) {
          return null;
        }
      }
      final results = await Future.wait(seedArtists.map(fetchOne));
      return results.where((r) => r != null).map((r) => r!).toList();
    } catch (_) {
      return const [];
    }
  }

  // ADDED (ArchiveTune parity, recheck 2026-09-13 — "songs ko bhi seed
  // banao"): ArchiveTune's own SimilarRecommendation model seeds from
  // ANY real LocalItem (its on-device history entity — Song, Album, or
  // Artist), not artists only (see SimilarRecommendation.kt: `title:
  // LocalItem, items: List<YTItem>`). This mirrors that for the Song
  // case — seeds come from RecentlyPlayedProvider.history (the exact
  // same real on-device play-history list _SpeedDialSection used to
  // read), and each seed's row is fetched via fetchYouMightAlsoLike,
  // this app's own real InnerTube per-song "You might also like"
  // (verified two-step next->Related tab->MPTR... browse — see that
  // function's own doc comment above _fetchRelatedBrowseId; the exact
  // real endpoint YT Music itself uses for this). Local-file songs
  // (song.isLocal) are skipped — they have no YouTube videoId, so this
  // endpoint has nothing real to query for them; never a fake stand-in.
  // Rotates which 2 recent songs get used the same way
  // rotatingAffinityArtists rotates artists (seeded by refreshKey), so
  // pull-to-refresh varies this too instead of freezing on the same
  // pair.
  Future<List<({Song seedSong, List<Song> related})>> _loadSimilarSongRows() async {
    try {
      final history = context.read<RecentlyPlayedProvider>().history;
      final streamable = <Song>[];
      final seenIds = <String>{};
      for (final s in history) {
        if (s.isLocal || s.id.isEmpty) continue;
        if (!seenIds.add(s.id)) continue;
        streamable.add(s);
      }
      if (streamable.isEmpty) return const [];
      // Same "wider pool, shuffle with refreshKey, take N" rotation
      // shape as rotatingAffinityArtists — real recent songs only,
      // never invented, just which ones surface this pull varies.
      final pool = streamable.take(10).toList()
        ..shuffle(math.Random(widget.refreshKey));
      final seeds = pool.take(2).toList();

      // FIX (same class as _loadSimilarRows' fix above — "similar to X
      // rows disappearing on refresh"): the .timeout() here only covers
      // a SLOW response; a genuine thrown error (connection reset mid-
      // request, DNS failure) inside this async block was still
      // uncaught, so it could still reject the whole Future.wait and
      // wipe out the other seed's already-successful result via the
      // outer try/catch below. Each seed's own future now independently
      // catches its own error and falls back to an empty related-list
      // for just that seed, rather than being able to reject the shared
      // Future.wait — one flaky lookup can no longer take the other
      // seed's already-successful result down with it.
      Future<({Song seedSong, List<Song> related})> fetchOne(Song song) async {
        try {
          final related = await ApiService.fetchYouMightAlsoLike(song.id)
              .timeout(const Duration(seconds: 8), onTimeout: () => const <Song>[]);
          return (seedSong: song, related: related);
        } catch (_) {
          return (seedSong: song, related: const <Song>[]);
        }
      }
      final results = await Future.wait(seeds.map(fetchOne));
      return results.where((r) => r.related.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelves = _shelves;

    // Still loading shelves (first paint) — same skeleton language as
    // before.
    if (shelves == null && !_shelvesFailed) {
      return Padding(
        padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ShelfTitleSkeleton(),
            const SizedBox(height: 12),
            // Height matched to _RealHomeShelfRow's actual card height
            // (172, see that row's own FadedHorizontalList) — this used
            // to borrow _YtPlaylistsForYouSkeleton's 130px placeholder,
            // which caused a visible layout jump (shelf grows 130->172)
            // the instant real shelves resolved.
            FadedHorizontalList(
              height: 172,
              child: const _YtPlaylistsForYouSkeleton(),
            ),
          ],
        ),
      );
    }

    if (shelves == null || shelves.isEmpty) {
      // FIX ("similar to X rows disappearing when remote shelves fail" —
      // 2026-09-13): this used to return SizedBox.shrink() here
      // unconditionally, which hid the ENTIRE section — including any
      // already-loaded Similar Recommendations rows — just because the
      // separate real-shelves fetch came back empty/failed. ArchiveTune
      // treats these as two independent loops (`similarRecommendations
      // .forEach` and `homePage.sections.forEachIndexed`), so one being
      // empty never affects the other. Falls through to the render path
      // below instead, which already handles an empty shelves list fine.
      if ((_similarRows ?? const []).isEmpty &&
          (_similarSongRows ?? const []).isEmpty) {
        return const SizedBox.shrink();
      }
    }

    final similar = _similarRows ?? const [];
    final similarSongs = _similarSongRows ?? const [];
    final realShelves = shelves ?? const [];

    // ARCHIVETUNE ORDER MATCH ("category aur artist ekdam ArchiveTune
    // jaisa" — 2026-09-13): this used to alternate one shelf then one
    // similar-artist row (an interleave loop) — ArchiveTune's own
    // HomeScreen.kt never does that. It runs
    // `uiState.similarRecommendations.forEach { ... }` as one complete,
    // separate loop FIRST, then `uiState.homePage.sections.forEachIndexed
    // { ... }` as its own complete loop AFTER — i.e. every "Similar to X"
    // row together, then every real remote shelf together, never mixed.
    // Reordered here to match that exactly: all similar-artist rows
    // render first, then all real shelves. Song-seeded rows are the
    // same kind of "Similar to X" row ArchiveTune's own single
    // similarRecommendations loop already covers (its LocalItem seed can
    // be a Song too) — grouped into that same first block, artist rows
    // then song rows, never interleaved with the remote shelves after.
    final children = <Widget>[
      for (final row in similar)
        _SimilarArtistsRow(
          key: ValueKey('${row.artistName}_${widget.refreshKey}'),
          seedArtistName: row.artistName,
          seedArtistImageUrl: row.artistImageUrl,
          relatedArtist: row.relatedArtist,
          albums: row.albums,
        ),
      for (final row in similarSongs)
        _SimilarSongsRow(
          key: ValueKey('${row.seedSong.id}_${widget.refreshKey}'),
          seedSong: row.seedSong,
          related: row.related,
        ),
      for (final shelf in realShelves)
        _RealHomeShelfRow(
          key: ValueKey('${shelf.title}_${widget.refreshKey}'),
          shelf: shelf,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _ShelfTitleSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      height: 20,
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

// One real shelf ("New releases", "India's biggest hits", etc.) as its
// own titled horizontal row — real title straight from InnerTube, real
// cards (album -> AlbumScreen, playlist -> lazy-resolved MixScreen).
class _RealHomeShelfRow extends StatelessWidget {
  final HomeShelf shelf;
  const _RealHomeShelfRow({super.key, required this.shelf});

  // REVERT ("Featured playlist for you wale arrow se moods aur genres
  // khulna chahiye" — 2026-09-07): removed this special case in the
  // previous pass because the confusion at the time was about the
  // standalone Moods & Genres ENTRY CARD sitting awkwardly at the top
  // of Home (a separate widget, _MoodsGenresEntryCard, already removed
  // — see its own doc comment) — not about this arrow. Restoring the
  // arrow -> Moods & Genres behavior: this is the deliberate one
  // exception to the generic see-all arrow every other shelf uses.
  static const String _kFeaturedForYouTitle = 'Featured playlists for you';

  void _openArrow(BuildContext context) {
    AurumHaptics.selection();
    if (shelf.title == _kFeaturedForYouTitle) {
      AurumDepthRoute.to(context, const MoodsGenresScreen());
    } else {
      AurumDepthRoute.to(context, _ShelfSeeAllScreen(shelf: shelf));
    }
  }

  @override
  Widget build(BuildContext context) {
    // "Featured playlists for you" always shows its arrow (3 items,
    // wouldn't otherwise clear the >4 threshold below) since its arrow
    // goes to Mood & Genres rather than a see-all of its own 3 items —
    // every other shelf keeps the existing "only show when there's
    // enough to actually see more of" rule. List-style shelves have no
    // see-all destination of their own yet, so they never show the arrow.
    final showArrow = !shelf.isList &&
        (shelf.title == _kFeaturedForYouTitle || shelf.items.length > 4);
    // FEATURE ("ekdam youtube music jaisa" — 2026-09-13): real InnerTube
    // list-style shelves (e.g. "Covers and remixes") render as a flat
    // vertical stack of playable rows with a "Play all" pill in the
    // header instead of the horizontal card carousel every other shelf
    // uses — see HomeShelf.isList's doc comment for why the two shapes
    // exist and how they're told apart at parse time.
    if (shelf.isList) {
      return Padding(
        padding: const EdgeInsets.only(top: 32, left: 12, right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 4,
                        height: 18,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          gradient: AurumTheme.accentGradientOf(context),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          shelf.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (shelf.songs.isNotEmpty)
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        AurumHaptics.selection();
                        context.read<PlayerProvider>().playSong(
                              shelf.songs.first,
                              queue: shelf.songs,
                              index: 0,
                            );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AurumTheme.dividerOf(context),
                            width: 0.8,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded,
                                size: 18,
                                color: AurumTheme.textPrimaryOf(context)),
                            const SizedBox(width: 4),
                            Text(
                              'Play all',
                              style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < shelf.songs.length; i++)
              _QuickPickListRow(
                key: ValueKey('${shelf.title}_shelf_${shelf.songs[i].id}_$i'),
                song: shelf.songs[i],
                queue: shelf.songs,
                index: i,
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 32, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FEATURE ("ekdam youtube music jaisa" eyebrow+title
                    // header — 2026-09-06): when InnerTube's own response
                    // carries a strapline for this shelf (see
                    // HomeShelf.strapline's doc comment — genuinely
                    // present on some mood/genre carousels, e.g.
                    // "BACKGROUND SCORE TO YOUR LOVE STORY" above
                    // "Romance Right Now"), show it as the small-caps
                    // eyebrow line YT Music itself renders above the bold
                    // shelf title. Shelves with no strapline (e.g. "New
                    // releases") render exactly as before — single-line
                    // title, nothing invented.
                    if (shelf.strapline != null) ...[
                      Text(
                        shelf.strapline!.toUpperCase(),
                        style: TextStyle(
                          color: AurumTheme.accentLightOf(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    // PREMIUM UPGRADE — small gradient accent tick before
                    // the title, matches the app-bar "Astra" wordmark's
                    // gradient language so every shelf feels branded
                    // rather than a generic list header. Title bumped
                    // 17->19 and weight 700->800 for stronger editorial
                    // presence ("ekdam masterpiece" ask).
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 4,
                          height: 18,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            gradient: AurumTheme.accentGradientOf(context),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            shelf.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (showArrow)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => _openArrow(context),
                    // FIX ("See all" arrow icon — ArchiveTune reference,
                    // 2026-09-07): reference screenshots show a plain
                    // right-arrow icon next to shelf titles (e.g. next to
                    // "Similar to Chill77"/"New releases"), not a text
                    // button — swapped from the text "See all" label to
                    // match, tap target/behavior unchanged.
                    // PREMIUM UPGRADE — wrapped in a soft glass pill so the
                    // arrow reads as a tappable chip rather than a bare
                    // floating icon, matching the glass/gradient language
                    // used elsewhere in the redesign.
                    child: Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AurumTheme.bgCardOf(context).withOpacity(0.6),
                        border: Border.all(
                          color: AurumTheme.dividerOf(context),
                          width: 0.6,
                        ),
                      ),
                      child: Icon(
                        Icons.arrow_forward,
                        color: AurumTheme.textPrimaryOf(context),
                        size: 18,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          FadedHorizontalList(
            // Bumped alongside _RealShelfPlaylistCard's width increase
            // (148 card + a little breathing room) — "cards ko toda sa
            // bada kro" — 2026-09-07.
            height: 172,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              cacheExtent: 600,
              padding: const EdgeInsets.only(right: 12),
              itemCount: shelf.items.length,
              itemBuilder: (_, i) {
                final item = shelf.items[i];
                if (item.isAlbum) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _HomeAlbumCardWidget(
                      card: HomeAlbumCard(
                        albumId: item.browseId,
                        title: item.title,
                        artist: item.subtitle,
                        artworkUrl: item.artworkUrl,
                      ),
                    ),
                  );
                }
                return _RealShelfPlaylistCard(item: item, shelfTitle: shelf.title);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Playlist card from a real shelf — visually identical to
// _YtHomePlaylistCardWidget, but resolves its song list lazily on tap
// (via ApiService.resolveHomeShelfPlaylist) instead of requiring every
// card's ~100 songs to already be fetched before Home can even show the
// row — keeps the multi-shelf home load itself cheap regardless of how
// many shelves/items InnerTube returns.
class _RealShelfPlaylistCard extends StatefulWidget {
  final HomeShelfItem item;
  final bool fullWidth;
  // FIX ("play trick option jar jagah laga hai, hata do, bs 1-2 jagah
  // ekdam innertube jaisa" — 2026-09-07 recheck): isRadioMix (InnerTube's
  // own pageType) turned out to come back true/ambiguous across nearly
  // every shelf item in practice, not just genuine mixes — so gating on
  // it alone still showed the icon on almost every card, exactly the
  // "sab jagah laga hai" problem being fixed. Switched to an explicit
  // allow-list by shelf title instead: only shelves whose cards are
  // genuinely video/mix-style content (community/trending playlists,
  // "Hits of" year-collage editorial shelves) opt in — a plain
  // curated/mood playlist or album shelf never shows it. Update
  // ("aur bhe kuch pr rakho bs jyda nhi" — 2026-09-07): added
  // 'Featured playlists for you' to the list alongside 'Trending
  // community playlists' — still an explicit, short allow-list, not a
  // blanket on/off.
  final String shelfTitle;
  const _RealShelfPlaylistCard({
    required this.item,
    required this.shelfTitle,
    this.fullWidth = false,
  });

  @override
  State<_RealShelfPlaylistCard> createState() =>
      _RealShelfPlaylistCardState();
}

class _RealShelfPlaylistCardState extends State<_RealShelfPlaylistCard> {
  bool _pressed = false;
  bool _resolving = false;

  Future<void> _open() async {
    if (_resolving) return;
    AurumHaptics.selection();
    setState(() => _resolving = true);
    // PERF FIX ("playlist pe click karne pe pehle loading leta hai" —
    // 2026-09-06): this used to await resolveHomeShelfPlaylist's full
    // network round-trip (up to 10s timeout) BEFORE navigating at all —
    // meaning every tap sat on a frozen/loading card for however long
    // that fetch took, exactly the "feels slow" gap being fixed here.
    // Real YT Music navigates to the mix screen INSTANTLY on tap and
    // streams the tracklist in after — this now does the same: navigate
    // first with an empty list, then resolve the real first page as this
    // screen's own `autoLoadMore` (which MixScreen already calls once
    // right after it mounts and appends the result in-place — see
    // MixScreen.autoLoadMore's own doc comment). One InnerTube call
    // either way; the only change is WHEN the user starts looking at a
    // real (if momentarily empty) screen instead of a still-on-Home
    // loading spinner.
    if (mounted) setState(() => _resolving = false);
    if (!mounted) return;
    AurumDepthRoute.to(
      context,
      MixScreen(
        mixId: widget.item.browseId,
        mixName: widget.item.title,
        artworkUrl: widget.item.artworkUrl,
        emoji: '',
        songs: const [],
        autoLoadMore: () async {
          final firstPage = await ApiService.resolveHomeShelfPlaylist(widget.item);
          if (firstPage.isEmpty) return firstPage;
          final more = await ApiService.fetchHomeShelfPlaylistMore(
            widget.item,
            existingVideoIds: firstPage.map((s) => s.id).toList(),
          );
          return [...firstPage, ...more];
        },
      ),
    );
  }

  // FIX ("playlist pe click karne pe pehle loading leta hai" — recheck,
  // 2026-09-06): the old _open() had its own failure snackbar shown on
  // Home's context before navigating — that's no longer possible since
  // navigation now happens BEFORE the fetch (see _open() above). A
  // genuine failure (bad network, no songs found for this shelf item at
  // all) now surfaces as MixScreen's own empty-state text instead —
  // same message, just shown on the screen the person is actually
  // looking at when the failure becomes known, rather than a snackbar
  // on a screen they've already left.

  @override
  Widget build(BuildContext context) {
    final c = widget.item;
    return RepaintBoundary(
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _open,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1.0,
          duration: AurumMotion.durationOrZero(AurumMotion.short1),
          curve: Curves.easeOut,
          child: Container(
            // SIZE BUMP ("cards ko toda sa bada kr skte ho jo innertube se
            // aa rahe hai" — 2026-09-07): 130 -> 148, a modest bump
            // (matches the row height above) rather than a big jump —
            // stays square (no explicit height, still fills the parent
            // FadedHorizontalList's height) so this never distorts.
            width: widget.fullWidth ? null : 172,
            margin: widget.fullWidth
                ? EdgeInsets.zero
                : const EdgeInsets.only(right: 12),
            // PREMIUM UPGRADE — YT Music/Spotify-grade card depth: layered
            // ambient shadow beneath the card (previously flush/flat) plus
            // a whisper-thin highlight border so cards read as physically
            // raised tiles rather than pasted-on images. Radius bumped
            // 14->18 to match the rounder, "expensive" card language used
            // across the redesign.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: AurumTheme.accentOf(context).withOpacity(0.06),
                  blurRadius: 24,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (c.artworkUrl.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: c.artworkUrl,
                      cacheManager: AurumImageCache(),
                      fit: BoxFit.cover,
                      memCacheWidth: 260,
                      memCacheHeight: 260,
                      placeholder: (_, __) =>
                          Container(color: AurumTheme.bgCardOf(context)),
                      errorWidget: (_, __, ___) =>
                          Container(color: AurumTheme.bgCardOf(context)),
                    )
                  else
                    Container(color: AurumTheme.bgCardOf(context)),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.85),
                        ],
                        stops: const [0.35, 1.0],
                      ),
                    ),
                  ),
                  // Hairline inner border — the "expensive glass" edge
                  // treatment used across the redesign, matches the
                  // hero/app-bar accent-glass language instead of a bare
                  // flat image edge.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.08),
                        width: 1,
                      ),
                    ),
                  ),
                  // Explicit short allow-list — see the widget-level doc
                  // comment above for why isRadioMix alone wasn't
                  // reliable enough in practice.
                  if (widget.shelfTitle == 'Trending community playlists' ||
                      widget.shelfTitle == 'Featured playlists for you')
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withOpacity(0.45),
                        ),
                        child: const Icon(
                          Icons.play_circle_outline,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.1,
                            height: 1.2,
                          ),
                        ),
                        if (c.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            c.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.75),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_resolving)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black45,
                        child: Center(
                          child: AurumMorphLoader(size: 22),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Album card for a real InnerTube home shelf — used by both
// _RealHomeShelfRow (the horizontal shelf row on Home) and
// _ShelfSeeAllScreen (that shelf's own "see all" grid) whenever a shelf
// item is an album rather than a playlist/mix.
class _HomeAlbumCardWidget extends StatelessWidget {
  final HomeAlbumCard card;
  const _HomeAlbumCardWidget({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () {
          AurumHaptics.light();
          AurumDepthRoute.to(
            context,
            AlbumScreen(
              albumId: card.albumId,
              albumName: card.title,
              artworkUrl: card.artworkUrl,
            ),
          );
        },
        child: SizedBox(
          // Matches _RealShelfPlaylistCard's 172 width/height exactly so
          // album cards don't look smaller/flatter sitting next to
          // playlist cards in the same shelf row.
          width: 172,
          height: 172,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AurumArtwork(url: card.artworkUrl, size: 130, borderRadius: 16),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                card.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (card.artist.isNotEmpty)
                Text(
                  card.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// FEATURE ("See all" full-grid screen — 2026-09-07): plain grid of every
// item already sitting in `shelf.items` (no re-fetch — the horizontal row
// already has all of it in memory). Reuses _RealShelfPlaylistCard /
// _HomeAlbumCardWidget as-is so the tap-through (album -> AlbumScreen,
// playlist -> lazy-resolved MixScreen via resolveHomeShelfPlaylist) is
// pixel-for-pixel the same behavior as tapping the same card on Home.
// FIX ("khule to best page bana kr khule, aisa na khule akward lg raha
// hai" — 2026-09-07 recheck): cards here used to be the fixed-148px
// horizontal-strip card, centered inside a wider flexible grid cell —
// left visible empty gutters on either side of every card, unlike the
// reference screenshot's edge-to-edge grid cards. Switched to
// fullWidth: true (a flag both card widgets already supported, used
// elsewhere in this file for exactly this full-bleed case) so each card
// now stretches to fill its own grid cell — no Center() wrapper needed,
// no gutters, matches the reference "India's biggest hits" page.
class _ShelfSeeAllScreen extends StatelessWidget {
  final HomeShelf shelf;
  const _ShelfSeeAllScreen({required this.shelf});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          shelf.title,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 20,
          crossAxisSpacing: 14,
          // FIX ("see all pe jaake cards stretched/akward lag rahe hai" —
          // recheck): 0.72 made each cell noticeably taller than wide,
          // and _RealShelfPlaylistCard's artwork Stack has no fixed
          // aspect ratio of its own when fullWidth:true (width: null) —
          // it just fills whatever height the grid cell hands it. That
          // combination stretched every card into a tall, warped
          // rectangle, breaking the clean near-square look the same
          // cards have in the horizontal shelf row. 1.0 keeps cells
          // square so cards here match the shelf row exactly instead of
          // visibly distorting.
          childAspectRatio: 1.0,
        ),
        itemCount: shelf.items.length,
        itemBuilder: (_, i) {
          final item = shelf.items[i];
          if (item.isAlbum) {
            // Album card keeps its own fixed 130 width + below-artwork
            // title/artist text (different layout than the playlist
            // card, which bakes title into the artwork) — still needs
            // centering in the wider grid cell, unlike the playlist
            // card below which now stretches via fullWidth instead.
            return Center(
              child: _HomeAlbumCardWidget(
                card: HomeAlbumCard(
                  albumId: item.browseId,
                  title: item.title,
                  artist: item.subtitle,
                  artworkUrl: item.artworkUrl,
                ),
              ),
            );
          }
          return _RealShelfPlaylistCard(
            item: item,
            shelfTitle: shelf.title,
            fullWidth: true,
          );
        },
      ),
    );
  }
}

const String _kRealMoodAllId = '__all__';

class _RealMoodChipsSection extends StatefulWidget {
  final int refreshKey;
  const _RealMoodChipsSection({this.refreshKey = 0});

  @override
  State<_RealMoodChipsSection> createState() => _RealMoodChipsSectionState();
}

class _RealMoodChipsSectionState extends State<_RealMoodChipsSection> {
  List<MoodGenreCategory>? _categories;
  bool _categoriesFailed = false;

  String _selectedMood = _kRealMoodAllId;
  List<HomeShelf>? _categoryShelves;
  bool _categoryFailed = false;
  // Guards a fast chip-tap-tap-tap from letting an earlier, slower
  // fetch's result land after a later one already resolved and
  // rendered — same "only the latest request wins" rule used
  // elsewhere in this file (e.g. SearchScreen's own query race guard).
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  @override
  void didUpdateWidget(_RealMoodChipsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FIX (recheck — "refresh pr bhe ekdam fresh ekdam real innertube
    // se" — 2026-09-13): pull-to-refresh used to only reload the chip
    // list itself. If a mood other than "All" was still selected at
    // refresh time, that mood's OWN category shelves were never
    // refetched — the chip row refreshed but the shelves underneath it
    // silently kept showing the pre-refresh data until the user tapped
    // the chip again. Reset selection back to "All" on every refresh
    // (same rule _HomeShelvesAndSimilarSection already applies to ITS
    // own state) so a refresh always lands on a guaranteed-fresh state
    // rather than a stale mood carried over from before the refresh.
    if (oldWidget.refreshKey != widget.refreshKey) {
      _selectedMood = _kRealMoodAllId;
      _categoryShelves = null;
      _categoryFailed = false;
      _loadCategories();
    }
  }

  Future<void> _loadCategories() async {
    try {
      final sections = await ApiService.fetchMoodsAndGenres();
      if (!mounted) return;
      // Flatten every section's tiles into one chip row — this row is
      // a quick-access shortcut, not the full categorized grid (that's
      // still MoodsGenresScreen, one tap away via the shelves below).
      final flat = <MoodGenreCategory>[
        for (final section in sections) ...section.items,
      ];
      setState(() {
        _categories = flat;
        _categoriesFailed = flat.isEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _categoriesFailed = true);
    }
  }

  Future<void> _onMoodTap(String id) async {
    AurumHaptics.selection();
    if (id == _selectedMood) return;
    setState(() {
      _selectedMood = id;
      _categoryShelves = null;
      _categoryFailed = false;
    });
    if (id == _kRealMoodAllId) return;

    final categories = _categories;
    if (categories == null) return;
    final match = categories.where((c) => c.params == id).firstOrNull;
    if (match == null) return;

    final token = ++_loadToken;
    try {
      final shelves =
          await ApiService.fetchMoodGenreCategory(match.browseId, match.params);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _categoryShelves = shelves;
        _categoryFailed = shelves.isEmpty;
      });
    } catch (_) {
      if (mounted && token == _loadToken) {
        setState(() => _categoryFailed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories;

    // Nothing real came back — skip the whole row silently rather than
    // showing an empty/broken chip strip, same "don't show a titled
    // section with no real content" rule every optional Home section
    // here follows.
    if (categories == null && _categoriesFailed) {
      return const SizedBox.shrink();
    }
    if (categories == null) {
      // Loading skeleton — plain chip-shaped shimmer blocks, same
      // quiet-skeleton language as the rest of Home.
      return Padding(
        padding: const EdgeInsets.only(top: 28, left: 12, right: 0),
        child: SizedBox(
          height: 34,
          child: Shimmer.fromColors(
            baseColor: AurumTheme.bgCardOf(context),
            highlightColor: AurumTheme.bgElevatedOf(context),
            child: Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      width: 74,
                      height: 34,
                      decoration: BoxDecoration(
                        color: AurumTheme.bgCardOf(context),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (categories.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 12),
            child: SizedBox(
              height: 34,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(right: 12),
                cacheExtent: 300,
                itemCount: categories.length + 1,
                itemBuilder: (_, i) {
                  final isAll = i == 0;
                  final id = isAll ? _kRealMoodAllId : categories[i - 1].params;
                  final label =
                      isAll ? AppLocalizations.of(context)!.homeMoodAll : categories[i - 1].title;
                  final selected = id == _selectedMood;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => _onMoodTap(id),
                      child: AnimatedContainer(
                        duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                        curve: Curves.easeOut,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: selected
                              ? AurumTheme.accentOf(context)
                              : AurumTheme.bgCardOf(context),
                          borderRadius: BorderRadius.circular(20),
                          border: selected
                              ? null
                              : Border.all(
                                  color: AurumTheme.textPrimaryOf(context)
                                      .withOpacity(0.10),
                                  width: 1,
                                ),
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? Theme.of(context).colorScheme.onPrimary
                                : AurumTheme.textPrimaryOf(context)
                                    .withOpacity(0.85),
                            fontSize: 13,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          // Selected-mood shelves — only rendered for a real (non-"All")
          // chip. "All" intentionally shows nothing here; the regular
          // shelves further down the page already cover that case.
          if (_selectedMood != _kRealMoodAllId) ...[
            const SizedBox(height: 12),
            if (_categoryShelves == null && !_categoryFailed)
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12),
                child: FadedHorizontalList(
                  height: 172,
                  child: const _YtPlaylistsForYouSkeleton(),
                ),
              )
            else if (_categoryFailed || (_categoryShelves?.isEmpty ?? true))
              const SizedBox.shrink()
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final shelf in _categoryShelves!)
                    _RealHomeShelfRow(
                      key: ValueKey('${shelf.title}_$_selectedMood'),
                      shelf: shelf,
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

// PERF FIX ("ekdam lightweight aur top garde chalna chahiye" — memory-leak
// audit, 2026-09-14): scrollController used to be a REQUIRED param, and
// both call sites below passed a brand-new `ScrollController()` inline on
// every single build() — this widget's own ListView.builder uses
// NeverScrollableScrollPhysics (it's a static shimmer placeholder, the
// user can never actually scroll it), so that controller was never
// serving any real scroll purpose in the first place, just being
// allocated and immediately discarded unclosed on every rebuild (e.g.
// every time a parent StatefulWidget's build() re-runs while still in
// its loading state — which for a slow/flaky connection can be many
// times). A ScrollController holds real ChangeNotifier/AnimationController-
// adjacent resources that are meant to be explicitly disposed; creating
// one inline like `ListView.builder(controller: ScrollController())` with
// no owning State to call .dispose() on it is a textbook Flutter memory
// leak. Since the physics already make it non-interactive, the controller
// serves no purpose here at all — dropped entirely instead of trying to
// manage its lifecycle.
class _YtPlaylistsForYouSkeleton extends StatelessWidget {
  const _YtPlaylistsForYouSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(right: 12),
      itemCount: 4,
      itemBuilder: (_, __) => Container(
        width: 130,
        height: 130,
        margin: const EdgeInsets.only(right: 12),
        child: Shimmer.fromColors(
          baseColor: AurumTheme.bgCardOf(context),
          highlightColor: AurumTheme.textPrimaryOf(context).withOpacity(0.06),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}

// FIX (2026-08-14): a mood switch that comes back empty/failed used to
// make the ENTIRE "Playlists For You" section vanish (see the build()
// comment above). Now that case renders this small inline retry tile
// instead — row stays visible, user gets a one-tap way to try that
// mood again, matches how the reference apps this row is modeled on
// handle a failed shelf without hiding the whole shelf.
class _YtPlaylistsForYouRetry extends StatelessWidget {
  final VoidCallback onRetry;
  const _YtPlaylistsForYouRetry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 130,
      child: Center(
        child: TextButton.icon(
          onPressed: onRetry,
          icon: Icon(Icons.refresh_rounded,
              size: 18, color: AurumTheme.textSecondaryOf(context)),
          label: Text(
            // Hardcoded (not routed through l10n) deliberately — adding
            // a new AppLocalizations key here would need .arb entries
            // regenerated for every locale, which this fix can't safely
            // do blind. Plain English string is a safe, zero-risk
            // choice for a small retry affordance.
            'Retry',
            style: TextStyle(
              color: AurumTheme.textSecondaryOf(context),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          style: TextButton.styleFrom(
            backgroundColor: AurumTheme.bgCardOf(context),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// Home Premium Banner — shown to free users between sections
// ─────────────────────────────────────────────────────────────────────────────

class _HomePremiumBanner extends StatefulWidget {
  final bool isActive;
  const _HomePremiumBanner({this.isActive = true});

  @override
  State<_HomePremiumBanner> createState() => _HomePremiumBannerState();
}

class _HomePremiumBannerState extends State<_HomePremiumBanner>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmer;

  // PERF: this banner lives on Home, which is kept alive inside an
  // IndexedStack (see main_shell.dart) — so even when the user is on
  // Library/Search/Profile, this widget is still mounted and, previously,
  // this shimmer's `..repeat()` kept ticking at 60fps in the background
  // forever, for every free user, burning GPU/battery for a purely
  // decorative loop nobody could see. Same fix pattern as the full/home
  // player's ambient breathe animation: pause on app background, and
  // respect the Appearance -> Animations toggle.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _shimmer =
        CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOutSine);
    if (AudioPrefs.enableAnimationsNotifier.value && widget.isActive) {
      _shimmerCtrl.repeat();
    }
  }

  @override
  void didUpdateWidget(_HomePremiumBanner old) {
    super.didUpdateWidget(old);
    // See the PERF comment above this class — same IndexedStack-visibility
    // gap as home_screen.dart's own _breatheCtrl, fixed the same way:
    // stop immediately when this tab is switched away from; resume is
    // left to whatever triggers a rebuild once active again (matches
    // build()'s AnimatedBuilder, which just reads current _shimmerCtrl
    // state — no separate restart path needed here).
    if (old.isActive == widget.isActive) return;
    if (!widget.isActive) {
      _shimmerCtrl.stop();
    } else if (AudioPrefs.enableAnimationsNotifier.value &&
        !_shimmerCtrl.isAnimating) {
      _shimmerCtrl.repeat();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (AudioPrefs.enableAnimationsNotifier.value &&
          widget.isActive &&
          !_shimmerCtrl.isAnimating) {
        _shimmerCtrl.repeat();
      }
    } else {
      _shimmerCtrl.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPremium = context.watch<PremiumProvider>().isPremium;
    if (isPremium) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
      child: AurumPressable(
        scaleAmount: 0.97,
        // Same AurumDepthRoute switch as Settings/Profile above, so
        // Premium's entry animation matches the rest of that flow too.
        onTap: () => AurumDepthRoute.to(context, const PremiumScreen()),
        child: AnimatedBuilder(
          animation: _shimmer,
          builder: (_, __) {
            final t = _shimmer.value;
            final sweep = (t * 2.6) - 0.8;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: const [
                    Color(0xFF2A1E00),
                    Color(0xFF1A1200),
                  ],
                ),
                border: Border.all(
                  color: AurumTheme.accent.withOpacity(0.3),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.accent.withOpacity(0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(children: [
                // Shimmer icon
                ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: const [
                      AurumTheme.accentDark,
                      AurumTheme.accentLight,
                      AurumTheme.accent,
                    ],
                    stops: [
                      (sweep - 0.4).clamp(0.0, 1.0),
                      sweep.clamp(0.0, 1.0),
                      (sweep + 0.4).clamp(0.0, 1.0),
                    ],
                  ).createShader(bounds),
                  child: const Icon(Icons.workspace_premium_rounded,
                      color: Colors.white, size: 32),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShaderMask(
                        shaderCallback: (b) => LinearGradient(
                          colors: const [
                            AurumTheme.accentDark,
                            AurumTheme.accentLight,
                          ],
                          stops: [
                            (sweep - 0.5).clamp(0.0, 1.0),
                            (sweep + 0.5).clamp(0.0, 1.0),
                          ],
                        ).createShader(b),
                        child: const Text(
                          'Unlock Astra Plus ✦',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '320kbps • Offline • No ads • More',
                        style: TextStyle(
                          color: AurumTheme.accent.withOpacity(0.55),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    gradient: AurumTheme.accentGradient,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Try',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// ignore: avoid_void_async
void unawaited(Future<void> f) {}

