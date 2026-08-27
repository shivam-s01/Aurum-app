import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/source_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../services/home_feed_cache.dart';
import '../services/recommendation_engine.dart';
import '../providers/download_provider.dart';
import '../services/audio_prefs.dart';
import '../services/native_engine_bridge.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/faded_horizontal_list.dart';
import '../widgets/song_tile.dart';
import '../main.dart' show aurumRouteObserver;
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
import 'login_screen.dart';
import 'full_player_screen.dart';
import 'premium_screen.dart';
import 'mix_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

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
          const fullPlayer = FullPlayerScreen();
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
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
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
// gold accent so it still matches the rest of Aurum instead of looking
// like a stock Material widget.

class _HomeScreenState extends State<HomeScreen> {
  bool _onlineLoading = true;
  String? _onlineError;
  // Bumped on every pull-to-refresh so the "Playlists for You" cards (which
  // cache their own art/songs in initState) get fresh widget identities and
  // refetch a brand-new random Saavn-first set instead of showing stale data.
  int _playlistRefreshKey = 0;

  List<ArtistSimple> _homeArtists = [];
  bool _artistsLoading = true;
  // Scopes the cache-shrink-flash guard in _loadArtists() to only the
  // FIRST streaming callback per load — see that guard's doc comment.
  bool _isFirstArtistUpdate = true;

  final ScrollController _scrollCtrl = ScrollController();

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
    // FIX (cold-start instant load, Spotify-style): render whatever was
    // cached from the last successful load FIRST, synchronously into
    // initial state where possible, so the very first frame already shows
    // real content instead of shimmer — then kick off the real network
    // fetch in the background exactly as before. _hydrateFromCache reads
    // SharedPreferences (fast, no network) and silently no-ops if this is
    // a genuine first-ever launch with nothing cached yet, in which case
    // behavior is identical to before this fix.
    _hydrateFromCache();
    _loadOnline(clearExisting: false);
    _loadArtists();
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
          textColor: AurumTheme.gold,
          onPressed: () => player.togglePlay(),
        ),
      ),
    );
  }

  Future<void> _hydrateFromCache() async {
    final cachedSections = await HomeFeedCache.loadSections();
    final cachedArtists = await HomeFeedCache.loadArtists();
    if (!mounted) return;
    // Only apply the cache if the real fetch hasn't already produced
    // something newer/better by the time this resolves — SharedPreferences
    // reads are fast but still technically async, and _loadOnline() is
    // fired in the same initState right after this call. Guarding on
    // `_onlineSections.isEmpty`/`_homeArtists.isEmpty` means whichever
    // source lands first (almost always the cache, since it's pure local
    // disk vs a network round-trip) wins the initial paint, and the other
    // one simply never overwrites it with less/older data.
    // PERF FIX: sections go through the ValueNotifier directly (no
    // setState) — see the notifier's doc comment above for why. Only the
    // artist strip still needs a real setState here, and only if it's
    // actually changing.
    if (_onlineSections.isEmpty && cachedSections.isNotEmpty) {
      // Real content already on screen from cache — the shimmer-only
      // loading state no longer applies, even though the fresh fetch is
      // still running in the background. _loadOnline()'s own onSection
      // stream will progressively replace these with live sections as
      // they arrive, same as it already does for a from-scratch load.
      _onlineSections = cachedSections;
      if (_onlineLoading) setState(() => _onlineLoading = false);
    }
    if (_homeArtists.isEmpty && cachedArtists.isNotEmpty) {
      setState(() {
        _homeArtists = cachedArtists;
        _artistsLoading = false;
      });
    }
  }

  @override
  void dispose() {
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
    } catch (_) {
      if (mounted) setState(() => _artistsLoading = false);
    }
  }

  // Recommendation Intelligence helper — RecommendationEngine only ever
  // stores/returns song IDs (kept intentionally lightweight so its
  // SharedPreferences footprint stays tiny even for a heavy listener), so
  // Home resolves those IDs back to full Song objects (for art, title,
  // artist, playback) from RecentlyPlayedProvider's own history, which
  // already holds every song the engine could possibly reference here
  // (Continue Listening / Rediscover Favorites only ever draw from songs
  // the user has actually played). Order follows `ids` (the engine's own
  // ranking), not `history`'s order.
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
      // BUGFIX: "sections load late" — this previously collected every
      // section into a local list and only called setState once, after
      // the ENTIRE fetchHomeStreaming batch finished (up to the full 25s
      // timeout in the worst case). fetchHomeStreaming already streams
      // sections in one-by-one via onSection specifically so the UI can
      // show them progressively — batching them all up here just meant
      // every section waited on the slowest one, which is exactly why
      // "Playlists For You" (loaded separately, by _YtPlaylistsForYouSection)
      // appeared fast while everything else felt stuck. Calling setState
      // per-section restores that progressive reveal.
      // Growable list built once and appended to in place — avoids an
      // O(n) full-list copy on every single section arrival, keeping
      // this lightweight even as more sections stream in. setState
      // triggers the rebuild Flutter needs; the List reference itself
      // doesn't need to change for that.
      // FIX (cold-start cache continuation): this used to always start
      // from a fresh empty list, which — combined with the
      // `clearExisting: false` fix above — meant cache-hydrated sections
      // would survive the setState above only to be wiped out right here
      // instead, the instant this line ran and before the first real
      // onSection callback even fired. Seeding from whatever's already in
      // _onlineSections (the cache, on a cold start) means those sections
      // stay visible on screen exactly as they were, and get replaced
      // title-by-title as genuine live sections stream in below — a
      // section whose title matches an already-shown cached one is
      // swapped in place instead of appended as a duplicate, so the user
      // never sees the same shelf twice while a refresh is in flight.
      final liveSections = clearExisting ? <SongSection>[] : List<SongSection>.from(_onlineSections);
      if (clearExisting) _onlineSections = liveSections;
      // PERF FIX ("refresh ke poore time tak lag/jerky rehta hai"): each of
      // the ~15-19 streamed sections used to trigger its own IMMEDIATE
      // List.from() copy + ValueNotifier rebuild the instant it arrived.
      // api_service.dart's own wave-throttling fires sections in small
      // bursts (up to 3 at a time, ~200ms apart) — so within a single burst,
      // 2-3 of these full copy+rebuild cycles were landing back-to-back in
      // the same handful of frames, competing with each other and with
      // whatever the just-hydrated cache content was still laying out. That
      // repeating burst-of-rebuilds pattern, once per wave, for the entire
      // duration of the refresh, is what read as "lag until fresh content
      // finishes loading" rather than one clean jank moment.
      // Coalescing into a microtask means every section that arrives within
      // the same synchronous batch (a whole burst resolving together) is
      // folded into ONE list copy and ONE notifier update, scheduled once
      // per burst instead of once per section — cutting the rebuild count
      // roughly 3x during exactly the window that felt janky, with zero
      // change to which sections appear or how fast the first one shows up.
      bool _flushScheduled = false;
      void scheduleFlush() {
        if (_flushScheduled) return;
        _flushScheduled = true;
        scheduleMicrotask(() {
          _flushScheduled = false;
          if (!mounted) return;
          _onlineSections = List<SongSection>.from(liveSections);
          if (_onlineLoading) setState(() => _onlineLoading = false);
        });
      }
      await ApiService.fetchHomeStreaming(
        topArtists: topArtists,
        topArtistsRotating: topArtistsRotating,
        recentlyPlayed: recentSongs,
        onSection: (section) {
          if (!mounted) return;
          // PERF FIX (40s cold-start lag): this used to be wrapped in
          // setState() on _HomeScreenState — see the ValueNotifier's doc
          // comment near the top of this State class for the full
          // explanation. Each of the ~15-19 sections streaming in here now
          // only notifies _onlineSectionsNotifier's own
          // ValueListenableBuilder (wrapping just _OnlineContent further
          // down in build()), instead of rebuilding the entire Home
          // screen — AppBar, curated playlists, premium banner, and artist
          // strip included — on every single arrival.
          final existingIdx = liveSections.indexWhere((s) => s.id == section.id);
          if (existingIdx != -1) {
            liveSections[existingIdx] = section;
          } else {
            liveSections.add(section);
          }
          // Reassign to a fresh list so the ValueNotifier's own identity
          // check (it only notifies listeners when the value actually
          // changes) reliably fires — mutating liveSections in place above
          // and reusing the same reference here would risk being treated
          // as "unchanged" by some ValueNotifier-adjacent tooling.
          // (See scheduleFlush() above — the actual reassignment + setState
          // now happens once per burst instead of once per section.)
          scheduleFlush();
        },
      ).timeout(const Duration(seconds: 25));
      if (mounted) {
        setState(() {
          _onlineLoading = false;
        });
      }
      // Cache the finished batch for next cold start (see
      // home_feed_cache.dart) — only once the full streamed batch has
      // actually finished, so a partial/interrupted load never overwrites
      // a previously-complete good cache with a thinner one.
      unawaited(HomeFeedCache.saveSections(liveSections));
    } catch (e) {
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
          // ── Top ambient glow layer (behind everything) ──
          const _TopAmbientGlow(),

          // ── Main scroll content ──
          // Reverted to Flutter's stock RefreshIndicator — the custom
          // AurumMorphLoader-based pull-to-refresh wasn't working
          // reliably, so this goes back to the simple, previously-working
          // native indicator. Styled gold/dark to still match Aurum.
          RefreshIndicator(
            color: AurumTheme.gold,
            backgroundColor: AurumTheme.bgCardOf(context),
            strokeWidth: 2.6,
            displacement: 48,
            onRefresh: () => isOnline
                ? Future.wait([_loadOnline(), _loadArtists()])
                : context.read<LibraryProvider>().refresh(),
            child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                _buildAppBar(context, src),
                SliverToBoxAdapter(child: _HeroNowPlaying(isActive: widget.isActive)),
                SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: isOnline
                              ? const Offset(-0.06, 0)
                              : const Offset(0.06, 0),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: isOnline
                        ? Column(
                            key: const ValueKey('online'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Playlists For You (real YT Music) ──
                              _YtPlaylistsForYouSection(refreshKey: _playlistRefreshKey),
                              // ── Premium upsell banner removed (all features free now) ──
                              // ── Song sections, with the Artist Strip
                              // injected at the midpoint — YT Music and
                              // Spotify both surface a "Popular artists" /
                              // "Your favorite artists" row roughly halfway
                              // down the home feed, never buried after
                              // every other section. _OnlineContent now
                              // computes that midpoint itself from
                              // whatever sections actually streamed in
                              // (varies per session), so the strip's
                              // position stays "middle of the feed" no
                              // matter how many sections load.
                              // PERF FIX: isolated in its own
                              // ValueListenableBuilder so each streamed-in
                              // section (up to ~15-19 per cold start) only
                              // rebuilds this subtree — not the curated
                              // playlists row or premium banner above it.
                              // See _onlineSectionsNotifier's doc comment.
                              ValueListenableBuilder<List<SongSection>>(
                                valueListenable: _onlineSectionsNotifier,
                                builder: (context, sections, _) {
                                  return _OnlineContent(
                                    sections: sections,
                                    loading: _onlineLoading,
                                    error: _onlineError,
                                    onRetry: _loadOnline,
                                    artistStrip: _ArtistStrip(
                                      artists: _homeArtists,
                                      loading: _artistsLoading,
                                    ),
                                  );
                                },
                              ),
                            ],
                          )
                        : const _OfflineContent(key: ValueKey('offline')),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
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
              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
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
                      ..color = AurumTheme.gold.withOpacity(0.22)
                      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
                  ),
                ),
                ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [
                      AurumTheme.goldLight,
                      AurumTheme.gold,
                      AurumTheme.goldDark,
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [AurumTheme.goldDark, AurumTheme.gold, AurumTheme.goldLight],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.45),
                    blurRadius: 10,
                    spreadRadius: 0.5,
                  ),
                ],
              ),
              child: const Text(
                '✦ Plus',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
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
// Hero Now Playing — premium immersive section + floating glass card.
// Lives inside HomeScreen's IndexedStack tab, so Flutter's TickerMode
// automatically pauses the AnimationController when this tab is offstage —
// no manual lifecycle wiring needed for the breathing animation.
// ─────────────────────────────────────────────────────────────────────────────

class _HeroNowPlaying extends StatefulWidget {
  final bool isActive;
  const _HeroNowPlaying({this.isActive = true});

  @override
  State<_HeroNowPlaying> createState() => _HeroNowPlayingState();
}

class _HeroNowPlayingState extends State<_HeroNowPlaying>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  late final AnimationController _breatheCtrl;
  String? _lastUrl;
  bool _appInForeground = true;

  // ── Left/right swipe → prev/next song ──
  double _dragX = 0;
  bool _isDraggingX = false;
  int _swipeDir = 0;
  String? _lastSongId;
  static const double _swipeThreshold = 70.0;
  static const double _swipeVelocityThreshold = 500.0;

  late final AnimationController _swipeCtrl;
  Animation<double> _swipeAnim = const AlwaysStoppedAnimation(0.0);
  late final AnimationController _slideInCtrl;
  late Animation<double> _slideInAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 13s full cycle — within spec's 12-15s range
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 20000),
    ); // started/stopped from build() based on isPlaying — see build()

    _swipeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _slideInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _slideInAnim =
        CurvedAnimation(parent: _slideInCtrl, curve: Curves.easeOutCubic);
  }

  ModalRoute<void>? _subscribedRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Guard against re-subscribing on every didChangeDependencies call —
    // this fires more than once since _HeroNowPlaying lives inside an
    // IndexedStack tab that's never disposed (theme changes, MediaQuery
    // changes, etc. all re-trigger it). Only (re)subscribe if the actual
    // ModalRoute instance changed, matching Flutter's documented
    // RouteAware pattern exactly.
    final route = ModalRoute.of(context);
    if (route != null && route != _subscribedRoute) {
      if (_subscribedRoute != null) {
        aurumRouteObserver.unsubscribe(this);
      }
      aurumRouteObserver.subscribe(this, route);
      _subscribedRoute = route;
    }
  }

  // FIX — breathing animation permanently dead after opening the full
  // player once: FullPlayerScreen is pushed via Navigator ON TOP of Home,
  // which puts Home's route (and everything in it, including this widget)
  // under Flutter's TickerMode.disabled. That silently stops _breatheCtrl
  // from ticking frames, but does NOT flip AnimationController.isAnimating
  // back to false — the controller still THINKS it's mid-`.repeat()`.
  // build()'s gate is `if (shouldBreathe && !_breatheCtrl.isAnimating)`,
  // so on returning to Home, isAnimating already reads true and that
  // guard never re-fires .repeat() — the animation stays frozen forever
  // (or until the next song change happens to reset state elsewhere).
  // Fix: RouteAware.didPopNext fires exactly when this route becomes the
  // active top route again (i.e. right after popping FullPlayerScreen
  // back to Home). Force a hard stop+restart there so the controller's
  // internal state is never left stale.
  @override
  void didPopNext() {
    if (!mounted) return;
    // Hard reset — do NOT rely on the `!_breatheCtrl.isAnimating` guard in
    // build(), since that flag can still read `true` here (stale from
    // before TickerMode disabled this route) even though no frames have
    // actually ticked. .stop() first guarantees a clean, real restart.
    _breatheCtrl.stop();
    final player = context.read<PlayerProvider>();
    if (player.isPlaying && _appInForeground && widget.isActive) {
      _breatheCtrl.repeat(reverse: true);
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(_HeroNowPlaying old) {
    super.didUpdateWidget(old);
    // See widget.isActive doc comment — stop the breathe glow the instant
    // this tab is switched away from, rather than leaving it ticking
    // off-screen until some unrelated rebuild happens to re-evaluate
    // build()'s gate. Switching back TO this tab lets build()'s own gate
    // (which already re-checks isPlaying/appInForeground) resume it
    // naturally on the next build — no special-case restart needed here,
    // only the stop needs to be immediate.
    if (old.isActive == widget.isActive) return;
    if (!widget.isActive && _breatheCtrl.isAnimating) {
      _breatheCtrl.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Force-stop the breathe glow the instant the app leaves the
    // foreground (minimized, screen locked, app-switcher) regardless of
    // isPlaying — audio keeps playing via the foreground service, but
    // there's zero reason to keep repainting this widget when nobody can
    // see it. This is on top of the isPlaying gate in build().
    _appInForeground = state == AppLifecycleState.resumed;
    if (!_appInForeground) {
      if (_breatheCtrl.isAnimating) _breatheCtrl.stop();
    } else if (mounted) {
      setState(() {}); // let build() re-evaluate and resume if isPlaying
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    aurumRouteObserver.unsubscribe(this);
    _breatheCtrl.dispose();
    _swipeCtrl.dispose();
    _slideInCtrl.dispose();
    super.dispose();
  }

  // Generation token — same pattern as mini player's _swipeGen. Prevents
  // stale .whenComplete() callbacks from firing extra/wrong skipNext/
  // skipPrev calls when swipes are spammed rapidly back-to-back.
  int _swipeGen = 0;

  void _onDragStartX(DragStartDetails _) {
    _swipeGen++;
    _swipeCtrl.stop();
    setState(() => _isDraggingX = true);
  }

  void _onDragUpdateX(DragUpdateDetails details) {
    setState(() {
      _dragX = (_dragX + details.delta.dx).clamp(-160.0, 160.0);
    });
  }

  void _onDragEndX(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDraggingX = false);

    final commitNext =
        _dragX < -_swipeThreshold || velocity < -_swipeVelocityThreshold;
    final commitPrev =
        _dragX > _swipeThreshold || velocity > _swipeVelocityThreshold;

    if (commitNext) {
      AurumHaptics.medium();
      _commitSwipe(next: true);
    } else if (commitPrev) {
      AurumHaptics.medium();
      _commitSwipe(next: false);
    } else {
      _springBackX();
    }
  }

  void _springBackX() {
    _swipeCtrl.stop();
    final gen = ++_swipeGen;
    _swipeAnim = Tween<double>(begin: _dragX, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _swipeGen) return;
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }

  void _commitSwipe({required bool next}) {
    _swipeCtrl.stop();
    final gen = ++_swipeGen;
    _swipeAnim =
        Tween<double>(begin: _dragX, end: next ? -220.0 : 220.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeInCubic),
    );
    _swipeDir = next ? -1 : 1;
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _swipeGen) return;
      final player = context.read<PlayerProvider>();
      next ? player.skipNext() : player.skipPrev();
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }


  void _openFullPlayer() {
    pushFullPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final isLight = Theme.of(context).brightness == Brightness.light;

    // Battery: the breathe glow only needs to animate while a song is
    // actually playing. Previously it ran on an infinite ..repeat(reverse:
    // true) from initState with no gating, so it kept ticking (and
    // repainting this part of the hero) even when paused or when nothing
    // was loaded — pure wasted GPU/CPU work sitting on the home screen.
    final isPlayingNow =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final shouldBreathe = isPlayingNow &&
        _appInForeground &&
        widget.isActive &&
        AudioPrefs.enableAnimationsNotifier.value;
    if (shouldBreathe && !_breatheCtrl.isAnimating) {
      _breatheCtrl.repeat(reverse: true);
    } else if (!shouldBreathe && _breatheCtrl.isAnimating) {
      _breatheCtrl.stop();
    }

    // FIX: a persistent hairline seam (page's cream/`bgOf` background
    // peeking through) was showing along the hero's bottom edge in every
    // state, not just mid-transition. Root cause: AnimatedSize recomputes
    // its layout size from its child's intrinsic size every frame, and
    // that computed size can be a sub-pixel off from the child's actual
    // painted bounds due to rounding — normally invisible, but here the
    // full-bleed hero (no margin/card color of its own to plug the gap,
    // unlike the old padded/boxed design) sits directly on the page
    // background, so that fractional gap exposed it as a visible seam.
    //
    // Fix: `clipBehavior: Clip.hardEdge` on AnimatedSize clips content to
    // its own computed bounds rather than letting a rounding mismatch
    // show whatever's behind it. This addresses the actual rendering
    // artifact directly, rather than trying to paint over a gap that
    // shouldn't be visible in the first place.
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: song == null
            ? _buildEmptyPrompt(context)
            : _buildPlayingCard(context, song, isLight),
      ),
    );
  }

  Widget _buildEmptyPrompt(BuildContext context) {
    // Lightweight static prompt — no blur, no animation, theme-safe.
    // Kept a small side margin here (unlike the playing card below) since
    // there's no artwork to bleed edge-to-edge — a floating pill reads
    // better than a full-width empty bar.
    return Padding(
      key: const ValueKey('hero_empty'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 22),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AurumTheme.bgCardOf(context),
        ),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded,
                color: AurumTheme.gold.withOpacity(0.85), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.homePickSomething,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Playing card — "now playing stage" ──────────────────────────────────
  // Redesigned as a full-bleed panel (no side margins, no rounded card
  // floating on the page background, no outer border) so it reads as the
  // top of a continuous surface that the rest of the page descends from,
  // rather than a separate boxed widget sitting on top of the scaffold.
  // All gesture/animation logic below (swipe-to-skip, breathing scale,
  // slide-in on song change) is unchanged from before — only the outer
  // shape/spacing changed.
  Widget _buildPlayingCard(BuildContext context, Song song, bool isLight) {
    return Padding(
      key: const ValueKey('hero_playing'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 22),
      child: AurumPressable(
        scaleAmount: 0.99,
        onTap: _openFullPlayer,
        child: Container(
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isLight ? 0.14 : 0.32),
                blurRadius: 22,
                offset: const Offset(0, 10),
                spreadRadius: -4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: ValueListenableBuilder<bool>(
            valueListenable: AudioPrefs.swipeToChangeNotifier,
            builder: (context, swipeEnabled, _) {
              return GestureDetector(
            onHorizontalDragStart: swipeEnabled ? _onDragStartX : null,
            onHorizontalDragUpdate: swipeEnabled ? _onDragUpdateX : null,
            onHorizontalDragEnd: swipeEnabled ? _onDragEndX : null,
            child: AnimatedBuilder(
              animation: Listenable.merge([_swipeCtrl, _slideInCtrl]),
              builder: (_, child) {
                if (song.id != _lastSongId) {
                  final isFirst = _lastSongId == null;
                  _lastSongId = song.id;
                  if (!isFirst) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _slideInCtrl.forward(from: 0.0);
                    });
                  }
                }
                final swipeX =
                    _swipeCtrl.isAnimating ? _swipeAnim.value : _dragX;
                final frac = (swipeX.abs() / 160.0).clamp(0.0, 1.0);
                final swipeOpacity = (1.0 - frac * 0.7).clamp(0.0, 1.0);
                final swipeScale = (1.0 - frac * 0.05).clamp(0.92, 1.0);

                final slideInOffset = _slideInCtrl.isAnimating
                    ? (1.0 - _slideInAnim.value) * (_swipeDir * -140.0)
                    : 0.0;
                final slideInOpacity = _slideInCtrl.isAnimating
                    ? Curves.easeOut.transform(_slideInAnim.value)
                    : 1.0;

                final totalX = swipeX + slideInOffset;
                final totalOpacity = (swipeOpacity *
                        (_slideInCtrl.isAnimating ? slideInOpacity : 1.0))
                    .clamp(0.0, 1.0);

                return Transform.translate(
                  offset: Offset(totalX, 0),
                  child: Transform.scale(
                    scale: swipeScale,
                    child: Opacity(opacity: totalOpacity, child: child),
                  ),
                );
              },
              child: Stack(fit: StackFit.expand, children: [
            // ── Stage background: blurred artwork, breathing scale ──
            // Perf: the blur (ImageFiltered) is now built ONCE, outside the
            // AnimatedBuilder — only the cheap Transform.scale wrapper
            // rebuilds every animation tick. Before, the blur filter itself
            // sat inside the builder callback, so Skia was re-running the
            // (expensive, full-stage-sized) Gaussian blur on every single
            // frame of the breathe loop for a scale change of at most
            // 1.5% — pure wasted GPU work for an effect nobody can even
            // perceive.
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _breatheCtrl,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: isLight ? 2.5 : 2,
                    sigmaY: isLight ? 2.5 : 2,
                    tileMode: TileMode.clamp,
                  ),
                  child: AurumArtwork(
                    url: song.artworkUrl,
                    size: double.infinity,
                    borderRadius: 0,
                  ),
                ),
                builder: (_, child) {
                  // FIX (same glitch as full_player_screen.dart's Ken
                  // Burns pan): _breatheCtrl already reverses direction on
                  // its own via repeat(reverse: true). Layering
                  // Curves.easeInOut.transform() on that raw value
                  // re-eases something already changing direction — at
                  // each turnaround the controller's own velocity flip and
                  // the curve's steep slope combine into a visible snap,
                  // most noticeable on the return stroke. A raised-cosine
                  // is smooth at both ends of a reversing triangle wave.
                  final b = (1 - math.cos(_breatheCtrl.value * math.pi)) / 2;
                  return Transform.scale(
                    scale: 1.0 + (b * 0.015), // 1.00 -> 1.015: alive, not animated
                    child: child,
                  );
                },
              ),
            ),
            // ── Scrim: now fades from fully transparent at the very top
            // (so it visually joins the appbar behind it, reinforcing the
            // "one continuous stage" read) down to a strong dark base
            // where the track info sits, for legibility.
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isLight
                      ? [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.0),
                          Colors.black.withValues(alpha: 0.32),
                        ]
                      : [
                          Colors.black.withValues(alpha: 0.0),
                          Colors.black.withValues(alpha: 0.15),
                          Colors.black.withValues(alpha: 0.70),
                        ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
            // ── Track info + resume — sits directly on the stage now,
            // no floating glass card/border. Full-width, edge-aligned
            // with the rest of the page's 20px gutter.
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AurumArtwork(
                        url: song.artworkUrl, size: 44, borderRadius: 11),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.artist,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.68),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ]),
            ),
          );
            },
          ),
          ),
        ),
      ),
    );
  }
}

class _TopAmbientGlow extends StatefulWidget {
  const _TopAmbientGlow();

  @override
  State<_TopAmbientGlow> createState() => _TopAmbientGlowState();
}

class _TopAmbientGlowState extends State<_TopAmbientGlow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  Color _currentColor = Colors.transparent;
  Color _targetColor  = Colors.transparent;
  String _lastUrl     = '';

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastUrl) return;
    _lastUrl = url;

    try {
      final ImageProvider provider = url.startsWith('http')
          ? CachedNetworkImageProvider(url)
          : FileImage(File(url)) as ImageProvider;

      // 80x80 is enough for palette — minimal cost
      final pg = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(48, 48),
      );

      final raw = pg.vibrantColor?.color ??
          pg.dominantColor?.color ??
          pg.lightVibrantColor?.color;

      if (raw == null || !mounted) return;

      // Snapshot current lerped value before transition
      final t = _ctrl.value;
      _currentColor = Color.lerp(_currentColor, _targetColor, t) ?? _currentColor;

      final isDark = mounted && Theme.of(context).brightness == Brightness.dark;
      _targetColor = isDark
          // Dark mode: subtle, low-lightness — artwork stays the focus.
          ? HSLColor.fromColor(raw).withSaturation(0.45).withLightness(0.14).toColor()
          // Light mode: airy, higher lightness so it reads as soft
          // colored light rather than a dark smear behind bright text.
          : HSLColor.fromColor(raw).withSaturation(0.55).withLightness(0.72).toColor();

      // Fade out → update → fade in (crossfade feel)
      await _ctrl.reverse();
      if (!mounted) return;
      setState(() => _currentColor = _targetColor);
      _ctrl.forward();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);

    if (song != null) {
      // Fire async, no setState in build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _extractColor(song.artworkUrl);
      });
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    // FIX — home screen looked completely flat whenever nothing was
    // playing (which is exactly the state a fresh app-open lands on,
    // e.g. "Pick something to play"): this glow used to render nothing
    // at all with no active song, even though the whole point of the
    // effect is to give the page ambient depth instead of a flat block
    // of background color. A paid app's home surface has *some* subtle
    // life to it even before playback starts. Fall back to a gentle,
    // static wash of the brand gold at low opacity instead of
    // SizedBox.shrink — same painter, same position, just a fixed
    // idle color rather than one extracted from currently-playing art.
    final effectiveColor = song != null
        ? _currentColor
        : (isDark
            ? AurumTheme.gold.withOpacity(0.16)
            : AurumTheme.gold.withOpacity(0.10));

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _opacity,
        builder: (_, __) {
          final opacity = song != null ? _opacity.value : 1.0;
          return Opacity(
            opacity: opacity,
            child: SizedBox(
              height: isDark ? 220 : 240,
              width: double.infinity,
              child: _GlowPainter(color: effectiveColor, isDark: isDark),
            ),
          );
        },
      ),
    );
  }
}

// CustomPainter — single radial gradient blob at the top center.
// Cheaper than a Container with BoxDecoration because it skips the
// layout pass entirely.
class _GlowPainter extends StatelessWidget {
  final Color color;
  final bool isDark;
  const _GlowPainter({required this.color, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GlowBlobPainter(color, isDark));
  }
}

class _GlowBlobPainter extends CustomPainter {
  final Color color;
  final bool isDark;
  _GlowBlobPainter(this.color, this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    if (color == Colors.transparent) return;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topCenter,
        radius: 1.1,
        colors: isDark
            ? [color.withOpacity(0.30), color.withOpacity(0.10), Colors.transparent]
            : [color.withOpacity(0.22), color.withOpacity(0.08), Colors.transparent],
        stops: const [0.0, 0.4, 1.0],
      ).createShader(Rect.fromLTWH(0, -size.height * 0.3, size.width, size.height * 0.9));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_GlowBlobPainter old) => old.color != color || old.isDark != isDark;
}

// ─────────────────────────────────────────────────────────────────────────────
// Online Content
// ─────────────────────────────────────────────────────────────────────────────

class _OnlineContent extends StatelessWidget {
  final List<SongSection> sections;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  // Injected mid-feed instead of stacked after everything — see call site
  // comment for why (YT Music / Spotify both surface an artist row roughly
  // halfway down the home feed, never as a trailing afterthought section).
  final Widget artistStrip;

  const _OnlineContent({
    required this.sections,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.artistStrip,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _buildShimmer(context);
    if (sections.isEmpty) {
      return _buildError(
        context,
        message: error ?? AppLocalizations.of(context)!.homeCouldntLoadSongsRetry,
      );
    }
    // MIDDLE INSERTION: floor(n/2) puts the strip after roughly the first
    // half of sections regardless of how many streamed in this session (YT
    // Music's home-shelf count varies run to run) — e.g. 6 sections → after
    // section 3, 5 sections → after section 2. Always leaves at least one
    // section on each side so it never collapses to "first" or "last".
    final midpoint = (sections.length / 2).floor().clamp(1, sections.length);
    return Column(
      children: [
        for (int i = 0; i < sections.length; i++) ...[
          _StaggeredSection(
            // PERF FIX (cold-start "lag until refresh finishes"): keyed by
            // the section's own stable id, not its list position, so
            // Flutter's element diffing can match old/new widgets by
            // identity instead of rebuilding the whole Column subtree on
            // every single onSection setState in _loadOnline() (up to
            // ~20 back-to-back rebuilds while cached content is already
            // on screen). Each streamed-in section now only touches its
            // own subtree.
            // CRASH FIX: sections list can update mid-scroll
            key: ValueKey(i < sections.length ? sections[i].id : 'empty_$i'),
            sectionId: i < sections.length ? sections[i].id : '',
            child: i < sections.length ? _buildSection(context, sections[i]) : const SizedBox.shrink(),
          ),
          if (i + 1 == midpoint) artistStrip,
        ],
      ],
    );
  }

  Widget _buildShimmer(BuildContext context) {
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

  Widget _buildError(BuildContext context, {String? message}) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_off_rounded, size: 48,
              color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(
            message ?? error ?? AppLocalizations.of(context)!.homeFailedToLoad,
            textAlign: TextAlign.center,
            style: TextStyle(color: AurumTheme.textMutedOf(context)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            child: Text(AppLocalizations.of(context)!.commonRetry, style: TextStyle(color: AurumTheme.gold)),
          ),
        ]),
      ),
    );
  }

  // Each dynamic home section (Made for You / mood / genre mixes from
  // fetchHome) renders as a horizontal row of square per-song cards
  // (_SongGridCard) — Spotify's "Popular radio" / "Featured Charts" shelf
  // style. Title + artist sit BELOW the artwork, never overlaid on top of
  // it. A "See all" link opens the full mix in MixScreen; tapping any
  // individual card plays that song with the rest of the section as queue.
  Widget _buildSection(BuildContext context, SongSection section) {
    return _SongSectionRow(section: section);
  }
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
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  section.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    AurumHaptics.selection();
                    final art = section.songs
                        .where((s) => s.artworkUrl.isNotEmpty)
                        .map((s) => s.artworkUrl)
                        .firstOrNull ?? '';
                    // FIX ("navigation feels inconsistent"): this was the
                    // one flat "See all" tap in the app still using a plain
                    // MaterialPageRoute — default Android transition, not
                    // Aurum's 350ms fade+slide every other direct
                    // navigation (Library sections, other "See all" rows,
                    // etc.) uses. Switched to AurumPageRoute.to so this
                    // matches the rest of the app and respects the "Back
                    // Animations" setting like everything else does.
                    AurumDepthRoute.to(
                      context,
                      MixScreen(
                        mixId: section.id,
                        mixName: section.title,
                        artworkUrl: art,
                        emoji: '🎵',
                        songs: section.songs,
                      ),
                    );
                  },
                  // Own padded hit area (not just the text glyph bounds) so
                  // the tap target is consistently reachable and gives
                  // immediate ripple feedback — a "See all" mis-tap/no-op
                  // used to be the row's least reliable interaction.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(
                      'See all',
                      style: TextStyle(
                        color: AurumTheme.gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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

class _SongGridCard extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongGridCard({required this.song, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    // PERF: isolates each horizontally-scrolling card into its own
    // compositor layer — same reasoning as SongTile/the followed-albums
    // grid. These rows can hold up to 12 cards each and there are several
    // per Home screen, so this adds up on weaker devices during scroll.
    return RepaintBoundary(
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
                child: AurumArtwork(url: song.artworkUrl, size: 152, borderRadius: 0),
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
      duration: const Duration(milliseconds: 420),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.10),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
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
    // Aurum's own in-app downloads (DownloadProvider/Hive) are a SEPARATE
    // source from the raw device MediaStore scan LibraryProvider does —
    // songs downloaded through the app never show up in `lib.allSongs`
    // unless MediaStore also happens to index that exact file. Without
    // this, "Downloaded" content the user got FROM Aurum itself (the most
    // likely thing they'd expect to see first) was invisible on offline
    // Home — only songs picked up by a raw folder scan showed at all.
    final downloads = context.watch<DownloadProvider>().completed;

    final libLoading = lib.status == LibraryStatus.idle || lib.status == LibraryStatus.loading;
    if (libLoading && downloads.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: const Center(child: AurumMorphLoader(size: 56)),
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
    // local file) shouldn't also appear a second time as an "Aurum
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

    // Aurum's own downloads lead the page — most-recently-downloaded
    // first (DownloadProvider.completed is already sorted newest-first),
    // same "your most recent activity surfaces first" logic the online
    // feed's own "Because You Played" row follows.
    // NOTE (l10n): "Downloaded on Aurum" is a brand name + fixed English
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
        SongSection(id: 'aurum_downloads', title: 'Downloaded on Aurum', songs: appDownloadedSongs),
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
            Icon(Icons.download_done_rounded, color: AurumTheme.gold, size: 16),
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
            child: Text(label, style: TextStyle(color: AurumTheme.gold)),
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
        emoji: '📁',
        songs: section.songs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    return Padding(
      padding: const EdgeInsets.only(top: 24, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  section.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _openMix(context),
                  // FIX: hardcoded English on this new offline row — reuses
                  // the app's existing commonSeeAll key (already defined
                  // across all 16 locale .arb files) instead of introducing
                  // another un-translated string, matching how every
                  // localized label elsewhere in this file is sourced.
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(
                      AppLocalizations.of(context)!.commonSeeAll,
                      style: TextStyle(
                        color: AurumTheme.gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
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
                    parent: animation, curve: Curves.easeOutCubic)),
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
            gradient: AurumTheme.goldGradient,
          ),
          padding: const EdgeInsets.all(1.5),
          child: ClipOval(
            child: avatarUrl != null
                ? CachedNetworkImage(
                    imageUrl: avatarUrl,
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
    final dotColor = isOnline ? AurumTheme.gold : AurumTheme.textMutedOf(context);

    return AurumPressable(
      scaleAmount: 0.96,
      onTap: widget.onTap,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: AurumTheme.bgCardOf(context).withOpacity(0.6),
            border: Border.all(
              color: AurumTheme.dividerOf(context),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: isOnline
                      ? [BoxShadow(color: dotColor.withOpacity(0.55), blurRadius: 5)]
                      : [],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                isOnline ? AppLocalizations.of(context)!.homeOnline : AppLocalizations.of(context)!.homeOffline,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
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

class _SourceSheet extends StatelessWidget {
  final SourceProvider src;
  const _SourceSheet({required this.src});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bg = AurumTheme.bgCardOf(context);
    final border = AurumTheme.dividerOf(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
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
                      onTap: () {
                        if (!src.isOnline) src.toggle();
                        Navigator.pop(context);
                      },
                    ),
                    const SizedBox(height: 10),
                    _SourceOption(
                      icon: Icons.phone_iphone_rounded,
                      label: AppLocalizations.of(context)!.homeOfflineLibrary,
                      subtitle: AppLocalizations.of(context)!.homeOfflineLibraryDesc,
                      selected: !src.isOnline,
                      onTap: () {
                        if (src.isOnline) src.toggle();
                        Navigator.pop(context);
                      },
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
  const _SourceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
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
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.selected
                ? AurumTheme.gold.withOpacity(0.12)
                : AurumTheme.bgElevatedOf(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.selected
                  ? AurumTheme.gold.withOpacity(0.5)
                  : AurumTheme.dividerOf(context),
              width: 1,
            ),
          ),
          child: Row(children: [
            Icon(widget.icon,
                size: 20,
                color: widget.selected
                    ? AurumTheme.gold
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
              Icon(Icons.check_circle_rounded, size: 18, color: AurumTheme.gold),
          ]),
        ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Recently Played — square art tiles of the user's own play history, tap to
// play directly (unlike every other row on this page, these are individual
// songs, not a mix/album to open — so no MixScreen navigation here).
// ─────────────────────────────────────────────────────────────────────────────

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
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
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
              itemBuilder: (_, i) => AurumPressable(
                scaleAmount: 0.96,
                onTap: () {
                  // SPOTIFY-STYLE FIX ("kahi se bhi full player na
                  // khule"): tap now only starts playback.
                  player.playSong(songs[i], queue: songs, index: i);
                },
                child: Container(
                  width: 130,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AurumArtwork(
                            url: songs[i].artworkUrl, size: 260, borderRadius: 12),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        songs[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        songs[i].artist,
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
  // Own controller (not a stray one allocated fresh in build) so it's
  // created once and disposed once — same pattern as every other
  // scrollable section in this file (see the song-card carousel's own
  // controller for the fuller rationale on why this matters for a
  // horizontal list that can rebuild often on Home).
  late final ScrollController _scrollController = ScrollController();

  // Cap how many chips render on Home — this is a taste/discovery
  // section, not the full artist library (that's Search / Library).
  static const int _maxShown = 10;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          // COMPACT HORIZONTAL STRIP: a full-width list of 6-10 artist
          // rows was taking up nearly a full screen of vertical space on
          // Home before a person even reached New Releases / other
          // sections below it — same "too much scroll for one section"
          // problem a vertical grid would have. A horizontal scroll strip
          // (Spotify/YT Music's own "Popular artists" pattern) keeps the
          // section's footprint to a single fixed-height row while still
          // surfacing the same 10 artists — just swipeable instead of
          // stacked. Chips are sized up from the old 64px version (84px
          // avatar + name below) for a premium, not-cramped feel now that
          // there's no competing full-row layout to match widths with.
          FadedHorizontalList(
            height: 128,
            controller: _scrollController,
            fadeWidth: 12,
            child: loading
                ? _buildShimmer(context)
                : artists.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        controller: _scrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        cacheExtent: 500,
                        itemCount: artists.take(_maxShown).length,
                        itemBuilder: (_, i) => _ArtistChip(
                          key: ValueKey(artists[i].id),
                          artist: artists[i],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        itemBuilder: (_, __) => Container(
          width: 86,
          margin: const EdgeInsets.only(right: 16),
          child: Column(children: [
            // FIX (white flash — same root cause as elsewhere in this
            // file): Shimmer.fromColors only sweeps a gradient OVER this
            // base color, it doesn't replace it. Using the theme's own
            // card color (not Colors.white) keeps a dropped/late shimmer
            // frame looking correct against the dark theme.
            CircleAvatar(radius: 42, backgroundColor: AurumTheme.bgCardOf(context)),
            const SizedBox(height: 8),
            Container(
              width: 60, height: 11,
              decoration: BoxDecoration(
                color: AurumTheme.bgCardOf(context),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ]),
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

    return AurumPressable(
      scaleAmount: 0.94,
      onTap: () => _open(context),
      child: Container(
        width: 86,
        margin: const EdgeInsets.only(right: 16),
        child: Column(
          children: [
            AurumStackedArtwork(
              url: artist.imageUrl,
              size: 84,
              circular: true,
              showNowPlaying: isCurrentArtist,
              isPlaying: isActuallyPlaying,
              stackColor: AurumTheme.gold,
            ),
            const SizedBox(height: 8),
            Text(
              artist.name,
              style: TextStyle(
                color: isCurrentArtist
                    ? AurumTheme.gold
                    : AurumTheme.textPrimaryOf(context),
                fontSize: 12.5,
                fontWeight: isCurrentArtist ? FontWeight.w700 : FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
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
class _YtPlaylistsForYouSection extends StatefulWidget {
  final int refreshKey;
  const _YtPlaylistsForYouSection({this.refreshKey = 0});

  @override
  State<_YtPlaylistsForYouSection> createState() =>
      _YtPlaylistsForYouSectionState();
}

// Sentinel id for the always-present default chip — the personalized-
// seed + generic-shelf mix this row showed before mood chips existed.
// Kept selected by default (never an "unselected" chip state) so the
// row never has a beat where nothing is highlighted — same reasoning
// as Spotify/Echo always showing one active pill.
const String _kMoodAll = '_all';

class _YtPlaylistsForYouSectionState
    extends State<_YtPlaylistsForYouSection> {
  List<YtHomePlaylistCard>? _cards;
  bool _failed = false;
  bool _everLoadedOnce = false;
  String _selectedMood = _kMoodAll;

  // BUG FIX ("app fasna / scroll atakna over time" — memory leak):
  // this ScrollController used to be created fresh inside build() —
  // `final scrollController = ScrollController();` — every single
  // rebuild. Since this is a StatefulWidget whose build() re-runs on
  // every mood-chip tap (_onMoodTap → setState) and every pull-to-
  // refresh (didUpdateWidget), each of those rebuilds allocated a brand
  // new controller and abandoned the previous one without ever calling
  // .dispose() on it — a genuine, unbounded memory leak that gets worse
  // the more the user interacts with this row (switches moods, pulls to
  // refresh) across a session. Each abandoned controller also leaves its
  // ScrollPosition/listener machinery alive in memory doing nothing.
  // Moved to a State field created once in initState and disposed once
  // in dispose(), matching every other ScrollController in this file.
  late final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_YtPlaylistsForYouSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pull-to-refresh bumps refreshKey — refetch so this row rotates
    // along with every other section on refresh instead of staying
    // stale. Refresh keeps whatever mood was selected rather than
    // silently resetting it back to "All".
    if (oldWidget.refreshKey != widget.refreshKey) {
      setState(() {
        _cards = null;
        _failed = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      // NO-REPEAT: skip song ids already shown recently under THIS
      // SPECIFIC mood (persisted across sessions, scoped per-mood — see
      // HomePlaylistHistory), so refresh and mood switches actually
      // surface something new instead of looping the same handful of
      // songs, without one mood's history ever being able to starve a
      // different mood's (often much smaller) result pool.
      final currentMood = _selectedMood == _kMoodAll ? null : _selectedMood;
      final excludeIds = await HomePlaylistHistory.getShownIds(currentMood);
      final cards = await ApiService.fetchYtMusicHomePlaylists(
        limit: 10,
        mood: currentMood,
        excludeIds: excludeIds,
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (cards.isEmpty) {
        setState(() => _failed = true);
      } else {
        setState(() {
          _cards = cards;
          _failed = false;
          _everLoadedOnce = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onMoodTap(String moodId) {
    if (moodId == _selectedMood) return;
    AurumHaptics.selection();
    setState(() {
      _selectedMood = moodId;
      _cards = null;
      _failed = false;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to show and nothing coming — skip the whole section
    // rather than leaving an empty-but-titled row on screen. Matches
    // how other optional sections on this screen (e.g. offline row)
    // handle the no-content case. Mood chips only render once there's
    // at least been a successful load, so a first-load failure never
    // shows a row of chips above an empty shelf.
    // FIX (2026-08-14 — "Bollywood ya koi mood choose karne pe poora
    // section invisible ho jaata tha"): pehle yahan condition thi
    // `_failed && _cards == null`, jo TRUE ho jaati thi har baar jab
    // koi mood switch fail/khaali result deta — kyunki _onMoodTap()
    // mood switch karte hi _cards ko null kar deta hai (line ~3206),
    // aur agar us mood ka fetch fail ho, poora row shrink ho jaata,
    // as if section exist hi nahi karta. Ab hum sirf VERY FIRST load
    // (jab koi mood kabhi successfully load hi nahi hua, matlab "All"
    // khud fail ho gaya) pe hi poora section chhupate hain — kisi bhi
    // baad ke mood switch ke fail hone pe row visible rehta hai aur
    // ek proper "retry" state dikhata hai (neeche build me), jaisa
    // Spotify/YT Music khud karte hain — section gayab nahi hota.
    if (_failed && _cards == null && !_everLoadedOnce) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final cards = _cards;

    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 12, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.homePlaylistsForYou,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 12),
          _MoodChipRow(
            selectedMood: _selectedMood,
            onTap: _onMoodTap,
          ),
          const SizedBox(height: 12),
          FadedHorizontalList(
            height: 130,
            controller: _scrollController,
            child: cards == null
                ? (_failed
                    ? _YtPlaylistsForYouRetry(onRetry: _load)
                    : _YtPlaylistsForYouSkeleton(
                        scrollController: _scrollController))
                : ListView.builder(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    cacheExtent: 600,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: cards.length,
                    itemBuilder: (_, i) => _YtHomePlaylistCardWidget(
                      key: ValueKey(
                          '${cards[i].id}_${widget.refreshKey}_$_selectedMood'),
                      card: cards[i],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Mood chip row — Podcasts/Relax/Workout/Energize/etc, plus an always-
// present "All" chip first. One chip is always selected (never a bare/
// unselected row), matching the reference apps this row is modeled on.
// Pure presentational row; all state lives in the parent section.
// ══════════════════════════════════════════════════════════════════
class _MoodChipRow extends StatelessWidget {
  final String selectedMood;
  final ValueChanged<String> onTap;
  const _MoodChipRow({required this.selectedMood, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final chips = <HomeMoodChip>[
      HomeMoodChip(_kMoodAll, l10n.homeMoodAll),
      ...kHomeMoodChips,
    ];
    return SizedBox(
      height: 34,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(right: 12),
        // PERF: mood chips are cheap (AnimatedContainer + Text, no
        // network image), but caching a little extra off-screen width
        // still avoids a build/layout hitch on the very first frame a
        // low-end device scrolls this row fast — matches the cacheExtent
        // used on every other horizontal list in this file for
        // consistency, even though the cost here is small either way.
        cacheExtent: 300,
        itemCount: chips.length,
        itemBuilder: (_, i) {
          final chip = chips[i];
          final selected = chip.id == selectedMood;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onTap(chip.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  chip.label,
                  style: TextStyle(
                    color: selected
                        ? Theme.of(context).colorScheme.onPrimary
                        : AurumTheme.textPrimaryOf(context).withOpacity(0.85),
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _YtPlaylistsForYouSkeleton extends StatelessWidget {
  final ScrollController scrollController;
  const _YtPlaylistsForYouSkeleton({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
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

class _YtHomePlaylistCardWidget extends StatefulWidget {
  final YtHomePlaylistCard card;
  const _YtHomePlaylistCardWidget({super.key, required this.card});

  @override
  State<_YtHomePlaylistCardWidget> createState() =>
      _YtHomePlaylistCardWidgetState();
}

class _YtHomePlaylistCardWidgetState
    extends State<_YtHomePlaylistCardWidget> {
  bool _pressed = false;

  // REWRITTEN (2026-08-14): the card's songs are already fully resolved
  // Song objects by the time this widget exists (see
  // ApiService.fetchYtMusicHomePlaylists) — there's no playlist id to
  // "import" anymore, so this is now just a direct navigation, exactly
  // like every other mix/playlist tile elsewhere in this app. No
  // loading snackbar, no failure state, no async gap at all.
  void _open() {
    AurumHaptics.selection();
    AurumDepthRoute.to(
      context,
      MixScreen(
        mixId: widget.card.id,
        mixName: widget.card.title,
        artworkUrl: widget.card.artworkUrl,
        emoji: '🎵',
        songs: widget.card.songs,
        // Only this call site (the "Playlists For You" card tap) turns
        // pull-to-refresh on — the other 2 MixScreen pushes in this
        // file and the one in library_screen.dart don't pass this, so
        // they're completely unaffected. refreshSeed uses the card's
        // own title so a refresh pulls more songs matching that
        // specific category rather than a generic query.
        enableRefresh: true,
        refreshSeed: widget.card.title,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.card;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _open,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: Container(
          width: 130,
          margin: const EdgeInsets.only(right: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (c.artworkUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: c.artworkUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 260,
                    memCacheHeight: 260,
                    placeholder: (_, __) => Container(
                      color: AurumTheme.bgCardOf(context),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: AurumTheme.bgCardOf(context),
                    ),
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
                        Colors.black.withOpacity(0.75),
                      ],
                      stops: const [0.4, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: Text(
                    c.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
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
                  color: AurumTheme.gold.withOpacity(0.3),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.08),
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
                      AurumTheme.goldDark,
                      AurumTheme.goldLight,
                      AurumTheme.gold,
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
                            AurumTheme.goldDark,
                            AurumTheme.goldLight,
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
                          color: AurumTheme.gold.withOpacity(0.55),
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
                    gradient: AurumTheme.goldGradient,
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

