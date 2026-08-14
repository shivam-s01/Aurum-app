import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../main.dart' show aurumRouteObserver;
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../utils/artwork_palette_cache.dart';
import '../utils/aurum_transitions.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:share_plus/share_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/download_provider.dart';
import '../providers/premium_provider.dart';
import '../providers/theme_provider.dart';
import '../models/song.dart';
import '../models/lyrics.dart';
import '../utils/devanagari_transliterator.dart';
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/audio_prefs.dart';
import '../services/waveform_service.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/premium_gate.dart';
import 'library_screen.dart' show showAddToPlaylistSheet;
import '../widgets/audio_output_sheet.dart';
import '../widgets/cast_button.dart';
import 'settings_player_screen.dart' show SleepTimerService, SleepTimerSheet, EqualizerScreen;
import '../utils/aurum_haptics.dart';

// ═══════════════════════════════════════════════════════════════════════
// NOTICE FOR ANY FUTURE EDITS TO THIS FILE (human or AI assistant):
//
// This file previously carried a `_kDebugFullPlayerWhiteLayer2` flag and a
// `_debugFlashBanner2()` on-screen banner helper, used together with
// matching debug tooling in home_screen.dart to hunt the "Full Player
// swipe-dismiss / close leaves a gray/black layer stuck over the whole
// screen" bug. That bug is now diagnosed and fixed — the real fix lives in
// home_screen.dart's `_FullPlayerRouteBackdrop` (see the notice at the top
// of that file for the full root-cause writeup). ALL debug-only code has
// been removed from this file — it was diagnostic scaffolding, not part of
// the fix, and left in a release build it's dead weight that also
// visibly flashes an orange banner over real user content.
//
// DO NOT reintroduce this debug flag/banner to "help verify" a related
// bug. If a similar full-screen overlay issue resurfaces, check
// home_screen.dart's _FullPlayerRouteBackdrop first (see the notice
// there). If new diagnostics are genuinely needed here, gate them behind
// `kDebugMode` (from package:flutter/foundation.dart), never a
// hand-rolled `const bool _kDebugXxx = true` — and remove them again once
// the bug is closed, don't leave them "temporarily" in a release build.
// ═══════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// FullPlayerScreen v5.0 — Echo Nightly Premium
// Changes from v4.3:
//   • _BgLayer: 3-color palette extraction (vibrant + dominant + dark muted)
//   • _BgLayer: breathing gradient animation via _breatheCtrl (4s loop)
//   • _BgLayer: blur sigma reduced 60→50 for lighter GPU load
//   • _showOptions: replaced basic list with premium grid sheet (JioSaavn style)
//   • _QueuePage: Echo Nightly style — "Now Playing" header, gradient tiles
//   • _QueueTile: album art, gradient highlight on current, cleaner layout
//   • _PremiumOptionsSheet: new widget — 2-col grid, song header, all actions
// ─────────────────────────────────────────────────────────────────────────────

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {

  // ── Entry animation (420ms, easeOutCubic) ──
  // Note: entry slide/fade used to be driven by an internal _entryCtrl
  // here, stacked on top of the route's own PageRouteBuilder transition
  // (see mini_player.dart / home_screen.dart / search_screen.dart /
  // song_tile.dart, all standardized to a 380ms slide-up / 300ms
  // slide-down). That meant every open played TWO slide-in animations
  // back to back with different durations/curves, and every close played
  // a 480ms internal reverse THEN a separate 300ms route-pop reverse
  // (~780ms total) — the double-animation is what read as "awkward, not
  // premium". Removed: the route transition is now the single source of
  // truth for open/close motion, and _close() below just pops instead of
  // running its own reverse first.

  // ── Staggered entry: info, seekbar, controls fade in after artwork ──
  late final AnimationController _staggerCtrl;
  late final Animation<double> _infoStagger;
  late final Animation<double> _seekStagger;
  late final Animation<double> _ctrlStagger;

  // ── Song change: title cross-fade ──
  late final AnimationController _titleChangeCtrl;
  late final Animation<double> _titleFadeAnim;
  late final Animation<Offset> _titleSlideAnim;

  // ── Artwork scale on play/pause/song change ──
  late final AnimationController _artworkCtrl;
  late final Animation<double> _artworkAnim;

  // ── Play button tactile scale (110ms) ──
  late final AnimationController _playBtnCtrl;
  late final Animation<double> _playBtnAnim;

  // ── Background color morphing (700ms) ──
  late final AnimationController _bgColorCtrl;
  Color _targetBg1 = const Color(0xFF0D0D18);
  Color _targetBg2 = const Color(0xFF060608);
  Color _targetBg3 = const Color(0xFF030305);
  Color _targetBg4 = const Color(0xFF0A0A14);
  Color _currentBg1 = const Color(0xFF0D0D18);
  Color _currentBg2 = const Color(0xFF060608);
  Color _currentBg3 = const Color(0xFF030305);
  Color _currentBg4 = const Color(0xFF0A0A14);

  // ── Breathing gradient (12s loop, reverse) ──
  // PERF FIX (godmode recheck — dead controller ticking forever in the
  // background): this field used to be `late final AnimationController
  // _breatheCtrl`, allocated in initState and restarted via
  // `.repeat(reverse: true)` inside _resumeAmbientAnims() — which fires
  // on every app foreground AND every Up Next panel close while the full
  // player is open. The Ken Burns pan/zoom it originally drove was
  // already removed from _StaticBlurArtwork/_BgLayer in an earlier pass
  // (nothing in this file reads breatheCtrl.value anymore — the
  // "breatheCtrl (an 18s loop)" and "the only remaining motion is the Ken
  // Burns drift already living inside staticBlur" comments elsewhere in
  // this file were stale leftovers from before that removal). So this
  // was a genuinely running 9s-loop AnimationController ticking at 60fps
  // for however long the session stays on this screen, for a value
  // nothing ever consumed — pure wasted CPU/battery, worse the longer a
  // listening session runs and worse on low-end devices. Removed
  // entirely below (declaration, initState allocation, dispose call, the
  // .stop()/.repeat() calls in _pauseAmbientAnims/_resumeAmbientAnims,
  // and the now-unused breatheCtrl parameter threaded through _BgLayer /
  // _StaticBlurArtwork) — zero allocation, zero vsync registration, zero
  // ticks.

  // ── Artwork float (5.5s loop, reverse) ──

  // ── Swipe-down to dismiss / swipe-up to open panel ──
  //
  // PERF FIX (drag felt heavy/stuttery, not "finger-following" smooth):
  // this used to be a plain `double _dragY` field, mutated via
  // `setState(() => _dragY += ...)` on every single onVerticalDragUpdate
  // callback — which reruns this whole State's build() method (the
  // entire full player: background, artwork, controls, seekbar, info,
  // everything) up to 60 times/sec while a finger is moving. Native
  // code doing the equivalent gesture only ever moves one small
  // transform layer, never rebuilds an entire screen's widget tree per
  // touch-move event — that gap is what actually reads as "stuttery"
  // rather than a smooth finger-following drag. Moved to a ValueNotifier
  // so only the thin Transform/Opacity wrapper around the screen (see
  // _DragTransform below) listens and rebuilds; the rest of the screen's
  // widget subtree is built exactly once per drag gesture, not once per
  // frame of it.
  final ValueNotifier<double> _dragYNotifier = ValueNotifier(0.0);
  double get _dragY => _dragYNotifier.value;
  set _dragY(double v) => _dragYNotifier.value = v;
  bool _isDragging = false;
  bool _dragIsUpward = false;
  // Tracks how far the finger has moved upward during this gesture, purely
  // for the release-time "did they mean to open Up Next" threshold check
  // below. Deliberately NOT applied to _dragY / screen position (see
  // onVerticalDragUpdate) — this fixes the full player visibly sliding up
  // while swiping to open Up Next.
  double _upwardDragDistance = 0;

  // ── Spring-back after a cancelled drag ──
  // Previously a cancelled drag (released before crossing the dismiss
  // threshold) snapped _dragY straight to 0 via setState with no
  // animation at all — visually a hard jump/jerk. This controller
  // animates that snap-back smoothly instead.
  late final AnimationController _springBackCtrl;
  // Tracks whether _springBackCtrl's CURRENT run is a committed dismiss
  // (_completeDismissDrag, animating _dragY toward screenH then popping)
  // versus a cancelled-drag spring-back (_springBackDrag, animating _dragY
  // back to 0, staying open) — both reuse the same controller, so the
  // lifecycle-pause fix below needs this to tell them apart: a committed
  // dismiss should still be allowed to finish and pop even if the app is
  // backgrounded mid-animation, but a spring-back-to-open should not.
  bool _springBackIsDismissing = false;

  // ── Palette / song cache ──
  String? _lastArtUrl;
  String? _lastSongId;
  // Tracks the theme mode _extractColor last ran for — lets build() detect
  // a live dark/light toggle independent of song changes (see the bug fix
  // note above the extraction-trigger block in build()). Starts null so
  // the very first build always counts as "no prior mode" rather than
  // false-triggering a spurious "theme changed" re-extraction.
  bool? _lastIsLight;
  // Distinguishes "screen just opened" from "song changed while this
  // screen was already open" — see the skip of _triggerArtworkAnimation()
  // in build() below for why this matters.
  bool _isFirstBuild = true;

  // Bumped every time _extractColor is (re)triggered by a song change.
  // Palette extraction is async (PaletteGenerator awaits an image decode),
  // so on very fast song switching, an OLDER song's extraction can finish
  // AFTER a newer one's — e.g. song A's decode is slow, song C's is fast,
  // so C's colors land first and A's then overwrite them a moment later.
  // That read as the background trailing behind what the UI (artwork/
  // title) was already showing on rapid skips. Only the extraction whose
  // captured generation still matches the current one when it completes
  // is allowed to commit its colors — every stale, superseded one is
  // silently discarded, however late it finishes.
  int _artGen = 0;
  // Bumped every time the title cross-fade is (re)triggered — guards the
  // chained reverse().then(forward()) below so a stale completion from an
  // earlier, now-superseded skip can never fire its .forward() after a
  // newer skip has already started its own reverse, which under fast
  // spam-skipping could otherwise interleave and leave the title
  // mid-fade/stuck instead of cleanly settled on the current song.
  int _titleGen = 0;

  // ── Favourite toggle (local) ──
  // NOTE: local _isFav bool removed — liked state now reads/writes directly
  // through FavoritesProvider (see _SongInfo's onFavTap wiring below),
  // which is the single real source of truth already used everywhere else
  // (mini player, bottom sheet actions).

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Entry slide/fade now handled entirely by the route's own
    // PageRouteBuilder transition — see note above _entryCtrl's old
    // declaration for why the internal copy was removed.

    // SPEED FIX (Spotify-level instant open): this was 520ms, staggering
    // info/seekbar/controls in AFTER the route's own 380ms slide-up had
    // already finished — meaning the screen looked "open" but content was
    // still visibly fading in for another beat on top of that, exactly
    // what reads as "abhi bhi load ho raha hai" even though nothing was
    // actually still loading. Spotify/YT Music show all player chrome
    // already fully in place the instant the sheet finishes sliding up —
    // no separate content fade-in after. Shortened to load well inside
    // the route transition instead of trailing past it, so by the time
    // the slide-up settles everything is already fully visible.
    _staggerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _infoStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.18, 0.75, curve: Curves.easeOutCubic)));
    _seekStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.30, 0.85, curve: Curves.easeOutCubic)));
    _ctrlStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic)));
    _staggerCtrl.forward();

    // Song title cross-fade on track change
    _titleChangeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _titleFadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _titleChangeCtrl, curve: Curves.easeOut));
    _titleSlideAnim = Tween<Offset>(
            begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _titleChangeCtrl, curve: Curves.easeOutCubic));
    _titleChangeCtrl.value = 1.0; // starts fully visible

    _artworkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _artworkAnim = Tween<double>(begin: 0.94, end: 1.0)
        .animate(CurvedAnimation(parent: _artworkCtrl, curve: Curves.easeOutCubic));
    // FIX (first-open scale-pop) — the comment above _staggerCtrl says the
    // intent is "artwork appears with entry" (i.e. already settled,
    // riding in with the route's own 380ms slide-up), while info/seekbar/
    // controls are the ones that stagger in afterward. But
    // AnimationController defaults to value=0.0, so _artworkAnim actually
    // read 0.94x on this screen's very first built frame — before the
    // addPostFrameCallback in build() reaches _triggerArtworkAnimation()
    // and calls forward(). That's a real (if brief) extra "pop" from
    // 0.94x→1.0x layered on top of the slide transition, which reads as
    // slightly less solid than a paid-app open should. Starting at 1.0
    // (matching _titleChangeCtrl's identical pattern just above) makes
    // the artwork already at rest for that first frame, exactly matching
    // the stated design — the 0.94→1.0 motion is then purely what plays
    // on an actual in-screen song change (skip/tap), which is what
    // _triggerArtworkAnimation()'s forward(from: 0.0) is actually for.
    _artworkCtrl.value = 1.0;

    _playBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );
    _playBtnAnim = Tween<double>(begin: 1.0, end: 0.87)
        .animate(CurvedAnimation(parent: _playBtnCtrl, curve: Curves.easeInOut));

    _bgColorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    // NOTE: the old "artwork float" controller (idle 6s up/down drift on
    // the artwork) has been removed entirely — not just stopped. The
    // artwork now stays fully pinned in place (premium/paid-app style),
    // so there's no controller to allocate, tick, or dispose for it at
    // all — one less AnimationController running in this screen's tree.

    // SPEED FIX (Spotify-level instant open) + PERF FIX (godmode
    // recheck): the Ken Burns breathe loop (_breatheCtrl) that used to be
    // allocated here was removed entirely — see the field's own FIX
    // comment above for the full history. Nothing in this screen reads
    // it anymore, so there's nothing left to allocate, tick, pause/resume,
    // or dispose for it at all.

    _springBackCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    // NOTE: no unconditional `setState(() {})` listener here anymore —
    // _springBackDrag below drives _dragYNotifier directly during the
    // spring-back animation, which only rebuilds the thin drag-transform
    // wrapper (see _DragTransform), not this whole State's build().

    // FIX ("cold start: play a song, open full player, artwork is black
    // for a beat"): mini_player.dart's tap handler precaches the 220px
    // hero decode BEFORE pushing the route, but that's only reachable
    // when a mini player widget actually existed to be tapped. On a true
    // cold start (app process was killed, user opens app and playback +
    // full player come up together, e.g. via notification/deep link/auto-
    // resume) there's no prior tap to hook — FullPlayerScreen is simply
    // the first screen with this song's URL anywhere in the widget tree,
    // so nothing has warmed the 220px memCacheWidth decode yet and
    // AurumArtwork's own shimmer placeholder is genuinely the first thing
    // that can show. Firing the same precache here, as the very first
    // thing this screen's initState does, means the decode starts
    // immediately alongside the 380ms entry transition instead of only
    // starting once AurumArtwork itself builds a frame later. Deferred
    // one frame via addPostFrameCallback because `context` isn't safe to
    // read Provider from synchronously inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final url = context.read<PlayerProvider>().currentSong?.artworkUrl;
      if (url != null &&
          url.isNotEmpty &&
          !url.startsWith('content://') &&
          !url.startsWith('/') &&
          !url.startsWith('file://')) {
        precacheImage(
          CachedNetworkImageProvider(url, maxWidth: 220),
          context,
        ).catchError((_) {});
      }
    });
  }

  @override
  void dispose() {
    aurumRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _staggerCtrl.dispose();
    _titleChangeCtrl.dispose();
    _artworkCtrl.dispose();
    _playBtnCtrl.dispose();
    _bgColorCtrl.dispose();
    _springBackCtrl.dispose();
    _dragYNotifier.dispose();
    super.dispose();
  }

  /// Smoothly animates _dragY back to 0 after a cancelled drag, instead
  /// of snapping instantly. Uses an easeOutBack curve for a subtle
  /// "settle" feel rather than a linear slide.
  void _springBackDrag() {
    final start = _dragY;
    _springBackCtrl.reset();
    final anim = Tween<double>(begin: start, end: 0.0).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.easeOutCubic),
    );
    void listener() {
      if (!mounted) return;
      // Writing straight to the notifier — only whatever's listening to
      // _dragYNotifier (the thin drag-transform wrapper) rebuilds each
      // frame of the spring-back, not the entire screen.
      _dragY = anim.value;
    }

    anim.addListener(listener);
    _springBackCtrl.forward().whenCompleteOrCancel(() {
      anim.removeListener(listener);
      if (mounted) _dragY = 0;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause ambient/breathing animations whenever app isn't actively
    // visible on screen — no point burning GPU ticks while backgrounded,
    // locked, or in app-switcher.
    if (state == AppLifecycleState.resumed) {
      if (!_panelOpen) _resumeAmbientAnims();
    } else {
      _pauseAmbientAnims();
    }

    // FIX ("swipe down to dismiss, background/resume mid-drag — full
    // player left floating over stale content underneath, looks like two
    // overlapping layers"): the GestureDetector driving swipe-to-dismiss
    // (see onVerticalDragStart/Update/End further down) never wired an
    // onVerticalDragCancel — so if the app is backgrounded with a finger
    // still down mid-drag (Recents/home hit exactly while dismissing —
    // easy to do with a local/offline song, since it resolves instantly
    // with no network round-trip holding attention on the screen a moment
    // longer), neither onVerticalDragEnd nor any cancel path ever fires.
    // _isDragging and _dragY stay frozen at whatever partial value the
    // drag had reached, and _dragY directly drives _DragTransform's
    // translate/opacity on this whole screen — so resuming shows the full
    // player stuck mid-dismiss, translated and faded over whatever's
    // rendering underneath (exactly the "layer over old content" look).
    // Same root shape as the equivalent fix already applied to
    // mini_player.dart's own drag-to-dismiss for the same reason. Snap
    // back to fully-open immediately (no animation — the app isn't even
    // visible for one to be seen) rather than waiting on a pointer event
    // that may never arrive.
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) &&
        mounted &&
        (_isDragging ||
            (_dragY != 0 && !_springBackIsDismissing) ||
            (_springBackCtrl.isAnimating && !_springBackIsDismissing))) {
      // Stop any in-flight spring-back-to-open animation first —
      // otherwise its own listener (see _springBackDrag above) would
      // immediately overwrite the _dragY reset below on the next tick,
      // since AnimationControllers keep ticking even while the app is
      // backgrounded/paused. Deliberately NOT stopped when
      // _springBackIsDismissing is true — that run is a COMMITTED dismiss
      // (_completeDismissDrag) that still needs to finish and pop the
      // route even if the app is backgrounded mid-animation; killing it
      // here would instead leave the full player stuck open forever,
      // trading the original stuck-layer bug for a worse one.
      if (_springBackCtrl.isAnimating) _springBackCtrl.stop();
      _dragIsUpward = false;
      _upwardDragDistance = 0;
      _dragY = 0;
      if (_isDragging) setState(() => _isDragging = false);
    }
  }

  // ── RouteAware — pause ambient anims when a route is pushed on top ──
  // (lyrics screen, queue screen, options sheet, etc.)
  bool _didSeedInitialPalette = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    aurumRouteObserver.subscribe(this, ModalRoute.of(context)!);

    // FIX (black/neutral flash before color loads on first open) — this
    // screen used to always paint its very first frame with the hardcoded
    // near-black defaults on _currentBg1..4 / _targetBg1..4, because color
    // extraction only ever kicked off inside build()'s
    // addPostFrameCallback — a whole frame after first paint, PLUS
    // whatever the async palette decode took on top. On a cache miss
    // that's a very visible "opens black/flat, then the real color pops
    // in a beat later" — the opposite of Spotify/Echo, which open already
    // tinted because the artwork was pre-warmed while the mini-player was
    // still showing.
    //
    // Real fix: check the palette cache synchronously right here, before
    // this screen's first build() ever runs. _warmNextInQueue means the
    // song being opened has very often already had its palette extracted
    // and cached while the previous track was playing, so
    // ArtworkPaletteCache.peek() resolves instantly in the common case —
    // both _currentBg* and _targetBg* get seeded with the true color
    // before frame one, no morph animation needed for it at all. Only a
    // genuine cold cache falls through to the existing async path.
    if (!_didSeedInitialPalette) {
      _didSeedInitialPalette = true;
      // FIX (undefined_getter build error): FullPlayerScreen has no `song`
      // field of its own — it's driven entirely by PlayerProvider's
      // currentSong (see _buildBody / the Selector further down this
      // file), so `widget.song` was never a valid getter here and failed
      // to compile. The song being opened is PlayerProvider.currentSong.
      final currentSong = context.read<PlayerProvider>().currentSong;
      final url = currentSong?.artworkUrl ?? '';
      if (url.isNotEmpty && currentSong != null) {
        final cached = ArtworkPaletteCache.peek(url);
        if (cached != null) {
          // ROOT-CAUSE FIX (uniform gray/white wash, RGB~181, ~250-300ms,
          // full player open — confirmed via frame-by-frame recording):
          // this read Theme.of(context).brightness directly. theme_
          // provider.dart's isDarkOf() doc comment already explains why
          // that's unsafe: a route's own BuildContext, at the exact moment
          // it's first mounting (this runs inside initState, the earliest
          // possible build), isn't guaranteed to have a Theme ancestor
          // that's finished rebuilding with this frame's resolved isDark —
          // and Theme.of(context).brightness "silently defaults toward
          // light" when it can't resolve cleanly. That fix was already
          // applied to the route-level ColoredBox (pushFullPlayer in
          // home_screen.dart) and this screen's own outer Scaffold
          // backgroundColor — but this _BgLayer color-seeding call site,
          // which is what actually paints the large blurred background
          // behind the whole player, was missed in that pass. When it
          // silently resolved light for a frame, seeded1..4 all took the
          // light-mode branch (Color.lerp toward Colors.white) instead of
          // the correct dark branch — exactly a uniform light wash over
          // the still-forming player, composited under the SlideTransition
          // while it's still animating in, matching the observed uniform
          // ~181 gray (a light-tinted layer blended with the darker Home
          // frame still partially visible through the in-flight slide).
          // isDarkOf(context) is the same already-resolved boolean the
          // route ColoredBox and this screen's Scaffold already use —
          // asking it here instead closes the one remaining call site that
          // could still disagree with them for a frame.
          final isLight = !context.read<ThemeProvider>().isDarkOf(context);
          final c1 = cached.vibrant;
          final c2 = cached.dominant;
          final c3 = cached.darkMuted;
          final c4 = cached.lightVibrant;
          final seeded1 = isLight
              ? ensureContrastSafe(Color.lerp(c1, Colors.white, 0.16)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c1, Colors.black, 0.22)!, isLight: false);
          final seeded2 = isLight
              ? ensureContrastSafe(Color.lerp(c2, Colors.white, 0.10)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c2, Colors.black, 0.48)!, isLight: false);
          final seeded3 = isLight
              ? ensureContrastSafe(Color.lerp(c3, Colors.white, 0.04)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c3, Colors.black, 0.70)!, isLight: false);
          final seeded4 = isLight
              ? ensureContrastSafe(Color.lerp(c4, Colors.white, 0.20)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c4, Colors.black, 0.30)!, isLight: false);
          // Seed BOTH current and target to the same value — this is what
          // skips the morph entirely for the opening frame, since
          // _BgLayer lerps start→target by _bgColorCtrl.value (0.0 here).
          // Setting only target would still flash the old near-black
          // _currentBg on frame one, then visibly morph — same bug,
          // just relocated.
          _currentBg1 = seeded1;
          _currentBg2 = seeded2;
          _currentBg3 = seeded3;
          _currentBg4 = seeded4;
          _targetBg1 = seeded1;
          _targetBg2 = seeded2;
          _targetBg3 = seeded3;
          _targetBg4 = seeded4;
          // Keep the rest of the pipeline in sync so build()'s own
          // song-change detection doesn't immediately re-trigger a
          // redundant extraction+morph for the song that's already
          // correctly seeded.
          _lastSongId = currentSong.id;
          _lastIsLight = isLight;
          _lastArtUrl = url;
          // This seed path makes song.id == _lastSongId true for the
          // upcoming first build(), so that method's own song-changed
          // branch — which normally fires _warmNextInQueue() — never runs
          // for this open. Queue pre-warming still needs to happen on a
          // genuine first open, so trigger it here instead.
          _isFirstBuild = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _warmNextInQueue();
          });
        } else {
          // FIX ("full player opens on a near-black/flat background and
          // stays that way until the song finishes loading" — a genuinely
          // brand-new song, e.g. tapped for the very first time ever, has
          // no cached palette here for peek() to seed from at all). The
          // block above only handles the warm-cache case; on a true cold
          // cache this used to fall straight through to build()'s own
          // song-change branch, which only starts _extractColor() from an
          // addPostFrameCallback — a full frame after this screen's very
          // first paint — and _extractColor's own accurate-palette path
          // is a real quantization pass that can take the better part of
          // a second. Nothing filled that entire gap; the hardcoded
          // near-black _currentBg1..4 defaults sat on screen for all of
          // it, reading as "opens to black, then color pops in once the
          // song loads" — while the artwork image itself (which has its
          // own independent shimmer-then-fade-in) often finishes well
          // before that, making the mismatch even more obvious.
          //
          // Fix: fire the same fast average-color extraction
          // (ArtworkPaletteCache.getFast — a coarse sample, not a full
          // quantization pass) synchronously here, before first build(),
          // instead of waiting on build()'s post-frame callback. This
          // races the fast decode against the route's own 380ms slide-up
          // transition rather than starting it a frame+ late — by the
          // time the screen is fully visible there's very often already
          // a real (if approximate) tint on screen instead of the flat
          // default, with the accurate palette morphing in on top of it
          // moments later exactly as _applyPalette's `instant` path
          // already does elsewhere in this file.
          //
          // ROOT-CAUSE FIX (cached vs cold-cache theme-resolution
          // mismatch): this used to read Theme.of(context).brightness —
          // a DIFFERENT mechanism than the cached-palette branch just
          // above (which already uses isDarkOf(context)). Two branches of
          // the same seeding logic disagreeing on how "light vs dark" is
          // decided is exactly the class of bug that produces a
          // wrong-theme background: whichever branch actually ran for a
          // given open (cached vs cold) could seed _lastIsLight/_targetBg*
          // from a different source than the other, and unlike a single
          // stray frame, this value persists (stored in _lastIsLight,
          // compared against every subsequent build) until something else
          // corrects it. Using isDarkOf(context) here — same as the
          // cached-palette branch, _BgLayer, the route ColoredBox, and the
          // outer Scaffold — means every path that can seed the player's
          // background now agrees on the exact same resolved boolean.
          final isLight = !context.read<ThemeProvider>().isDarkOf(context);
          final gen = ++_artGen;
          _lastArtUrl = url;
          _lastSongId = currentSong.id;
          _lastIsLight = isLight;
          _isFirstBuild = false;
          unawaited(ArtworkPaletteCache.getFast(url).then((fast) {
            if (fast == null || gen != _artGen || !mounted) return;
            if (ArtworkPaletteCache.peek(url) != null) return;
            _applyPalette(fast, gen: gen, isLight: isLight, instant: true);
          }));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // NOTE: _extractColorForce (not _extractColor) — _lastArtUrl was
            // already set to `url` just above, so _extractColor's own
            // same-URL dedup guard would skip this call entirely and the
            // accurate palette would never actually be extracted.
            // _extractColorForce bypasses that guard by design (it exists
            // for exactly this situation elsewhere in this file — see its
            // doc comment) and always resolves from
            // ArtworkPaletteCache.get(), so it's the correct call here.
            _extractColorForce(url, isLight: isLight);
            _warmNextInQueue();
          });
        }
      }
    }
  }

  @override
  void didPushNext() {
    // A new route was pushed on top — pause GPU-heavy loops
    _pauseAmbientAnims();
  }

  @override
  void didPopNext() {
    // The route on top was popped — we're visible again, resume
    if (!_panelOpen) _resumeAmbientAnims();
  }

  bool _panelOpen = false;

  // PERF FIX (godmode recheck): _pauseAmbientAnims/_resumeAmbientAnims
  // existed solely to stop/restart the now-removed _breatheCtrl loop (see
  // that field's own FIX comment above for the full history) — nothing
  // else in this screen was ever driven by them. Kept as harmless no-ops,
  // rather than deleting every call site, since app-lifecycle/panel-open
  // hooks calling them is still exactly the right place to pause/resume
  // ambient motion if a genuinely visible ambient animation is ever added
  // back here in the future.
  void _pauseAmbientAnims() {}

  void _resumeAmbientAnims() {}

  // ── Palette / song cache ──
  Future<void> _extractColor(String url, {bool isLight = false}) async {
    if (url.isEmpty || url == _lastArtUrl) return;
    _lastArtUrl = url;
    final gen = ++_artGen;

    // Cache hit — the common case once a session has been running for a
    // bit (replays, shuffle loops, or a queue-neighbour that was already
    // pre-warmed) — applies the color change on this exact frame instead
    // of waiting on a fresh decode, which is what made this feel laggy.
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      _applyPalette(cached, gen: gen, isLight: isLight);
      return;
    }

    // FIX (cold-start black flash): a true cache miss — this exact
    // artwork has never been seen before, e.g. app freshly opened
    // straight into an unwarmed song — used to leave the background on
    // its hardcoded near-black default for the entire ~1.2s the accurate
    // PaletteGenerator extraction (below) could take, only then snapping
    // to real color. getFast() samples a coarse average color the moment
    // the artwork's own image stream first decodes — no separate slow
    // quantization pass — so the background gets its first real tint as
    // soon as pixels exist, not after a full extraction cycle. It's fired
    // WITHOUT awaiting the accurate path first, so both race
    // concurrently; whichever the accurate one wins (it always
    // eventually applies, since gen still matches), it simply overwrites
    // this fast approximate color, same as any other song-change morph.
    unawaited(ArtworkPaletteCache.getFast(url).then((fast) {
      if (fast == null || gen != _artGen || !mounted) return;
      // Only apply if the accurate result hasn't already landed and
      // moved _artGen/_lastArtUrl on — checked implicitly via gen above,
      // but also skip if a real cached palette has shown up in the
      // meantime (e.g. the accurate path was faster this time), so the
      // flat average never overwrites a better result already on screen.
      if (ArtworkPaletteCache.peek(url) != null) return;
      _applyPalette(fast, gen: gen, isLight: isLight, instant: true);
    }));

    try {
      final palette = await ArtworkPaletteCache.get(url);
      if (gen != _artGen || !mounted) return;
      _applyPalette(palette, gen: gen, isLight: isLight);
    } catch (_) {}
  }

  /// Same as [_extractColor] but deliberately bypasses the "same URL,
  /// skip" dedup guard — used when only the theme mode (dark/light)
  /// changed and the artwork URL is unchanged, so ensureContrastSafe()
  /// gets re-run against the new mode instead of leaving colors clamped
  /// for whichever mode was active when this song's palette was first
  /// extracted. Always resolves from cache (palette itself never depends
  /// on theme mode, only the contrast clamping applied on top of it does),
  /// so this is cheap — no network/decode work repeats.
  Future<void> _extractColorForce(String url, {required bool isLight}) async {
    if (url.isEmpty) return;
    final gen = ++_artGen;
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      _applyPalette(cached, gen: gen, isLight: isLight);
      return;
    }
    try {
      final palette = await ArtworkPaletteCache.get(url);
      if (gen != _artGen || !mounted) return;
      _applyPalette(palette, gen: gen, isLight: isLight);
    } catch (_) {}
  }

  void _applyPalette(ArtworkPalette p, {required int gen, required bool isLight, bool instant = false}) {
    if (gen != _artGen || !mounted) return;
    final c1 = p.vibrant;
    final c2 = p.dominant;
    final c3 = p.darkMuted;
    final c4 = p.lightVibrant;

    // Snapshot current lerped position before morphing
    final t = _bgColorCtrl.value;
    _currentBg1 = Color.lerp(_currentBg1, _targetBg1, t) ?? _currentBg1;
    _currentBg2 = Color.lerp(_currentBg2, _targetBg2, t) ?? _currentBg2;
    _currentBg3 = Color.lerp(_currentBg3, _targetBg3, t) ?? _currentBg3;
    _currentBg4 = Color.lerp(_currentBg4, _targetBg4, t) ?? _currentBg4;

    if (isLight) {
      _targetBg1 = ensureContrastSafe(Color.lerp(c1, Colors.white, 0.16)!, isLight: true);
      _targetBg2 = ensureContrastSafe(Color.lerp(c2, Colors.white, 0.10)!, isLight: true);
      _targetBg3 = ensureContrastSafe(Color.lerp(c3, Colors.white, 0.04)!, isLight: true);
      _targetBg4 = ensureContrastSafe(Color.lerp(c4, Colors.white, 0.20)!, isLight: true);
    } else {
      _targetBg1 = ensureContrastSafe(Color.lerp(c1, Colors.black, 0.22)!, isLight: false);
      _targetBg2 = ensureContrastSafe(Color.lerp(c2, Colors.black, 0.48)!, isLight: false);
      _targetBg3 = ensureContrastSafe(Color.lerp(c3, Colors.black, 0.70)!, isLight: false);
      _targetBg4 = ensureContrastSafe(Color.lerp(c4, Colors.black, 0.30)!, isLight: false);
    }

    // FIX (cold-start black flash, final piece): the fast average-color
    // result (see getFast() in _extractColor) is only useful if it shows
    // up on screen INSTANTLY — if it still had to ride the normal 700–
    // 900ms _bgColorCtrl morph starting from the hardcoded near-black
    // default, the user would watch the exact same "black fading to
    // color" gap this whole fix exists to remove, just with the fast
    // color as the destination instead of the accurate one. `instant:
    // true` (passed only from that one call site) snaps _currentBg
    // straight to the new target and marks _bgColorCtrl as already
    // complete, so this specific application paints immediately with no
    // fade. The accurate PaletteGenerator result that follows moments
    // later still morphs in normally via the standard forward(from: 0.0)
    // path below — only this first rough-and-instant color skips the
    // animation.
    if (instant) {
      _currentBg1 = _targetBg1;
      _currentBg2 = _targetBg2;
      _currentBg3 = _targetBg3;
      _currentBg4 = _targetBg4;
      _bgColorCtrl.value = 1.0;
      if (mounted) setState(() {});
      return;
    }

    _bgColorCtrl.forward(from: 0.0);
  }

  /// Opportunistically pre-decodes the next queued song's palette AND its
  /// hero-resolution (220px) artwork bytes while the current one is still
  /// playing, so by the time playback actually reaches it both the color
  /// morph and the image itself are instant instead of waiting on a cold
  /// decode. Cheap no-op if already cached/in-flight or if there's no next
  /// song.
  ///
  /// FIX ("next song shows blank/black artwork for a beat after skip"):
  /// this used to only warm the extracted palette (ArtworkPaletteCache),
  /// never the actual image bytes at the 220px width the hero Hero widget
  /// decodes at (see AurumArtwork._cacheSize — full player always requests
  /// size: double.infinity → fixed 220px memCacheWidth). Palette warming
  /// alone made the *background gradient* transition instantly on skip,
  /// but the artwork image itself still had to cold-decode the moment
  /// _triggerArtworkAnimation() ran, which is exactly the blank gap users
  /// saw. Precaching the image at the same 220px width here means that
  /// decode already happened by the time the skip lands.
  void _warmNextInQueue() {
    final player = context.read<PlayerProvider>();
    final queue = player.queue;
    final idx = player.currentIndex;
    if (queue.isEmpty || idx < 0 || idx + 1 >= queue.length) return;
    final next = queue[idx + 1];
    if (next.artworkUrl.isNotEmpty) {
      ArtworkPaletteCache.warm(next.artworkUrl);
      _precacheHeroArtwork(next.artworkUrl);
    }
  }

  /// Precaches artwork at the exact 220px width AurumArtwork's hero
  /// instance decodes at (size: double.infinity → _cacheSize fixed 220),
  /// so the image cache key matches and the full player's Hero paints
  /// instantly instead of cold-decoding. Local file:// / content:// URIs
  /// aren't run through CachedNetworkImage at all (they use their own
  /// MethodChannel/File loaders), so this only applies to network URLs —
  /// harmless no-op otherwise.
  void _precacheHeroArtwork(String url) {
    if (url.isEmpty ||
        url.startsWith('content://') ||
        url.startsWith('/') ||
        url.startsWith('file://')) {
      return;
    }
    if (!mounted) return;
    precacheImage(
      CachedNetworkImageProvider(url, maxWidth: 220),
      context,
    ).catchError((_) {
      // Fine to ignore — AurumArtwork still handles the normal
      // fetch/retry/placeholder path if this opportunistic warm fails.
    });
  }

  void _triggerArtworkAnimation() {
    // FIX — "fast spam-skip makes the artwork/UI lag behind the actual
    // song": this used to only call forward(from: 0.0) when the artwork
    // controller WASN'T already animating — meaning if you skipped again
    // while the previous song's artwork transition was still mid-flight,
    // the new trigger was silently dropped and the OLD artwork animation
    // was left to finish on its own timeline before anything reflected the
    // real current song. Under rapid repeated skips this stacked into
    // visibly stale artwork trailing behind, no matter how fast the user
    // tapped. Always restarting from 0.0 (regardless of current animation
    // state) guarantees the artwork transition always represents the
    // LATEST song the instant a skip lands — old in-flight animations are
    // simply superseded, never queued or waited on.
    if (mounted) {
      _artworkCtrl.forward(from: 0.0);
    }
    // Title cross-fade: fade out → snap new title → fade in
    if (mounted) {
      final gen = ++_titleGen;
      _titleChangeCtrl.reverse(from: 1.0).then((_) {
        if (mounted && gen == _titleGen) _titleChangeCtrl.forward();
      });
    }
  }

  void _close() {
    if (!mounted) return;
    AurumHaptics.light();
    // FIX (mini player → full player, queue still loading → back →
    // stuck gray/white layer, intermittent): _close() is the X-button /
    // system-back path. _completeDismissDrag() is the swipe-to-dismiss
    // path. Both independently call Navigator.pop() on this same route.
    // _completeDismissDrag() already guards its OWN re-entry via
    // _springBackIsDismissing, but _close() never checked that flag — so
    // if a swipe-to-dismiss was already mid-flight (its off-screen slide
    // animation running, pop scheduled for when that finishes) and back
    // was pressed in that same window, _close() popped immediately here,
    // while _completeDismissDrag()'s whenCompleteOrCancel callback was
    // still pending. That callback later found `canPop()` false (this
    // route was already gone) and fell into its own recovery branch,
    // calling `setState(() => _dragY = 0)` on a route that was already in
    // the middle of being torn down — a setState racing route disposal
    // instead of a clean single pop, which is exactly the kind of race
    // that leaves a stray half-transitioned frame (the reported stuck
    // gray/white layer) rather than a clean dismissal. Reusing the same
    // guard here means only ONE of the two paths ever gets to pop —
    // whichever lands first — and the other simply no-ops.
    if (_springBackIsDismissing) return;
    // Notifier setter already triggers the thin _DragTransform rebuild —
    // no need to also setState() the whole screen right before it pops.
    if (_dragY != 0) _dragY = 0;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // FIX (awkward jerk on swipe-to-dismiss) — the old onVerticalDragEnd
  // path called `_dragY = 0` (an instant, unanimated snap back to the
  // top) immediately followed by _close()'s Navigator.pop(), whose route
  // reverse-transition always starts its own slide from y=0. On a drag
  // that had already moved the screen down (say 200-280px, following the
  // finger), releasing past the dismiss threshold produced two competing
  // motions back to back: a one-frame snap UP to y=0, then the route
  // transition sliding the whole screen back DOWN from y=0 — a visible
  // direction reversal right at the moment of release, which read as a
  // jerk/stutter rather than the swipe simply continuing through.
  //
  // This replaces that: instead of resetting to 0, it animates _dragY
  // from wherever the finger left off the REST of the way off-screen
  // (using the actual screen height, not the old hard 280px visual clamp
  // in _DragTransform, so the screen genuinely finishes leaving the
  // frame) over a short duration, and only pops the route once that
  // animation completes — by which point the screen is already fully
  // off-screen, so the route's own reverse-transition is invisible
  // (there's nothing left on screen for it to animate). The swipe now
  // reads as one continuous motion instead of two.
  void _completeDismissDrag() {
    if (!mounted) return;
    // FIX ("offline song, full player swipe-down se band karo — gray/white
    // layer atak jaata hai, kabhi kaam karta hai kabhi nahi" — production
    // bug): this had no re-entry guard at all, unlike _PremiumContentPanel
    // ._dismiss() right below in this same file (which correctly checks
    // _isDismissing first). A second onVerticalDragEnd landing while the
    // first _completeDismissDrag()'s slide-off animation was still
    // in-flight — e.g. a slightly jittery release, or two pointer events
    // resolving to two drag-end callbacks — started a SECOND independent
    // animation on _springBackCtrl (reset() + forward() again), racing the
    // first one's own whenCompleteOrCancel callback. Whichever finishes
    // first calls Navigator.pop() and the route is gone; the other one's
    // callback then runs against a screen that's already been popped —
    // `mounted` can still read true for a frame or two mid-pop-animation,
    // but `canPop()` is now false, so the SECOND callback's pop is
    // silently skipped (see the debug log path below) with nothing left
    // to recover it. That's exactly why this was intermittent: it only
    // needed a second callback to land, which doesn't happen on every
    // swipe. Guarding re-entry here means only the FIRST dismiss ever
    // starts an animation or attempts a pop — any duplicate call while
    // one is already in flight is simply ignored, exactly like
    // _PremiumContentPanel._dismiss() already does for its own dismiss.
    if (_springBackIsDismissing) {
      return;
    }
    AurumHaptics.light();
    _springBackIsDismissing = true;
    final screenH = MediaQuery.of(context).size.height;
    final start = _dragY;
    _springBackCtrl.reset();
    // Duration scales down from the already-covered distance so a
    // near-threshold release (long remaining distance) doesn't feel
    // slower than a deep drag (short remaining distance) — both read as
    // "the same swipe speed carried through" rather than a fixed-time
    // animation that'd feel like it's dragging or snapping depending on
    // how far the user had already gone.
    final remaining = (screenH - start).clamp(1.0, screenH);
    final ms = (140 + (remaining / screenH) * 160).round();
    _springBackCtrl.duration = Duration(milliseconds: ms);
    final anim = Tween<double>(begin: start, end: screenH).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.easeIn),
    );
    void listener() {
      if (!mounted) return;
      _dragY = anim.value;
    }

    anim.addListener(listener);
    _springBackCtrl.forward().whenCompleteOrCancel(() {
      anim.removeListener(listener);
      _springBackCtrl.duration = const Duration(milliseconds: 320);
      _springBackIsDismissing = false;
      if (!mounted) {
        return;
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        // FIX (see the re-entry guard added at the top of this function
        // for the actual root cause — a duplicate call racing the first
        // pop). This branch is the backstop for any OTHER path that could
        // still leave canPop() false here (e.g. something else on the
        // stack already popped this route first): rather than silently
        // giving up and leaving the screen slid fully off-screen but
        // still technically mounted/on the stack — invisible, but still
        // intercepting touches — snap it back to visible. A visible,
        // interactive full player the user can swipe again is always
        // recoverable; an invisible stuck route is not.
        if (mounted) {
          setState(() => _dragY = 0);
        }
      }
    });
  }

  Future<void> _onPlayTap(PlayerProvider player) async {
    AurumHaptics.heavy();
    // STABILITY FIX (play/pause button feels like it "bumps"/lags on
    // tap): this used to await the full press-in (110ms) AND
    // press-out (110ms) squish animation — a fixed 220ms of pure
    // animation time — BEFORE calling togglePlay() at all. That is a
    // real, felt input delay on every single tap, stacked on top of
    // the icon-swap animation togglePlay() itself triggers once state
    // updates. Firing togglePlay() immediately (not awaited — the
    // press squish is purely cosmetic and shouldn't block the actual
    // state change) means the icon starts responding as soon as
    // physically possible, with the button's own squish playing
    // concurrently rather than gating it.
    unawaited(player.togglePlay());
    unawaited(_playBtnCtrl.forward().then((_) => _playBtnCtrl.reverse()));
  }

  void _openPanel({int initialTab = 0}) {
    AurumHaptics.medium();
    _panelOpen = true;
    _pauseAmbientAnims();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(165),
      useSafeArea: false,
      builder: (_) => _PremiumContentPanel(
        bg1: _currentBg1,
        bg2: _currentBg2,
        bg3: _currentBg3,
        initialTab: initialTab,
      ),
    ).whenComplete(() {
      _panelOpen = false;
      if (mounted &&
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) {
        _resumeAmbientAnims();
      }
    });
  }

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    AurumHaptics.light();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => _PremiumOptionsSheet(
        song: song,
        player: player,
        accentColor: _targetBg1,
        rootContext: context,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (String?, bool, bool, LoopMode, bool, int)>(
      selector: (_, player) => (
        player.currentSong?.id,
        player.isPlaying,
        player.isLoading,
        player.loopMode,
        player.shuffle,
        player.queue.length,
      ),
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        final song = player.currentSong;
        if (song == null) {
          // currentSong went null while this screen is open (e.g. stream
          // resolve failed and the queue got cleared). Rendering nothing
          // here just leaves a black/blank screen sitting on top of the
          // app — close it automatically instead so the user lands back
          // on whatever screen they came from.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }

        // Trigger artwork + color extraction on song change OR theme
        // (dark/light) change.
        //
        // BUG FIX: this used to only fire inside the song.id != _lastSongId
        // branch — so toggling dark/light mode while the full player was
        // already open on the SAME song never re-ran _extractColor at all
        // (the URL hadn't changed, and _extractColor's own dedup guard
        // returns early on url == _lastArtUrl regardless of isLight). The
        // background colors stayed clamped by ensureContrastSafe() for
        // whichever mode was active when the song first loaded — e.g. a
        // near-black dark-mode-safe background could persist right after
        // switching to light mode, where the screen now draws dark text on
        // top of it. Tracking the resolved isLight value separately and
        // re-triggering extraction whenever it flips (independent of
        // whether the song also changed) means a live theme toggle always
        // recomputes contrast-safe colors for the new mode.
        // ROOT-CAUSE FIX (single source of truth for theme resolution):
        // this used to read Theme.of(context).brightness — a DIFFERENT
        // mechanism than _BgLayer (which uses isDarkOf(context)) and the
        // route/Scaffold background (same). isDarkOf folds in isAmoled and
        // the isDynamic+platformBrightness special case, neither of which
        // Theme.of(context).brightness alone captures — so this watchdog
        // could disagree with what _BgLayer is actually painting, in
        // either direction, for as long as the player stays open (this
        // isn't a one-frame flash path — themeChanged gates persist until
        // the next flip is detected). context.watch so a genuine live
        // theme toggle while the player is open is still caught, matching
        // the original intent of this whole block.
        final isLight = !context.watch<ThemeProvider>().isDarkOf(context);
        final themeChanged = isLight != _lastIsLight;
        _lastIsLight = isLight;
        if (song.id != _lastSongId || themeChanged) {
          final songChanged = song.id != _lastSongId;
          _lastSongId = song.id;
          // FIX (double-animation on first open) — on the screen's very
          // first build, song.id is always != _lastSongId (which starts
          // null), so this used to always fire _triggerArtworkAnimation()
          // too — replaying the 0.94→1.0 artwork pop and the title
          // fade-out/in on top of the route's own 380ms slide-up
          // transition, even though nothing had actually "changed" from
          // the user's perspective. That's the extra pop this fix
          // removes: _triggerArtworkAnimation() (and the redundant
          // _artworkCtrl.value = 1.0 set in initState) is now reserved
          // for genuine song changes that happen while this screen is
          // already open (skip/tap-another-song), not the screen's own
          // opening — which the route transition already animates on
          // its own.
          final isFirstBuild = _isFirstBuild;
          _isFirstBuild = false;
          // A pure theme toggle (song unchanged) has no reason to replay
          // the artwork pop/title cross-fade — those are song-change cues.
          // Only re-extraction needs to happen, and it needs to bypass
          // _extractColor's own "same URL, skip" guard, since the URL
          // genuinely hasn't changed here — only the contrast mode has.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (songChanged && !isFirstBuild) _triggerArtworkAnimation();
            if (song.artworkUrl.isNotEmpty) {
              if (songChanged) {
                _extractColor(song.artworkUrl, isLight: isLight);
              } else {
                // Theme-only change: force past the same-URL dedup guard.
                _extractColorForce(song.artworkUrl, isLight: isLight);
              }
            }
            if (songChanged) _warmNextInQueue();
          });
        }

        return GestureDetector(
              // Single gesture owner for the whole screen — swipe down
              // dismisses, swipe up opens the queue/lyrics panel. Having
              // this logic split across two nested GestureDetectors (one
              // wrapping the whole screen, one wrapping just the body)
              // put both in the same Flutter gesture arena on the same
              // axis, so the arena's win/lose resolution was effectively
              // arbitrary — sometimes swallowing the swipe-up-to-open
              // gesture, sometimes double-firing, sometimes leaving
              // _dragY in a stuck state. One detector removes the
              // ambiguity entirely.
              onVerticalDragStart: (_) {
                _dragIsUpward = false;
                _upwardDragDistance = 0;
                // Cheap: fires once per gesture start, not per frame —
                // unlike _dragY this is fine to setState directly. Only
                // _DragHandle actually depends on this value.
                setState(() => _isDragging = true);
              },
              onVerticalDragUpdate: (d) {
                if (_panelOpen) return;
                if (d.delta.dy > 0 && !_dragIsUpward) {
                  // Downward: drag-to-dismiss follows the finger. Writing
                  // straight to the notifier — PERF FIX: this used to be
                  // setState(() => _dragY += ...), which reran this
                  // entire State's build() (background, controls,
                  // seekbar, everything) on every touch-move callback.
                  // Now only _DragTransform below (which wraps the
                  // otherwise-stable Scaffold child) listens and rebuilds.
                  _dragY += d.delta.dy;
                } else if (d.delta.dy < 0 || _dragIsUpward) {
                  // Upward: STRICT FIX — this used to nudge _dragY negative
                  // (clamped to -60) and Transform.translate applied that
                  // immediately, so the instant you started swiping up to
                  // open Up Next, the *entire full player screen* visibly
                  // slid upward underneath your finger — worse and more
                  // jarring the faster you swiped. The Up Next panel opens
                  // as its own bottom sheet with its own slide-in transition
                  // (see _openPanel/showModalBottomSheet below); the full
                  // player underneath has no reason to move at all during
                  // that gesture. We track the raw distance separately
                  // (_upwardDragDistance) purely so onVerticalDragEnd's
                  // threshold check below keeps working for slow deliberate
                  // swipes, not just fast flicks — without ever touching
                  // the screen's position.
                  _dragIsUpward = true;
                  _upwardDragDistance += d.delta.dy; // negative while moving up
                }
              },
              onVerticalDragEnd: (d) {
                setState(() => _isDragging = false);
                final velocity = d.primaryVelocity ?? 0;

                if (!_dragIsUpward && (_dragY > 110 || velocity > 750)) {
                  // FIX (see _completeDismissDrag() doc comment above) —
                  // this used to hard-reset _dragY to 0 (snap back to the
                  // top with no animation) and immediately pop, which
                  // fought against the drag the user had just done.
                  // Continuing the drag's own motion the rest of the way
                  // off-screen reads as one smooth swipe-through instead.
                  _completeDismissDrag();
                } else if (_dragIsUpward &&
                    (_upwardDragDistance < -20 || velocity < -400)) {
                  _dragY = 0;
                  _openPanel();
                } else {
                  _springBackDrag();
                }
                _dragIsUpward = false;
              },
              // FIX ("swipe down/up sometimes leaves screen stuck") — no
              // onVerticalDragCancel was wired here at all, so if the
              // gesture arena took the pointer away mid-drag (a competing
              // scroll winning resolution, same class of issue as the
              // didChangeAppLifecycleState fix above covers for
              // backgrounding), _isDragging/_dragY had no path back to a
              // clean state. Treat exactly like a below-threshold release:
              // spring back to fully-open.
              onVerticalDragCancel: () {
                if (_isDragging && mounted) setState(() => _isDragging = false);
                _dragIsUpward = false;
                _upwardDragDistance = 0;
                _springBackDrag();
              },
              child: _DragTransform(
                dragYListenable: _dragYNotifier,
                child: Scaffold(
                      // FIX (permanent removal of cold-start white/cream
                      // flash — confirmed reproducible in every theme
                      // mode): this used to branch on isDarkOf(context) to
                      // decide between Colors.black and the light cream
                      // 0xFFF5F0EA. That branch depended on ThemeProvider
                      // having already resolved (it loads its saved mode
                      // async via SharedPreferences), so on a cold start —
                      // before that resolves — this could paint the cream
                      // branch for one or more real frames regardless of
                      // which mode the user actually has selected,
                      // producing exactly the white/cream flash reported
                      // ("full player khulne se 1-2 sec pehle white tint").
                      // The player's own palette-driven _BgLayer below
                      // already defaults to dark colors (_targetBg1 etc,
                      // 0xFF0D0D18) before any artwork is extracted, and
                      // stays dark-toned even in light theme once real
                      // colors land — so a plain dark base here can never
                      // visibly clash with what paints on top of it a
                      // moment later, in any theme. Hardcoding dark
                      // removes the race entirely instead of just timing
                      // around it.
                      backgroundColor: Colors.black,
                      body: Stack(
                        fit: StackFit.expand,
                        children: [
                          // FIX (cold-start white flash, second half): a
                          // guaranteed-opaque solid color painted as the
                          // very first Stack child, matching the theme.
                          // Unlike Scaffold.backgroundColor (which is still
                          // subject to Flutter's own paint scheduling), a
                          // plain ColoredBox as literally the first pixel
                          // this Stack ever draws removes any possible gap
                          // frame during the route's slide-up on a cold
                          // start, when the artwork/palette-driven _BgLayer
                          // below hasn't extracted real colors yet. Same
                          // permanent-dark fix as backgroundColor above —
                          // no theme-resolution race possible.
                          const ColoredBox(color: Colors.black),
                          // Background: isolated repaint boundary
                          RepaintBoundary(
                            child: _BgLayer(
                              song: song,
                              bgCtrl: _bgColorCtrl,
                              startBg1: _currentBg1,
                              startBg2: _currentBg2,
                              startBg3: _currentBg3,
                              startBg4: _currentBg4,
                              targetBg1: _targetBg1,
                              targetBg2: _targetBg2,
                              targetBg3: _targetBg3,
                              targetBg4: _targetBg4,
                              // FIX ("blur background wale swipe-down mein
                              // solid wale se alag ek layer/flash dikhta
                              // hai, jabki solid mein nahi"): Solid mode has
                              // zero active controllers behind it — just one
                              // flat ColoredBox — so a dismiss-drag composites
                              // cleanly every frame on any device. Blur/
                              // Gradient mode additionally runs the Ken
                              // Burns pan/zoom (breatheCtrl, an 18s loop)
                              // stacked underneath _DragTransform's own
                              // transform+opacity the whole time the player
                              // is open — including mid-swipe. Two
                              // independently-driven transforms compositing
                              // at once, on top of the single most expensive
                              // paint layer on this screen, is exactly the
                              // kind of thing that drops a frame on a
                              // low-end device — and a dropped/late frame
                              // during a fast multi-layer composite reads as
                              // a stray layer flash for an instant, which
                              // Solid mode structurally can't produce.
                              // Freezing the Ken Burns motion for the
                              // duration of the drag removes that second
                              // moving transform, leaving only
                              // _DragTransform's own — matching Solid mode's
                              // simplicity exactly while a finger is down,
                              // with the slow drift resuming the instant the
                              // gesture ends (spring-back or completed
                              // dismiss). This is a perf-only freeze (it
                              // doesn't hide the blur — see staticBlur's FIX
                              // comment above for why the blur itself always
                              // stays rendered), so it's fine for both drag
                              // directions (dismiss and Up Next panel open)
                              // to freeze it the same way.
                              isDragging: _isDragging,
                            ),
                          ),
                          SafeArea(
                            child: RepaintBoundary(
                              child: _buildBody(context, player, song),
                            ),
                          ),
                        ],
                      ),
                    ),
              ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, PlayerProvider player, Song song) {
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final w = constraints.maxWidth;
      final isCompact = h < 640;
      final isTablet = w > 600;

      final vGapSm = isCompact ? 8.0 : 16.0;
      final vGapMd = isCompact ? 12.0 : 20.0;
      final hPad = isTablet ? w * 0.16 : 28.0;

      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DragHandle(isDragging: _isDragging),
            TopBarWithCastBanner(song: song, bgLuma: _currentBg2.computeLuminance(), onMore: () => _showOptions(context)),
            SizedBox(height: (vGapMd - 15).clamp(0.0, vGapMd)),
            // Artwork — enters with the screen slide (no extra delay)
            _Artwork(
              song: song,
              player: player,
              hPad: hPad,
              h: h,
              w: w,
              bgLuma: _currentBg2.computeLuminance(),
              artworkAnim: _artworkAnim,
            ),
            SizedBox(height: (vGapMd - 15).clamp(0.0, vGapMd)),
            // Song info — staggered fade+slide up (delay ~90ms)
            FadeTransition(
              opacity: _infoStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.18, 0.75, curve: Curves.easeOutCubic))),
                child: FadeTransition(
                  opacity: _titleFadeAnim,
                  child: SlideTransition(
                    position: _titleSlideAnim,
                    child: _SongInfo(
                      song: song,
                      hPad: hPad,
                      isTablet: isTablet,
                      bgLuma: _currentBg2.computeLuminance(),
                      // FIX — "like button not wired, doesn't actually
                      // save/count as liked": this used to read/write a
                      // local `_isFav` bool that had NO connection to
                      // FavoritesProvider at all. It always opened showing
                      // unliked (even for an actually-liked song) and
                      // tapping it only flipped that local visual bool —
                      // nothing was ever persisted, and the song was never
                      // really added to/removed from Favorites. Now reads
                      // the real state straight from FavoritesProvider
                      // (same source of truth the bottom-sheet's "Like"
                      // action and the mini player's AurumLikeButton
                      // already correctly use) so the heart always
                      // reflects — and actually changes — the song's real
                      // liked status.
                      isFav: context.watch<FavoritesProvider>().isFavorite(song.id),
                      onFavTap: () {
                        PremiumGate.guard(
                          context,
                          feature: AppLocalizations.of(context)!.fpLikeSongsFeature,
                          description: AppLocalizations.of(context)!.fpLikeSongsSignIn,
                          requiresLoginOnly: true,
                          onAllowed: () {
                            AurumHaptics.light();
                            context.read<FavoritesProvider>().toggleFavorite(song);
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: vGapSm * 0.3),
            // sitting between title/artist and the seek bar. Tapping it
            // opens straight to the full Lyrics tab.
            ValueListenableBuilder<bool>(
              valueListenable: AudioPrefs.showLyricsOnPlayerNotifier,
              builder: (context, show, _) {
                if (!show) return const SizedBox.shrink();
                return _InlineLyricsStrip(
                  hPad: hPad,
                  bgLuma: _currentBg2.computeLuminance(),
                  onTap: () => _openPanel(initialTab: 1),
                );
              },
            ),
            SizedBox(height: vGapSm * 0.3),
            // Seek bar — delay ~150ms
            FadeTransition(
              opacity: _seekStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.30, 0.85, curve: Curves.easeOutCubic))),
                child: _SeekBar(player: player, hPad: hPad, bgLuma: _currentBg2.computeLuminance()),
              ),
            ),
            SizedBox(height: vGapSm),
            // Controls — delay ~220ms
            FadeTransition(
              opacity: _ctrlStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic))),
                child: _Controls(
                  player: player,
                  hPad: hPad,
                  playBtnAnim: _playBtnAnim,
                  bg1: _currentBg1,
                  bgLuma: _currentBg2.computeLuminance(),
                  onPlayTap: () => _onPlayTap(player),
                ),
              ),
            ),
            SizedBox(height: isCompact ? 8.0 : 12.0),
            SizedBox(
              height: 28,
              child: Center(child: _QualityPills(song: song, hPad: hPad, bgLuma: _currentBg2.computeLuminance())),
            ),
            const Spacer(),
            _BottomPill(hPad: hPad, bgLuma: _currentBg2.computeLuminance(), onTap: _openPanel),
            SizedBox(height: isCompact ? 8.0 : 12.0),
          ],
        );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DragTransform — isolates the swipe-to-dismiss transform from the rest
// of the full player.
//
// PERF FIX: previously the drag offset/scale/opacity were computed inline
// in _FullPlayerScreenState.build() and applied directly wrapping the
// giant Scaffold subtree — meaning any setState touching _dragY (i.e.
// every single frame of a finger drag) reran that entire build() method:
// background layers, controls, seekbar, song info, everything. This
// widget takes the already-built Scaffold as a stable `child` and only
// itself listens to the drag notifier, so a drag gesture now rebuilds
// just this thin wrapper every frame — the expensive subtree underneath
// is built exactly once per gesture (when the widget is first created),
// not once per touch-move callback.
// ─────────────────────────────────────────────────────────────────────────────
class _DragTransform extends StatelessWidget {
  final ValueListenable<double> dragYListenable;
  final Widget child;

  const _DragTransform({required this.dragYListenable, required this.child});

  @override
  Widget build(BuildContext context) {
    // FIX (awkward jerk on swipe-to-dismiss, part 2 — pairs with
    // _completeDismissDrag() above) — this used to hard-clamp the visual
    // translate to 280px and opacity to a floor of 0.45, regardless of
    // how far dragY actually went. That was fine for a LIVE drag (finger
    // still down, following it 1:1 felt right even past 280px of raw
    // delta), but it meant the screen could never actually finish
    // leaving the frame — so even the old instant "_dragY = 0 then pop"
    // path popped while the screen was still ~280px up and ~45% opaque,
    // and this new smooth completion animation would have hit the same
    // ceiling and looked like it stalled a quarter-of-the-way through
    // instead of finishing the swipe. The translate clamp is now the
    // actual screen height (so the completion animation can carry it
    // all the way to fully off-screen) and opacity now reaches 0 at that
    // same point, instead of bottoming out at 0.45.
    //
    // PERF FIX (smoothness during the drag itself): this used to stack
    // Transform.translate → Transform.scale → Opacity as three separate
    // widgets, each of which asks the engine for its own compositing
    // layer. Three layers being resized/repositioned/faded every single
    // touch-move frame is exactly the kind of thing that reads as
    // stutter on lower-end devices even though nothing here is logically
    // expensive. Folding translate+scale into one Matrix4 collapses that
    // to a single transform layer, and RepaintBoundary below pins the
    // (static, unchanging) child to its own layer once so the transform
    // layer is compositing a cached bitmap instead of re-walking the
    // whole Scaffold subtree's paint on every frame.
    final screenH = MediaQuery.of(context).size.height;
    return ValueListenableBuilder<double>(
      valueListenable: dragYListenable,
      builder: (context, dragY, child) {
        // FIX ("Solid mode jaisa hi Blur mode ka background bhi — poore
        // drag ke dauraan blur bana rahe jab tak dismiss COMPLETE na ho
        // jaaye, sirf Home ke saath ghost/blend hone wala hissa clean
        // ho"): opacity used to start dropping from the very first pixel
        // of drag (1.0 - dragY/screenH), so by ~30% of the swipe the
        // player was already ~70% opaque — with Home's route painting
        // live underneath (opaque:false, see pushFullPlayer's own FIX
        // comment for why that's needed), that meant a blurred, static
        // artwork photo was visibly blending with unrelated, live-moving
        // Home content the whole way down. Delaying the opacity falloff
        // to the last 25% of the drag means the blur stays fully present
        // and fully opaque — exactly as requested, present the entire
        // way down, same as Solid mode's flat color — for the first 75%
        // of the swipe, with nothing showing through it. Only in that
        // final 25%, once the card is nearly off-screen anyway, does it
        // fade — by then there's barely anything left on screen for it
        // to blend with, so it reads as a clean finish rather than a
        // ghost layer. This mirrors exactly how Solid mode already
        // behaved; Blur mode now gets the same guarantee.
        final dismissProgress = (dragY / screenH).clamp(0.0, 1.0);
        final dragOpacity =
            1.0 - ((dismissProgress - 0.75) / 0.25).clamp(0.0, 1.0);
        final dragScale =
            (1.0 - (dragY / 2200).clamp(0.0, 0.06)).clamp(0.0, 1.0);
        final ty = dragY.clamp(0.0, screenH);
        final matrix = Matrix4.identity()
          ..translate(0.0, ty)
          ..scale(dragScale, dragScale);
        return Opacity(
          opacity: dragOpacity,
          // FIX ("background mein upar blur dikh raha hai screenshot mein
          // — blur sirf full player ke apne area tak hi rahe, kabhi bahar/
          // upar na jaaye"): the blurred-artwork layer inside _BgLayer
          // (_BlurredArtworkCore) renders at Transform.scale(1.55) — a
          // deliberate overscan so the blur's own soft edges never show a
          // hard boundary. That overscan was never clipped anywhere in
          // this widget tree, so once this outer Transform also
          // translates the whole Scaffold during a dismiss drag, the
          // scaled-up blur content that extends past the player's own
          // screen bounds becomes visible above/around the player,
          // overlapping Home's live route underneath (opaque:false) —
          // exactly the stray blur strip seen in the report. Wrapping in
          // ClipRect here guarantees nothing this widget paints, at any
          // scale or translation, is ever visible outside the player's
          // own rectangle — the overscan still does its job of avoiding a
          // hard blur edge internally, it just can never leak past this
          // boundary.
          child: ClipRect(
            child: Transform(
              transform: matrix,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: RepaintBoundary(child: child),
    );
  }
}


class _DragHandle extends StatelessWidget {
  final bool isDragging;
  const _DragHandle({required this.isDragging});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: isDragging ? 44 : 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(isDragging ? 80 : 45),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top Bar
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final Song song;
  final double bgLuma;
  final VoidCallback onMore;
  const _TopBar({required this.song, required this.bgLuma, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // FIX (same class of bug as buttons/lyrics strip below): this bar
    // sits directly over the artwork/background (no opaque surface
    // behind it besides its own translucent pill), so it needs to react
    // to the actual artwork luminance, not the app's light/dark theme
    // setting — those are unrelated, and a dark-mode user with bright
    // artwork (like a light-colored album cover) got near-invisible
    // chevron/menu icons and a washed-out pill exactly like this.
    final bgIsLight = bgLuma >= 0.5;
    final textPrimary = bgIsLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textMuted = bgIsLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(170);
    final pillBg = bgIsLight ? AurumTheme.lightBgSurface.withAlpha(200) : Colors.black.withAlpha(70);
    final pillBorder = bgIsLight ? AurumTheme.lightDivider : Colors.white.withAlpha(30);
    final iconColor = bgIsLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(230);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        _IconBtn(
          icon: Icons.keyboard_arrow_down_rounded,
          size: 26,
          color: iconColor,
          onTap: () => Navigator.pop(context),
          semanticLabel: l10n.fpClosePlayer,
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: pillBorder, width: 0.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                l10n.fpNowPlaying,
                style: TextStyle(
                  color: textMuted,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.album.isNotEmpty ? song.album : 'Aurum Music', // brand name — not translated
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
        _IconBtn(
          icon: Icons.more_vert_rounded,
          size: 22,
          color: iconColor,
          onTap: onMore,
          semanticLabel: l10n.fpMoreOptions,
        ),
      ]),
    );
  }
}

/// Thin wrapper placing the "Casting to X" banner directly under the
/// top bar — kept as its own tiny widget so _TopBar itself stays
/// untouched (it has no BuildContext access to Provider watch calls
/// beyond what it already reads).
class TopBarWithCastBanner extends StatelessWidget {
  final Song song;
  final double bgLuma;
  final VoidCallback onMore;
  const TopBarWithCastBanner({super.key, required this.song, required this.bgLuma, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _TopBar(song: song, bgLuma: bgLuma, onMore: onMore),
      const CastingBanner(),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
// ─────────────────────────────────────────────────────────────────────────────
class _Artwork extends StatefulWidget {
  final Song song;
  final PlayerProvider player;
  final double hPad, h, w;
  final double bgLuma;
  final Animation<double> artworkAnim;

  const _Artwork({
    required this.song,
    required this.player,
    required this.hPad,
    required this.h,
    required this.w,
    required this.bgLuma,
    required this.artworkAnim,
  });

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> with SingleTickerProviderStateMixin {
  double _dragDx = 0;
  bool _dragging = false;

  // FIX (1-sec "jatka"/jerk on song change via swipe) — this used to reset
  // _dragDx straight to 0 via a plain setState() the instant the finger
  // lifted, regardless of how far it had been dragged (up to the ~220px/
  // 70px threshold). Transform.translate follows _dragDx directly, so
  // that read as the artwork instantly teleporting back to center in a
  // single frame — a hard, visible snap right at the moment the new song
  // landed, since skipNext()/skipPrev() were already firing in the same
  // callback. This controller animates that same return-to-center instead
  // of hard-cutting it, so the artwork eases back into place rather than
  // jumping. Kept intentionally short/cheap (150ms, single Tween, no
  // extra compositing layers) so it stays lightweight.
  late final AnimationController _snapBackCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  Animation<double>? _snapBackAnim;

  @override
  void dispose() {
    _snapBackCtrl.dispose();
    super.dispose();
  }

  // Higher sensitivity (closer to 100) means a shorter swipe triggers a
  // skip. We map the 0–100 setting onto a 220px (least sensitive) down to
  // 70px (most sensitive) drag-distance threshold.
  double _thresholdFor(double sensitivity) {
    final t = sensitivity.clamp(0.0, 100.0) / 100.0;
    return 220.0 - (150.0 * t);
  }

  void _animateSnapBack() {
    _snapBackCtrl.stop();
    final start = _dragDx;
    if (start == 0) {
      setState(() => _dragging = false);
      return;
    }
    _snapBackAnim = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _snapBackCtrl, curve: Curves.easeOutCubic),
    )..addListener(() {
        if (!mounted) return;
        setState(() => _dragDx = _snapBackAnim!.value);
      });
    _dragging = false;
    _snapBackCtrl.forward(from: 0.0);
  }

  void _handleDragEnd() {
    final sensitivity = AudioPrefs.swipeSensitivity;
    final threshold = _thresholdFor(sensitivity);
    if (_dragDx <= -threshold) {
      AurumHaptics.medium();
      widget.player.skipNext().then((allowed) {
        if (!allowed && mounted) {
          PremiumGate.show(
            context,
            feature: AppLocalizations.of(context)!.fpUnlimitedSkipsFeature,
            description: AppLocalizations.of(context)!.fpUnlimitedSkipsSignIn,
            requiresLoginOnly: true,
          );
        }
      });
    } else if (_dragDx >= threshold) {
      AurumHaptics.medium();
      widget.player.skipPrev();
    }
    _animateSnapBack();
  }

  @override
  Widget build(BuildContext context) {
    // Artwork's own visual size uses a tighter, dedicated inset than
    // widget.hPad (28dp — shared with title/seekbar/controls below for
    // their own horizontal padding and this widget's drag-gesture
    // hitbox). Spotify/Apple Music render the cover at roughly 88-92% of
    // screen width; the old maxArtSize (driven by the same 28dp used
    // everywhere else) landed closer to 86%, which reads slightly small
    // next to those references. Sizing just the artwork tighter — while
    // leaving widget.hPad, and everything built from it, untouched —
    // gets the cover noticeably closer to that proportion without
    // cramping the title text or control row, which still use the wider
    // padding they were already tuned for.
    const artworkVisualPad = 18.0;
    final maxArtSize =
        (widget.w - artworkVisualPad * 2).clamp(0.0, widget.h * 0.46);
    // FIX (shadow direction wrong depending on artwork, not app theme):
    // this softened the artwork's drop shadow on Theme.of(context).
    // brightness — but this shadow's job is to lift the artwork off the
    // BACKGROUND behind it (which is itself artwork-luma-driven, see
    // _BgLayer), not off the app's theme. A dark-mode user with light
    // artwork (bright background) needs the SOFT/light-background shadow
    // treatment, not the dark-theme one, and vice versa.
    final bgIsLight = widget.bgLuma >= 0.5;
    return ValueListenableBuilder<bool>(
      valueListenable: AudioPrefs.swipeToChangeNotifier,
      builder: (context, swipeEnabled, _) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: swipeEnabled
              ? (_) {
                  _snapBackCtrl.stop();
                  setState(() => _dragging = true);
                }
              : null,
          onHorizontalDragUpdate: swipeEnabled
              ? (d) => setState(() => _dragDx += d.delta.dx)
              : null,
          onHorizontalDragEnd: swipeEnabled ? (_) => _handleDragEnd() : null,
          onHorizontalDragCancel: swipeEnabled ? _animateSnapBack : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: artworkVisualPad),
            child: Center(
              child: SizedBox(
                width: maxArtSize,
                height: maxArtSize,
                // Artwork stays pinned in place — no vertical float.
                // Only the horizontal swipe-drag offset and its scale
                // feedback remain; the idle up/down "breathing" motion
                // has been removed so the artwork reads as static/fixed,
                // matching a premium/paid-app look.
                child: Transform.translate(
                  offset: Offset(_dragDx * 0.3, 0),
                  child: Transform.scale(
                    scale: _dragging
                        ? (1.0 - (_dragDx.abs() / 800).clamp(0.0, 0.08))
                        : 1.0,
                    child: AnimatedBuilder(
                  animation: widget.artworkAnim,
                  builder: (_, child) => Transform.scale(
                    scale: widget.artworkAnim.value,
                    child: child,
                  ),
                  // SPEED FIX (Spotify-level lightweight): this Hero had no
                  // matching Hero anywhere else in the app (mini_player.dart
                  // and every other artwork call site use plain
                  // AurumArtwork, no Hero tag) — confirmed via a full grep
                  // for tag 'aurum_artwork'. An unmatched Hero never gets to
                  // play a flight animation, so it was pure dead weight:
                  // every build here still paid for Hero's own GlobalKey
                  // registration/lookup machinery for zero visual benefit,
                  // and it's a latent risk for an unexpected flight
                  // animation to trigger later if any other screen ever
                  // reuses this exact tag by accident. Removed entirely —
                  // the child renders exactly the same without it.
                  child: ValueListenableBuilder<String>(
                    valueListenable: AudioPrefs.artworkShapeNotifier,
                    builder: (context, shape, _) {
                      final radius = shape == 'Circle'
                          ? maxArtSize / 2
                          : shape == 'Square'
                              ? 4.0
                              : 20.0;
                      return RepaintBoundary(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                            // FIX: this shadow used a flat Colors.black at
                            // fairly high alpha regardless of theme. On the
                            // dark theme that reads fine (matches the near-
                            // black background), but on light theme it sat
                            // on top of a pale surface as a hard, inky ring
                            // around the artwork — not the soft, low-alpha
                            // lift Spotify/Apple Music use on light
                            // backgrounds. Halved the alpha and blur/spread
                            // in light mode so it reads as a gentle elevation
                            // shadow instead of a dark outline.
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(
                                    bgIsLight
                                        ? (widget.player.isPlaying ? 60 : 38)
                                        : (widget.player.isPlaying ? 180 : 110)),
                                blurRadius: bgIsLight
                                    ? (widget.player.isPlaying ? 36 : 22)
                                    : (widget.player.isPlaying ? 64 : 40),
                                  offset: const Offset(0, 16),
                                  spreadRadius: (!bgIsLight && widget.player.isPlaying) ? 4 : 0,
                                ),
                                BoxShadow(
                                  color: Colors.black.withAlpha(bgIsLight ? 28 : 90),
                                  blurRadius: bgIsLight ? 10 : 18,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: AurumArtwork(
                                url: widget.song.artworkUrl,
                                size: double.infinity,
                                borderRadius: radius,
                                // FIX (white flash on song tap / swipe-down
                                // dismiss / collapse — root cause): see
                                // suppressWhiteShimmer doc comment in
                                // aurum_artwork.dart. This is the hero disc
                                // artwork rendered at full screen size —
                                // the white _ShimmerPulse loading state
                                // that's harmless at tile size was covering
                                // the entire player here while local/
                                // content:// album art loaded.
                                suppressWhiteShimmer: true,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song Info
// ─────────────────────────────────────────────────────────────────────────────
class _SongInfo extends StatelessWidget {
  final Song song;
  final double hPad;
  final bool isTablet, isFav;
  final VoidCallback onFavTap;
  final double bgLuma;

  const _SongInfo({
    required this.song,
    required this.hPad,
    required this.isTablet,
    required this.isFav,
    required this.onFavTap,
    required this.bgLuma,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // App theme flag — used only for the cast/output pill's surface color
    // below, which is a UI chrome element that should follow the app theme
    // (like every other pill/card in the screen), not the artwork.
    final isLight = Theme.of(context).brightness == Brightness.light;
    // Background-luma-driven (not theme-driven): keeps title/artist legible
    // against the actual rendered artwork background in either app theme.
    final bgIsLight = bgLuma >= 0.5;
    final textPrimary = bgIsLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textSecondary =
        bgIsLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(215);
    final titleSize = isTablet ? 26.0 : 22.0;
    final proximityToEdge = 1.0 - (2.0 * (bgLuma - 0.5).abs()).clamp(0.0, 1.0);
    final shadowColor = bgIsLight
        ? Colors.white.withAlpha((55 + proximityToEdge * 35).round())
        : Colors.black.withAlpha((160 + proximityToEdge * 40).round());
    final shadowBlur1 = bgIsLight ? 7.0 + proximityToEdge * 4 : 16.0 + proximityToEdge * 6;
    const shadowBlur2 = 7.0;
    final textShadows = bgIsLight
        ? [Shadow(color: shadowColor, blurRadius: shadowBlur1)]
        : [
            Shadow(color: shadowColor, blurRadius: shadowBlur1),
            Shadow(color: shadowColor, blurRadius: shadowBlur2),
          ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MarqueeText(
                  text: song.title,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    letterSpacing: -0.5,
                    shadows: textShadows,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.1,
                    shadows: textShadows,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _FavButton(isFav: isFav, onTap: onFavTap),
              const SizedBox(height: 4),
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: isLight
                      ? AurumTheme.lightBgSurface.withAlpha(180)
                      : Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(
                    color: isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CastIconButton(size: 18, color: textSecondary),
                    GestureDetector(
                      onTap: () => showAudioOutputSheet(context),
                      child: Semantics(
                        label: l10n.audioOutputPickerTitle,
                        button: true,
                        child: Padding(
                          // Kept exactly equal to CastIconButton's own
                          // internal tap padding so both icons sit with
                          // identical breathing room inside the pill — see
                          // note below on why both use 9, not 10.
                          padding: const EdgeInsets.all(9),
                          child: Icon(Icons.speaker_group_rounded, size: 18, color: textSecondary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Inline Lyrics Strip — Spotify-style single active line shown between the
// song title/artist and the seek bar. Reuses PlayerProvider.fetchSyncedLyrics()
// (already cached by ApiService), so this never triggers an extra network
// fetch beyond what the full Lyrics tab would already do. Only ever shows
// one line at a time; tapping it jumps straight to the full Lyrics tab.
//
// STABILITY NOTES:
//  - Wrapped in a fixed-height SizedBox so the strip never collapses to
//    zero height (whether loading, between lyric lines, or when a track
//    has no lyrics at all). Without this, every gap between lines — or
//    every song skip while the next track's lyrics are still loading —
//    would yank the seek bar up/down by the strip's height, which reads
//    as the whole player "jumping"/stuttering.
//  - Only the active-line text rebuilds on each playback tick (via a tiny
//    position-listener bridge), not the whole strip — keeps this cheap
//    even at 10 rebuilds/sec while a song plays.
//  - Song-skip is handled by keeping the OLD line on screen until the new
//    song's lyrics resolve, instead of clearing to blank first — avoids a
//    visible blank flash between tracks.
// ─────────────────────────────────────────────────────────────────────────────
class _InlineLyricsStrip extends StatefulWidget {
  final double hPad;
  final double bgLuma;
  final VoidCallback onTap;
  const _InlineLyricsStrip({
    required this.hPad,
    required this.bgLuma,
    required this.onTap,
  });

  @override
  State<_InlineLyricsStrip> createState() => _InlineLyricsStripState();
}

class _InlineLyricsStripState extends State<_InlineLyricsStrip> {
  // ALWAYS the same fixed height whenever this widget is in the tree at
  // all — whether lyrics exist, are still loading, or the current instant
  // has no active line (an instrumental gap). The one and only place the
  // layout ever collapses to zero is the parent's toggle-off branch
  // (`if (!show) return const SizedBox.shrink();`), which sits OUTSIDE
  // this widget entirely. So: toggle off = no box, no gap change ever, no
  // "faltu ka gap" opening up mid-song. Toggle on = this exact box, always,
  // and only the text inside it fades/slides in and out — the box itself
  // never grows, shrinks, or moves.
  static const double _stripHeight = 34.0;

  LyricsResult? _result;
  String? _loadedForId;

  @override
  Widget build(BuildContext context) {
    // FIX: this previously detected song changes only in
    // didChangeDependencies() using context.read — but context.read
    // creates no subscription, so didChangeDependencies had nothing of
    // its own to fire on and only happened to run when some unrelated
    // ancestor rebuilt. That's the same class of gap that was fixed in
    // _LyricsPageState below: explicitly watching currentSong in build()
    // makes detection deterministic on every song change, with no
    // dependency on anything else in the tree choosing to rebuild first.
    final watchedSong = context.watch<PlayerProvider>().currentSong;
    if (watchedSong != null && watchedSong.id != _loadedForId) {
      _loadedForId = watchedSong.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetch();
      });
    }

    // FIX ("lyrics line / buttons illegible depending on artwork
    // brightness"): this was Theme.of(context).brightness, which reflects
    // the app's light/dark MODE setting, not the actual artwork behind
    // this text. A dark-mode user with a bright/light-colored album cover
    // (or vice versa) got near-invisible text, since the color branch was
    // keyed to the wrong signal entirely. Now driven by widget.bgLuma —
    // the real rendered background luminance behind this strip (same
    // value already computed for and used by _SongInfo above it) — so
    // this reads correctly against the actual artwork in either app theme.
    final bgIsLight = widget.bgLuma >= 0.5;
    final activeColor = bgIsLight ? AurumTheme.lightTextPrimary : Colors.white;
    final mutedColor = bgIsLight
        ? AurumTheme.lightTextSecondary
        : Colors.white.withAlpha(150);

    final result = _result;
    Widget content;
    if (result == null || !result.hasAny) {
      // Still resolving, or no lyrics found — empty box, same fixed size.
      content = const SizedBox.shrink();
    } else if (!result.hasSynced) {
      // Plain (unsynced) lyrics — static teaser line.
      content = _PlainLineTeaser(plain: result.plain!, mutedColor: mutedColor);
    } else {
      // Synced lyrics — the ticker only ever fades text in/out inside the
      // fixed-size box below; it never changes the box's own height.
      content = _SyncedLineTicker(
        result: result,
        activeColor: activeColor,
        mutedColor: mutedColor,
      );
    }

    return SizedBox(
      height: _stripHeight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.hPad),
          child: content,
        ),
      ),
    );
  }

  int _fetchGeneration = 0;

  Future<void> _fetch() async {
    // Deliberately does NOT clear _result first — keeps showing the
    // previous track's last line on screen rather than blanking the strip,
    // avoiding a visible flash right at the moment of a song skip.
    //
    // Uses a generation counter rather than a busy-flag: a busy-flag would
    // let an in-flight fetch for song A silently swallow the request for
    // song B if the user skips again before A's fetch resolves. Bumping
    // the generation on every call means only the LATEST request's result
    // is ever applied, but every request still actually fires.
    final myGeneration = ++_fetchGeneration;
    final requestedForId = _loadedForId;
    final result = await context.read<PlayerProvider>().fetchSyncedLyrics();
    if (!mounted) return;
    // Stale response (a newer skip happened while this was in flight, or
    // the song id changed again) — ignore it.
    if (myGeneration != _fetchGeneration || requestedForId != _loadedForId) return;
    setState(() => _result = result);
  }
}

/// Isolates position-driven rebuilds to just this small widget — the
/// active line index is read from PlayerProvider's position every tick,
/// but only this Row (not the whole strip, not the seek bar, not song
/// info) rebuilds as a result.
class _SyncedLineTicker extends StatelessWidget {
  final LyricsResult result;
  final Color activeColor;
  final Color mutedColor;
  // Height when there's no active line (instrumental gap) vs. when a line
  // is on screen. Owning both here — rather than a parent SizedBox fixing
  const _SyncedLineTicker({
    required this.result,
    required this.activeColor,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    final position = context.select<PlayerProvider, Duration>((p) => p.position);
    final idx = result.activeIndexFor(position);
    final lineText =
        (idx >= 0 && idx < result.synced!.length) ? result.synced![idx].text : '';
    final showText = lineText.trim().isNotEmpty;

    // Always fills the parent's fixed-size box (set once, in
    // _InlineLyricsStripState) — this widget never changes its own size.
    // During a gap between timed lines it just fades to nothing and back
    // in the same spot, so the box, and everything below it, never moves.
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.35),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          // AnimatedSwitcher stacks outgoing+incoming children on top of
          // each other during the crossfade; without a shared alignment
          // they can sit at different vertical anchors mid-transition and
          // look like a tiny jump. Pin both to centerLeft explicitly.
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.centerLeft,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          child: showText
              ? Row(
                  key: ValueKey(lineText),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        lineText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: activeColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right_rounded, size: 18, color: mutedColor),
                  ],
                )
              : const SizedBox.shrink(key: ValueKey('empty-line')),
        ),
      ),
    );
  }
}

/// Static single-line teaser for tracks that only have plain (unsynced)
/// lyrics — shown once and never re-animated, since there's no timeline to
/// follow.
class _PlainLineTeaser extends StatelessWidget {
  final String plain;
  final Color mutedColor;
  const _PlainLineTeaser({required this.plain, required this.mutedColor});

  @override
  Widget build(BuildContext context) {
    final firstLine = plain
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            firstLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: mutedColor,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right_rounded, size: 18, color: mutedColor),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seek Bar
// ─────────────────────────────────────────────────────────────────────────────
class _SeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  final double bgLuma;
  const _SeekBar({required this.player, required this.hPad, required this.bgLuma});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  bool _dragging = false;
  double? _dragValue;
  List<double>? _waveform;
  String? _waveformFor;

  // DEBUG ONLY — temporary freeze detector for the "seek bar stuck at
  // 00:00" report. Watches whether duration/position ever become
  // non-zero within 4s of a song becoming current; if not, shows a red
  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadWaveform() async {
    final song = widget.player.currentSong;
    if (song == null) return;
    final key = song.localPath ?? song.streamUrl ?? song.id;
    if (_waveformFor == key) return;
    _waveformFor = key;
    final isLocal = song.isLocal;
    final path = song.localPath ?? song.streamUrl ?? '';
    if (path.isEmpty) return;
    final wf = await WaveformService.getWaveform(path, isLocal: isLocal);
    if (mounted && _waveformFor == key) {
      setState(() => _waveform = wf);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PERF FIX: _SeekBar used to rely on `widget.player` handed down from
    // the parent screen's Consumer, which rebuilt every tick anyway. Now
    // that the parent is gated by Selector (see _FullPlayerScreenState),
    // this widget listens to progress/position/buffered directly so the
    // slider still updates smoothly every tick without pulling the rest
    // of the (much heavier) screen along with it.
    return Selector<PlayerProvider, (double, int, int, String, String, String?, bool)>(
      selector: (_, player) => (
        player.progress,
        player.duration.inMilliseconds,
        player.buffered.inMilliseconds,
        player.positionString,
        player.durationString,
        player.currentSong?.id,
        // Needed so the Waveform slider style's Ticker (see
        // _WaveformSeekBarState) reliably restarts the instant playback
        // resumes, rather than depending on `progress` happening to
        // change on the same frame — pause/resume can otherwise land on
        // a frame where progress is momentarily unchanged, leaving the
        // wave's ticker stopped even though audio has resumed.
        player.isPlaying,
      ),
      builder: (context, data, __) {
        return _buildSeekBar(context);
      },
    );
  }

  Widget _buildSeekBar(BuildContext context) {
    // FIX (same class of bug as the lyrics strip/buttons above): was
    // Theme.of(context).brightness (app theme mode), now driven by the
    // real artwork background luminance so the track/time text stays
    // legible against the actual artwork colors in either app theme.
    final bgIsLight = widget.bgLuma >= 0.5;
    final trackActive = bgIsLight ? AurumTheme.lightTextPrimary : Colors.white;
    final trackInactive = bgIsLight ? AurumTheme.lightBgSurface : Colors.white.withAlpha(28);
    final timeColor = bgIsLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(160);

    // Settings → Appearance → "Player Slider Style"
    final sliderStyle = context.watch<ThemeProvider>().playerSliderStyle;
    final double baseTrackHeight;
    final double thumbRadius;
    switch (sliderStyle) {
      case 'Slim':
        baseTrackHeight = 1.5;
        thumbRadius = 4.5;
        break;
      case 'Thick':
        baseTrackHeight = 6.0;
        thumbRadius = 7.0;
        break;
      case 'Waveform':
        baseTrackHeight = 0;
        thumbRadius = 0;
        break;
      case 'Rounded':
      default:
        baseTrackHeight = 3.0;
        thumbRadius = 5.5;
    }

    if (sliderStyle == 'Waveform') {
      _loadWaveform();
      return _WaveformSeekBar(
        player: widget.player,
        hPad: widget.hPad,
        waveform: _waveform,
        activeColor: trackActive,
        inactiveColor: trackInactive,
        timeColor: timeColor,
        dragging: _dragging,
        dragValue: _dragValue,
        onDragStart: () {
          AurumHaptics.selection();
          setState(() => _dragging = true);
        },
        onDrag: (v) => setState(() => _dragValue = v),
        onDragEnd: (v) {
          AurumHaptics.selection();
          widget.player.seek(v);
          setState(() { _dragging = false; _dragValue = null; });
        },
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _dragging ? baseTrackHeight + 1 : baseTrackHeight,
              thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _dragging ? thumbRadius + 2 : thumbRadius,
                  elevation: _dragging ? 4 : 1,
                  pressedElevation: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor: trackActive,
              inactiveTrackColor: trackInactive,
              thumbColor: trackActive,
              overlayColor: trackActive.withAlpha(22),
              trackShape: const _BufferedTrackShape(),
            ),
            child: Slider(
              value: widget.player.progress,
              secondaryTrackValue: widget.player.duration.inMilliseconds > 0
                  ? (widget.player.buffered.inMilliseconds /
                          widget.player.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0,
              onChangeStart: (_) {
                AurumHaptics.selection();
                setState(() => _dragging = true);
              },
              onChanged: widget.player.seek,
              onChangeEnd: (_) {
                AurumHaptics.selection();
                setState(() => _dragging = false);
              },
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.player.positionString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              Text(widget.player.durationString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _WaveformSeekBar — Material 3 wavy progress indicator style.
// Track (unplayed) is a flat straight line; only the played portion waves.
// Wave phase is driven by actual audio position (ms), not a free-running
// timer, so it never drifts out of sync with playback, pause/resume, or
// seeking. Amplitude is intentionally small ("barely there") — this is the
// calmest of several tested variants and reads as premium, not gimmicky.
// ─────────────────────────────────────────────────────────────────────────────
class _WaveformSeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  final List<double>? waveform;
  final Color activeColor;
  final Color inactiveColor;
  final Color timeColor;
  final bool dragging;
  final double? dragValue;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  const _WaveformSeekBar({
    required this.player,
    required this.hPad,
    required this.waveform,
    required this.activeColor,
    required this.inactiveColor,
    required this.timeColor,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  State<_WaveformSeekBar> createState() => _WaveformSeekBarState();
}

class _WaveformSeekBarState extends State<_WaveformSeekBar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _ampAnim = 0.0; // eases 0→1 on play, 1→0 on pause (flattens the wave)
  Duration _lastElapsed = Duration.zero;

  // Wave shape constants — tuned to the "barely there" variant.
  static const double _wavelength = 26; // px per wave cycle
  static const double _waveSpeed = 14;  // px per second, slow relaxed drift

  double _scrollX = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    // Only actually ticking (60fps work) while playing. When the full
    // player is opened on a paused song, or the user pauses and leaves
    // the screen open, there is nothing left to animate once the wave has
    // flattened — running a Ticker every frame forever in that state is
    // pure wasted work (battery/heat) for a visually static line.
    if (widget.player.isPlaying && !widget.dragging) _ticker.start();
  }

  @override
  void didUpdateWidget(_WaveformSeekBar old) {
    super.didUpdateWidget(old);
    _syncTickerToPlaybackState();
  }

  void _syncTickerToPlaybackState() {
    final shouldRun = widget.player.isPlaying && !widget.dragging;
    if (shouldRun && !_ticker.isTicking) {
      // Resuming from a stopped ticker: reset the elapsed baseline so the
      // next frame's dt isn't measured against a stale timestamp from
      // before the pause (which would otherwise produce one oversized
      // jump in _ampAnim/_scrollX on resume).
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isTicking && _ampAnim <= 0.001) {
      // Only stop once the wave has actually eased back down to flat —
      // stopping mid-ease would freeze the line at a non-zero amplitude
      // instead of settling to the calm straight-line paused state.
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastElapsed).inMilliseconds;
    _lastElapsed = elapsed;
    if (dtMs <= 0) return;
    final dt = (dtMs / 1000.0).clamp(0.0, 0.05);

    final playing = widget.player.isPlaying && !widget.dragging;

    // FIX (wave stutters like it's being dragged by hand): _scrollX used
    // to be re-derived every single frame straight from
    // widget.player.position, but that position only actually changes in
    // ~500ms steps (see player_provider.dart's local position ticker) —
    // so the wave held dead still for ~30 frames, then snapped forward,
    // over and over. That snap-then-freeze pattern is exactly what reads
    // as janky/laggy instead of gliding.
    //
    // Now _scrollX advances every frame by real elapsed time (dt), same
    // as any smooth 60fps animation — it doesn't wait for a new position
    // value to move at all. The real position is only used to correct
    // drift (seek, resume, or the coarse ticker jumping further than one
    // frame's worth of travel), and even then it's blended in gently
    // rather than snapped, so a correction never reads as a visible jump.
    final targetScrollX = (widget.player.position.inMilliseconds / 1000.0) * _waveSpeed;
    if (playing) {
      _scrollX += dt * _waveSpeed;
      final drift = targetScrollX - _scrollX;
      final driftAbs = drift.abs();
      // Small gaps (normal position-ticker catch-up) blend in gently so
      // the correction is invisible. Large gaps — a new song starting,
      // or a seek landing far from where we were — snap immediately;
      // gradually blending a multi-second gap would show the wave
      // visibly crawling toward the correct spot for a second or more,
      // which reads as broken, not smooth.
      if (driftAbs > _waveSpeed * 3.0) {
        _scrollX = targetScrollX;
      } else if (driftAbs > _waveSpeed * 0.12) {
        _scrollX += drift * (dt * 4).clamp(0.0, 1.0);
      }
    } else {
      // Paused (or dragging): follow the real/seek position exactly so
      // the wave doesn't keep drifting on its own while audio is static.
      _scrollX = targetScrollX;
    }

    final target = playing ? 1.0 : 0.0;
    final next = _ampAnim + (target - _ampAnim) * (dt * 6).clamp(0.0, 1.0);
    if ((next - _ampAnim).abs() > 0.001 || playing) {
      setState(() => _ampAnim = next);
    } else if (_ticker.isTicking) {
      // Reached target (flat, paused) — stop burning frames.
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Playback state can change (play/pause, drag start/end) without a
    // new widget instance being created, so this check needs to run on
    // every build too, not just didUpdateWidget — covers the case where
    // only a field the ticker cares about changed via setState elsewhere
    // in the parent without the widget identity changing.
    _syncTickerToPlaybackState();
    final progress = widget.dragging ? (widget.dragValue ?? widget.player.progress) : widget.player.progress;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void handleUpdate(Offset local) {
                final v = (local.dx / width).clamp(0.0, 1.0);
                widget.onDrag(v);
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                // Only the horizontal-drag recognizer is registered here —
                // NOT onTapDown/onTapUp alongside it. Having both competing
                // in the same gesture arena was the actual bug behind "tap
                // se aage nahi badhta": a tap has a tiny bit of finger
                // movement in it, so Flutter's arena sometimes resolved it
                // toward the tap recognizer, sometimes toward drag, and a
                // "lost" tap recognizer eats the touch with no callback
                // firing at all — reads as "only click-and-hold/drag
                // works, plain tap does nothing." A drag recognizer alone
                // already fires onHorizontalDragStart for a zero-distance
                // touch-and-release, so it covers taps too — no separate
                // tap handler needed, and no more two-recognizer race.
                onHorizontalDragStart: (d) {
                  widget.onDragStart();
                  handleUpdate(d.localPosition);
                },
                onHorizontalDragUpdate: (d) => handleUpdate(d.localPosition),
                onHorizontalDragEnd: (_) => widget.onDragEnd(widget.dragValue ?? progress),
                onHorizontalDragCancel: () => widget.onDragEnd(widget.dragValue ?? progress),
                child: CustomPaint(
                  size: Size(width, 32),
                  painter: _WaveformPainter(
                    progress: progress,
                    activeColor: widget.activeColor,
                    inactiveColor: widget.inactiveColor,
                    scrollX: _scrollX,
                    ampAnim: _ampAnim,
                    wavelength: _wavelength,
                    dragging: widget.dragging,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.player.positionString,
                style: TextStyle(color: widget.timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              Text(widget.player.durationString,
                style: TextStyle(color: widget.timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double scrollX;
  final double ampAnim;
  final double wavelength;
  final bool dragging;

  _WaveformPainter({
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.scrollX,
    required this.ampAnim,
    required this.wavelength,
    required this.dragging,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final progressX = size.width * progress;
    // "Barely there" amplitude — small, calm ripple, not a dramatic bounce.
    final maxAmp = size.height * 0.10;
    final k = (2 * math.pi) / wavelength;

    // Track (unplayed): perfectly flat straight line, small gap before it.
    const gap = 6.0;
    if (progressX + gap < size.width) {
      final trackPaint = Paint()
        ..color = inactiveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(progressX + gap, centerY),
        Offset(size.width - 6, centerY),
        trackPaint,
      );
      canvas.drawCircle(
        Offset(size.width - 3, centerY),
        2.0,
        Paint()..color = inactiveColor,
      );
    }

    // Active (played) portion: single sinusoidal wave, constant
    // wavelength/speed, synced to real audio position via scrollX — this
    // is deliberately ONE clean frequency, matching Google's own squiggly
    // slider (Android 13+ media controls / Play Store & Files app
    // progress). Google's version reads as premium not because of a
    // complex waveform, but because of stroke thickness that breathes
    // with the wave (see strokeWidth below) — that's the piece this was
    // missing, not the wave shape itself.
    final activePath = Path();
    bool started = false;
    for (double x = 0; x <= progressX; x += 2) {
      final y = centerY + math.sin(k * (x - scrollX)) * (maxAmp * ampAnim);
      if (!started) {
        activePath.moveTo(x, y);
        started = true;
      } else {
        activePath.lineTo(x, y);
      }
    }

    // Google's squiggly slider gets its "alive" feel from the stroke
    // itself gently thickening and thinning as the wave scrolls, not from
    // the wave's shape or a glow. One uniform stroke width per frame here
    // (not per-point) — cheap, and at this line thickness (~3px) a
    // per-point taper wouldn't read as visually different anyway.
    final breathe = (math.sin((scrollX * 0.6) * (math.pi / wavelength)) * 0.4 + 0.6);
    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0 + 0.8 * breathe * ampAnim
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(activePath, activePaint);

    // Playhead dot rides on the wave — same solid dot as Google's slider
    // uses at the drag handle, no glow (Google's own version doesn't use
    // one either at this size).
    final headY = centerY + math.sin(k * (progressX - scrollX)) * (maxAmp * ampAnim);
    canvas.drawCircle(
      Offset(progressX, headY),
      dragging ? 5.5 : 4.0,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.scrollX != scrollX ||
      old.ampAnim != ampAnim ||
      old.dragging != dragging;
}


class _Controls extends StatelessWidget {
  final PlayerProvider player;
  final double hPad;
  final Animation<double> playBtnAnim;
  final Color bg1;
  final double bgLuma;
  final VoidCallback onPlayTap;

  const _Controls({
    required this.player,
    required this.hPad,
    required this.playBtnAnim,
    required this.bg1,
    required this.bgLuma,
    required this.onPlayTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLoopOne = player.loopMode == LoopMode.one;
    final isLoopAll = player.loopMode == LoopMode.all;
    // FIX ("prev/next buttons invisible depending on artwork"): this was
    // Theme.of(context).brightness (app theme mode) — a dark-mode user
    // with bright/light-colored artwork (or a light-mode user with dark
    // artwork) got the wrong color branch, since app theme and artwork
    // color are two unrelated things. Now driven by bgLuma, the real
    // rendered background luminance behind these controls.
    final bgIsLight = bgLuma >= 0.5;
    final prevNextColor = bgIsLight
        ? AurumTheme.lightTextPrimary
        : Colors.white.withAlpha(220);
    // Same artwork-driven signal for shuffle/repeat's inactive color —
    // passed explicitly so _CtrlBtn never falls back to its own
    // theme-brightness default for these two buttons.
    final inactiveToggleColor = bgIsLight
        ? AurumTheme.lightTextMuted
        : Colors.white.withAlpha(190);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad - 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CtrlBtn(
            icon: Icons.shuffle_rounded,
            size: 20,
            active: player.shuffle,
            inactiveColor: inactiveToggleColor,
            semanticLabel: l10n.fpShuffle,
            onTap: () {
              AurumHaptics.selection();
              player.toggleShuffle();
            },
          ),
          _CtrlBtn(
            icon: Icons.skip_previous_rounded,
            size: 38,
            color: prevNextColor,
            inactiveColor: prevNextColor,
            semanticLabel: l10n.fpPrevious,
            onTap: () {
              AurumHaptics.medium();
              player.skipPrev();
            },
          ),
          ScaleTransition(
            scale: playBtnAnim,
            child: _PremiumPlayButton(
              isPlaying: player.isPlaying,
              isLoading: player.isLoading,
              bg1: bg1,
              onTap: onPlayTap,
            ),
          ),
          _CtrlBtn(
            icon: Icons.skip_next_rounded,
            size: 38,
            color: prevNextColor,
            inactiveColor: prevNextColor,
            semanticLabel: l10n.fpNext,
            onTap: () {
              AurumHaptics.medium();
              player.skipNext().then((allowed) {
                if (!allowed && context.mounted) {
                  PremiumGate.show(
                    context,
                    feature: AppLocalizations.of(context)!.fpUnlimitedSkipsFeature,
                    description: AppLocalizations.of(context)!.fpUnlimitedSkipsSignIn,
                    requiresLoginOnly: true,
                  );
                }
              });
            },
          ),
          _CtrlBtn(
            icon: isLoopOne
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            size: 20,
            active: isLoopAll || isLoopOne,
            inactiveColor: inactiveToggleColor,
            semanticLabel: l10n.fpRepeat,
            onTap: () {
              AurumHaptics.selection();
              player.toggleLoop();
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pills
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPills extends StatelessWidget {
  final Song song;
  final double hPad;
  final double bgLuma;
  const _QualityPills({required this.song, required this.hPad, required this.bgLuma});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final parts = <String>[];
    if (song.isLocal) parts.add(l10n.fpLocalBadge);
    if (song.language != null && song.language!.isNotEmpty) {
      parts.add(song.language!.toUpperCase());
    }
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) return const SizedBox(height: 8);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        children: parts.map((p) => _QualityPill(label: p, bgLuma: bgLuma)).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom Pill
// ─────────────────────────────────────────────────────────────────────────────
class _BottomPill extends StatelessWidget {
  final double hPad;
  final double bgLuma;
  final VoidCallback onTap;
  const _BottomPill({required this.hPad, required this.bgLuma, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // FIX (same class of bug as buttons/lyrics strip above): was
    // Theme.of(context).brightness (app theme mode), now driven by the
    // real artwork background luminance so this pill stays legible
    // against the actual artwork in either app theme.
    final bgIsLight = bgLuma >= 0.5;
    final pillBg = bgIsLight ? AurumTheme.lightBgSurface.withAlpha(200) : Colors.white.withAlpha(18);
    final pillBorder = bgIsLight ? AurumTheme.lightDivider : Colors.white.withAlpha(28);
    final iconColor = bgIsLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(180);
    final textColor = bgIsLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(200);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: GestureDetector(
        onTap: onTap,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -300) onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: pillBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pillBorder, width: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.keyboard_arrow_up_rounded, color: iconColor, size: 16),
              const SizedBox(width: 8),
              Text(
                l10n.fpQueueLyricsInfo,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
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
// Premium Play Button
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Play/Pause button — outward ripple ring on tap (Echo Nightly style).
//
// One-shot ring: a single AnimationController (300ms, not looping) fires
// on every tap, expanding a thin circle from the button's own edge
// outward while fading it out — same tap that also drives the existing
// play⇄pause icon swap, so both read as one unified "press" moment
// instead of two disconnected animations.
//
// LIGHTWEIGHT BY DESIGN (2GB-safe):
//  • The controller only exists/ticks for the ~300ms after a tap — it is
//    NOT a repeating/ambient animation like the background breathe loop,
//    so it costs nothing while idle.
//  • Drawn with a single CustomPaint stroke circle, not a Container/
//    BoxShadow/DecoratedBox stack — one paint call, no extra compositing
//    layers.
//  • Wrapped in its own RepaintBoundary so the ~10 frames of ring
//    animation only re-paint this small circle, not the button's own
//    icon/shadow or anything else on the player screen.
//  • IgnorePointer'd and painted behind the button content, so it never
//    changes hit-testing or the button's existing tap behavior.
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumPlayButton extends StatefulWidget {
  final bool isPlaying, isLoading;
  final Color bg1;
  final VoidCallback onTap;

  const _PremiumPlayButton({
    required this.isPlaying,
    required this.isLoading,
    required this.bg1,
    required this.onTap,
  });

  @override
  State<_PremiumPlayButton> createState() => _PremiumPlayButtonState();
}

class _PremiumPlayButtonState extends State<_PremiumPlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rippleCtrl;
  late final Animation<double> _rippleRadius;
  late final Animation<double> _rippleOpacity;

  @override
  void initState() {
    super.initState();
    _rippleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _rippleRadius = Tween<double>(begin: 34, end: 52).animate(
      CurvedAnimation(parent: _rippleCtrl, curve: Curves.easeOut),
    );
    _rippleOpacity = Tween<double>(begin: 0.45, end: 0.0).animate(
      CurvedAnimation(parent: _rippleCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _rippleCtrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.isLoading) return;
    // Restart from 0 every tap (fromStart, not forward) so rapid
    // play/pause taps always show a fresh clean ring instead of a stale
    // in-flight one jumping partway through.
    _rippleCtrl.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Settings → Appearance → "Player Button Colors": 'Primary' (default,
    // white circle / black icon — current design), 'White' (explicit, same
    // as Primary), 'Accent' (uses the user's chosen accent color).
    final buttonColorMode = context.watch<ThemeProvider>().playerButtonColorMode;
    final accent = context.watch<ThemeProvider>().accentColor;
    final circleColor = buttonColorMode == 'Accent' ? accent : Colors.white;
    final iconColor = buttonColorMode == 'Accent'
        ? (ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : Colors.black)
        : Colors.black;

    return Semantics(
      label: widget.isPlaying ? l10n.fpPause : l10n.fpPlay,
      button: true,
      child: GestureDetector(
        onTap: _handleTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          // LAYOUT FIX: kept at the original 68x68 — this sits in a
          // Row(mainAxisAlignment: spaceBetween) alongside shuffle/prev/
          // next, so growing this widget's own footprint (it was
          // temporarily 112x112) would have pushed those neighbouring
          // buttons apart and made the whole control row look
          // asymmetric/cramped. The ring still needs to paint past this
          // box's edge without being clipped — OverflowBox below lets it
          // do that purely visually, with zero effect on how much space
          // this widget claims in the Row.
          width: 68,
          height: 68,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Ripple ring — behind the button, ignores hits, isolated
              // repaint boundary so its ~10 animated frames never touch
              // the rest of this screen's paint tree. OverflowBox gives
              // it a 112x112 canvas to paint into (52px max radius + 2px
              // stroke headroom) while the outer SizedBox above still
              // only claims 68x68 in the parent Row's layout.
              IgnorePointer(
                child: OverflowBox(
                  minWidth: 112,
                  maxWidth: 112,
                  minHeight: 112,
                  maxHeight: 112,
                  child: RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _rippleCtrl,
                      builder: (context, _) => CustomPaint(
                        size: const Size(112, 112),
                        painter: _rippleCtrl.value == 0
                            ? null
                            : _RippleRingPainter(
                                radius: _rippleRadius.value,
                                opacity: _rippleOpacity.value,
                                color: circleColor,
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: circleColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: circleColor.withAlpha(38),
                      blurRadius: 32,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: widget.bg1.withAlpha(128),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: anim,
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: widget.isLoading
                      ? const SizedBox(
                          key: ValueKey('loading'),
                          width: 26,
                          height: 26,
                          child:
                              Center(child: AurumM3Loader(width: 26, height: 2.5)),
                        )
                      : Icon(
                          widget.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          key: ValueKey(widget.isPlaying),
                          color: iconColor,
                          size: 36,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Thin expanding ring — one stroke circle, no gradient/shadow, cheapest
// possible way to draw this. shouldRepaint only true when values actually
// change (they do, every frame, during the ~300ms it's active — but the
// painter itself is never constructed at all while idle, since the
// AnimatedBuilder above passes painter: null when _rippleCtrl.value == 0).
class _RippleRingPainter extends CustomPainter {
  final double radius;
  final double opacity;
  final Color color;

  _RippleRingPainter({
    required this.radius,
    required this.opacity,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final paint = Paint()
      ..color = color.withOpacity(opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(size.center(Offset.zero), radius, paint);
  }

  @override
  bool shouldRepaint(covariant _RippleRingPainter old) =>
      old.radius != radius || old.opacity != opacity || old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Favourite Button
// ─────────────────────────────────────────────────────────────────────────────
class _FavButton extends StatelessWidget {
  final bool isFav;
  final VoidCallback onTap;
  const _FavButton({required this.isFav, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<ThemeProvider>().accentColor;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: AurumLikeButton(
        isLiked: isFav,
        size: 24,
        likedColor: accent,
        unlikedColor: Colors.white.withAlpha(128),
        onTap: onTap,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pill
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPill extends StatelessWidget {
  final String label;
  final double bgLuma;
  const _QualityPill({required this.label, required this.bgLuma});

  @override
  Widget build(BuildContext context) {
    // FIX ("year/language chip below play button washes out depending on
    // artwork"): this was Theme.of(context).brightness (app theme mode),
    // but this pill sits directly over the artwork/background, not on
    // any surface of its own — needs the real background luminance,
    // same as every other on-artwork control in this file.
    final bgIsLight = bgLuma >= 0.5;
    final fill = bgIsLight
        ? AurumTheme.lightBgSurface.withAlpha(210)
        : Colors.white.withAlpha(24);
    final border = bgIsLight
        ? AurumTheme.lightDivider
        : Colors.white.withAlpha(45);
    final textColor = bgIsLight
        ? AurumTheme.lightTextSecondary
        : Colors.white.withAlpha(220);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border, width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared action helpers — used by both the Full Player options sheet and the
// SongTile quick-actions sheet, so the behaviour (and its fixes) live once.
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the platform share sheet with a clean "Artist — Title" message.
void shareSong(BuildContext context, Song song) {
  final l10n = AppLocalizations.of(context)!;
  final text = l10n.fpShareText(song.artist, song.title);
  Share.share(text, subject: song.title);
}

/// Opens the existing premium Sleep Timer sheet (built for Settings → Player)
/// from anywhere a [PlayerProvider] is available, e.g. the Full Player screen.
void showSleepTimerForSong(BuildContext context, PlayerProvider player) {
  final handler = player.handler;
  bool finishSong = false;
  bool fadeOut = SleepTimerService.instance.lastFadeOutChoice;
  AurumHaptics.light();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withAlpha(150),
    builder: (_) => SleepTimerSheet(
      engine: handler,
      finishSong: finishSong,
      fadeOut: fadeOut,
      onFinishSongChanged: (v) => finishSong = v,
      onFadeOutChanged: (v) => fadeOut = v,
    ),
  );
}

/// Premium song-details sheet: title, artist, album, duration, year, source.
void showSongInfoDialog(BuildContext context, Song song) {
  final l10n = AppLocalizations.of(context)!;
  final isLight = Theme.of(context).brightness == Brightness.light;
  final bgColor = isLight ? AurumTheme.lightBgCard : const Color(0xFF15131C);
  final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
  final textMuted = isLight ? AurumTheme.lightTextSecondary : Colors.white60;
  final divider = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);

  final rows = <MapEntry<String, String>>[
    MapEntry(l10n.fpSongInfoTitle, song.title),
    MapEntry(l10n.fpSongInfoArtist, song.artist),
    if (song.album.isNotEmpty) MapEntry(l10n.fpSongInfoAlbum, song.album),
    if (song.durationString.isNotEmpty) MapEntry(l10n.fpSongInfoDuration, song.durationString),
    if (song.year != null && song.year!.isNotEmpty) MapEntry(l10n.fpSongInfoYear, song.year!),
    if (song.language != null && song.language!.isNotEmpty) MapEntry(l10n.fpSongInfoLanguage, song.language!),
    // Source row intentionally omitted — backend origin (YouTube/JioSaavn/
    // Local) is an internal implementation detail and should never surface
    // in user-facing UI.
  ];

  AurumHaptics.light();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withAlpha(150),
    builder: (_) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor.withAlpha(245),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: divider, width: 0.5)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36, height: 4,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: textMuted.withAlpha(80),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: AurumTheme.gold, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        l10n.fpSongInfo,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  for (final row in rows) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              row.key,
                              style: TextStyle(
                                color: textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              row.value,
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (row.key != rows.last.key)
                      Divider(height: 1, color: divider),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}


class _PremiumOptionsSheet extends StatefulWidget {
  final Song song;
  final PlayerProvider player;
  final Color accentColor;
  final BuildContext rootContext;

  const _PremiumOptionsSheet({
    required this.song,
    required this.player,
    required this.accentColor,
    required this.rootContext,
  });

  @override
  State<_PremiumOptionsSheet> createState() => _PremiumOptionsSheetState();
}

class _PremiumOptionsSheetState extends State<_PremiumOptionsSheet> {
  @override
  void initState() {
    super.initState();
    SleepTimerService.instance.addListener(_onSleepTimerTick);
  }

  @override
  void dispose() {
    SleepTimerService.instance.removeListener(_onSleepTimerTick);
    super.dispose();
  }

  void _onSleepTimerTick() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _downloadSong() {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final downloads = context.read<DownloadProvider>();

    if (downloads.isDownloaded(song.id)) {
      _snack(l10n.fpAlreadyDownloaded);
      return;
    }
    if (downloads.isDownloading(song.id)) {
      _snack(l10n.fpAlreadyDownloading);
      return;
    }
    if (song.isLocal) {
      _snack(l10n.fpAlreadyOnDevice);
      return;
    }

    Navigator.pop(context);
    _snack(l10n.fpDownloadingSong(song.title));

    downloads.download(song).then((started) {
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.fpDownloadFailed(song.title)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final fav = context.watch<FavoritesProvider>();
    final isLiked = fav.isFavorite(song.id);
    final downloads = context.watch<DownloadProvider>();
    final dlItem = downloads.statusOf(song.id);
    final isDownloaded = downloads.isDownloaded(song.id);
    final isDownloading = downloads.isDownloading(song.id);

    final bgColor = isLight
        ? AurumTheme.lightBgCard
        : Color.lerp(widget.accentColor, const Color(0xFF0C0C18), 0.55)!;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textMuted = isLight ? AurumTheme.lightTextSecondary : Colors.white70;
    final tileColor = isLight
        ? AurumTheme.lightBgSurface
        : Colors.white.withAlpha(10);
    final tileBorder = isLight
        ? AurumTheme.lightDivider
        : Colors.white.withAlpha(18);

    final sleepActive = SleepTimerService.instance.isActive;
    final sleepRemainingLabel = sleepActive
        ? '${(SleepTimerService.instance.remaining.inSeconds / 60).ceil()}m'
        : '';

    final actions = [
      _SheetAction(Icons.skip_next_rounded, l10n.fpPlayNext, AurumTheme.gold, () {
        Navigator.pop(context);
        widget.player.playNext(song);
      }),
      _SheetAction(Icons.queue_music_rounded, l10n.fpAddToQueue, Colors.purpleAccent, () {
        Navigator.pop(context);
        widget.player.addToQueue(song);
        _snack(l10n.fpAddedToQueue);
      }),
      _SheetAction(
        isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        isLiked ? l10n.fpLiked : l10n.fpLikeAction,
        const Color(0xFFE1306C),
        () {
          PremiumGate.guard(
            context,
            feature: l10n.fpLikeSongsFeature,
            description: l10n.fpLikeSignInBuildLibrary,
            requiresLoginOnly: true,
            onAllowed: () {
              fav.toggleFavorite(song);
              final nowLiked = fav.isFavorite(song.id);
              _snack(nowLiked ? l10n.fpAddedToLiked : l10n.fpRemovedFromLiked);
            },
          );
        },
      ),
      _SheetAction(Icons.share_rounded, l10n.fpShare, Colors.greenAccent, () {
        Navigator.pop(context);
        shareSong(context, song);
      }),
      _SheetAction(Icons.playlist_add_rounded, l10n.fpSaveToPlaylist, Colors.blueAccent, () {
        Navigator.pop(context);
        showAddToPlaylistSheet(widget.rootContext, song);
      }),
      _SheetAction(Icons.equalizer_rounded, l10n.fpAudioEffects, Colors.orangeAccent, () {
        Navigator.pop(context);
        Navigator.of(widget.rootContext).push(AurumPageRoute(
          builder: (_) => EqualizerScreen(audioEngine: widget.player.handler),
        ));
      }),
      _SheetAction(
        sleepActive ? Icons.bedtime_rounded : Icons.timer_outlined,
        sleepActive ? l10n.fpSleepRemaining(sleepRemainingLabel) : l10n.fpSleepTimer,
        Colors.cyan,
        () {
          Navigator.pop(context);
          showSleepTimerForSong(widget.rootContext, widget.player);
        },
      ),
      _SheetAction(
        isDownloaded
            ? Icons.download_done_rounded
            : isDownloading
                ? Icons.downloading_rounded
                : Icons.download_rounded,
        isDownloaded
            ? l10n.fpDownloaded
            : isDownloading
                ? l10n.fpDownloading
                : l10n.fpDownload,
        AurumTheme.gold,
        () {
          if (isDownloaded) {
            _snack(l10n.fpAlreadyDownloaded);
          } else if (isDownloading) {
            _snack(l10n.fpAlreadyDownloading);
          } else {
            _downloadSong();
          }
        },
      ),
      _SheetAction(Icons.info_outline_rounded, l10n.fpSongInfo, textMuted, () {
        Navigator.pop(context);
        showSongInfoDialog(widget.rootContext, song);
      }),
    ];

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor.withAlpha(isLight ? 240 : 245),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: isLight
                    ? AurumTheme.lightDivider
                    : Colors.white.withAlpha(14),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 16),
                  decoration: BoxDecoration(
                    color: isLight
                        ? AurumTheme.lightTextMuted.withAlpha(80)
                        : Colors.white.withAlpha(40),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Song header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AurumArtwork(url: song.artworkUrl, size: 52, borderRadius: 10),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.title,
                            style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 3),
                          Text(song.artist,
                            style: TextStyle(color: textMuted, fontSize: 12),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Divider(
                    color: isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14),
                    height: 1,
                  ),
                ),
                // Download progress
                if (isDownloading)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(children: [
                      Row(children: [
                        Icon(Icons.download_rounded, size: 14, color: AurumTheme.gold),
                        const SizedBox(width: 8),
                        Text('Downloading ${((dlItem?.progress ?? 0) * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: textMuted, fontSize: 12)),
                      ]),
                      const SizedBox(height: 6),
                      const AurumM3Loader(height: 3, borderRadius: 2),
                    ]),
                  ),
                // Action grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.7,
                    ),
                    itemCount: actions.length,
                    itemBuilder: (_, i) => _SheetActionTile(
                      action: actions[i],
                      tileColor: tileColor,
                      tileBorder: tileBorder,
                      textColor: textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _SheetAction(this.icon, this.label, this.color, this.onTap);
}

class _SheetActionTile extends StatefulWidget {
  final _SheetAction action;
  final Color tileColor;
  final Color tileBorder;
  final Color textColor;
  const _SheetActionTile({
    required this.action,
    required this.tileColor,
    required this.tileBorder,
    required this.textColor,
  });

  @override
  State<_SheetActionTile> createState() => _SheetActionTileState();
}

class _SheetActionTileState extends State<_SheetActionTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        AurumHaptics.selection();
        widget.action.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: _pressed
              ? widget.action.color.withAlpha(isLight ? 30 : 22)
              : widget.tileColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _pressed
                ? widget.action.color.withAlpha(60)
                : widget.tileBorder,
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(widget.action.icon, size: 18, color: widget.action.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.action.label,
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Content Panel — Queue / Lyrics / Info
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumContentPanel extends StatefulWidget {
  final Color bg1, bg2, bg3;
  final int initialTab;
  const _PremiumContentPanel(
      {required this.bg1, required this.bg2, required this.bg3, this.initialTab = 0});

  @override
  State<_PremiumContentPanel> createState() => _PremiumContentPanelState();
}

class _PremiumContentPanelState extends State<_PremiumContentPanel>
    with TickerProviderStateMixin {
  late int _activeTab = widget.initialTab;
  // PERF FIX: was a plain `double _dragY = 0` driven by setState() on
  // every onVerticalDragUpdate callback — that reran this entire State's
  // build() (BackdropFilter blur, tab content list, tab bar, everything)
  // on every touch-move frame during the handle drag. Same bug the main
  // full-player screen already had fixed via _dragYNotifier; applying the
  // identical fix here so only the thin Transform wrapper around the
  // panel rebuilds on drag, not the blur/list/tabs underneath it.
  final ValueNotifier<double> _dragYNotifier = ValueNotifier(0.0);
  double get _dragY => _dragYNotifier.value;
  set _dragY(double v) => _dragYNotifier.value = v;

  late final AnimationController _tabCtrl;
  late final Animation<double> _tabFade;

  // Spring-back-to-zero controller for an aborted drag-to-dismiss.
  late final AnimationController _springBackCtrl;
  Animation<double>? _springBackAnim;

  // Reverse exit animation (translate down + fade out) played before pop.
  late final AnimationController _exitCtrl;
  late final Animation<double> _exitTranslate;
  late final Animation<double> _exitFade;

  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _tabFade = CurvedAnimation(parent: _tabCtrl, curve: Curves.easeOut);
    _tabCtrl.forward();

    _springBackCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420));
    _springBackCtrl.addListener(() {
      if (_springBackAnim != null) {
        _dragY = _springBackAnim!.value;
      }
    });

    _exitCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _exitTranslate = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInCubic));
    // FIX ("swipe up/down Up Next panel pe blur ek alag layer/ghost jaisa
    // dikhta hai"): this used to run on the exact same 0→1 curve as
    // _exitTranslate — so a tap-to-close (no drag, straight to _dismiss())
    // faded this glass panel out while it was still mostly on-screen,
    // blending into the full player behind it for the whole 280ms, same
    // ghost-layer look as the drag case fixed above. Interval delays the
    // fade to only the last 30% of the animation (translate is already
    // most of the way through by then), matching the "hold solid, fade
    // only right at the very end" behavior used everywhere else in this
    // dismiss flow.
    _exitFade = Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(
            parent: _exitCtrl,
            curve: const Interval(0.7, 1.0, curve: Curves.easeInCubic)));
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _springBackCtrl.dispose();
    _exitCtrl.dispose();
    _dragYNotifier.dispose();
    super.dispose();
  }

  void _switchTab(int idx) {
    if (idx == _activeTab) return;
    AurumHaptics.selection();
    _tabCtrl.reverse().then((_) {
      if (!mounted) return;
      setState(() => _activeTab = idx);
      _tabCtrl.forward();
    });
  }

  void _springBackToZero() {
    _springBackAnim = Tween<double>(begin: _dragY, end: 0).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.elasticOut),
    );
    _springBackCtrl
      ..reset()
      ..forward();
  }

  void _dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    AurumHaptics.light();
    _exitCtrl.forward().then((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenH = MediaQuery.of(context).size.height;
    final topInset = MediaQuery.of(context).padding.top;
    // Previously 0.95 * screenH — tall enough to reach almost the very top
    // of the screen, under the status bar/notch, which read as the whole
    // full player relocating upward rather than a sheet rising over it.
    // Cap it well below the safe-area top so there's always a clear gap
    // showing the full player (and status bar) behind the sheet.
    final panelHeight =
        (screenH * 0.80).clamp(360.0, screenH - topInset - 56.0);
    // NOTE: dragFraction/dragOpacity/scale/opacity are NOT computed here —
    // this outer build() only runs once per gesture (see the PERF comment
    // on the ValueListenableBuilder below); the real per-frame versions
    // live inside that builder so a drag-update never reruns this whole
    // method. Only exitOffsetY (driven by _exitCtrl, not _dragY) is needed
    // at this scope.
    final exitOffsetY = _exitTranslate.value * screenH * 0.4;

    // ── Theme-aware glass tint ──
    // Lowered alphas + a thin top highlight = genuine see-through glass
    // depth (you can sense the artwork/bg colors through it) instead of a
    // near-opaque tinted panel. Blur sigma is untouched (still 12) so this
    // stays just as cheap on the GPU — only the paint values changed.
    final List<Color> glassColors = isLight
        ? [
            Color.lerp(widget.bg1, Colors.white, 0.86)!.withAlpha(196),
            Color.lerp(widget.bg2, Colors.white, 0.90)!.withAlpha(204),
            Color.lerp(widget.bg3, Colors.white, 0.94)!.withAlpha(214),
          ]
        : [
            Color.lerp(widget.bg1, const Color(0xFF0A0A16), 0.5)!
                .withAlpha(168),
            Color.lerp(widget.bg2, const Color(0xFF060610), 0.5)!
                .withAlpha(180),
            Color.lerp(widget.bg3, const Color(0xFF020206), 0.6)!
                .withAlpha(198),
          ];

    final borderColor =
        isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(28);
    final highlightColor =
        isLight ? Colors.white.withAlpha(140) : Colors.white.withAlpha(40);
    final handleColor = isLight
        ? AurumTheme.lightTextMuted.withAlpha(90)
        : Colors.white.withAlpha(40);

    return AnimatedBuilder(
      animation: _exitCtrl,
      builder: (context, _) {
        // PERF: dragFraction/dragOpacity/scale depend on _dragY, which now
        // changes every drag-update frame via the ValueNotifier above
        // (not setState). Wrapping just the Transform/Opacity chain in a
        // ValueListenableBuilder — with the actual panel content (blur,
        // tab bar, tab content list) passed through as its static `child`
        // — means only this thin transform math reruns per drag frame.
        // The heavy subtree below is built once and reused untouched,
        // exactly like the main full-player screen's _DragTransform fix.
        return ValueListenableBuilder<double>(
          valueListenable: _dragYNotifier,
          builder: (context, dragY, panelChild) {
            // FIX ("swipe up/down Up Next panel pe blur ek alag layer/
            // ghost jaisa dikhta hai, solid jaisa clean nahi"): opacity
            // used to fall to 0 by just ~40% of a FULL-SCREEN-HEIGHT drag
            // (dragFraction*2.5, where dragFraction = dragY/screenH), so
            // this glass panel started fading into the full player behind
            // it almost immediately — a soft blurred sheet dissolving into
            // another blurred/artwork background reads exactly like a
            // stray floating layer, same root cause as the main
            // swipe-down dismiss fix above (see _DragTransform's FIX
            // comment).
            // NOTE: this panel's own dismiss threshold (see the handle's
            // onVerticalDragEnd below) fires at just _dragY > 90px — a
            // small fraction of screenH — so measuring fade progress
            // against full screenH (as the down-dismiss fix does) would
            // make live-drag opacity barely move at all before release,
            // then jump straight to the separate _exitFade animation.
            // Scaling against 90px (this panel's actual live-drag range)
            // instead keeps the same "hold solid, only fade right at the
            // very end" feel, correctly sized to how far this handle
            // actually travels before letting go.
            final panelDragFraction = (dragY / 90.0).clamp(0.0, 1.0);
            final dragFraction = (dragY / screenH).clamp(0.0, 1.0);
            final dragOpacity =
                (1.0 - ((panelDragFraction - 0.75) / 0.25).clamp(0.0, 1.0));
            final scale = (1.0 - dragFraction * 0.06).clamp(0.88, 1.0);
            final opacity = (dragOpacity * _exitFade.value).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(0, dragY.clamp(0.0, screenH * 0.5) + exitOffsetY),
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topCenter,
                child: Opacity(
                  opacity: opacity,
                  child: panelChild,
                ),
              ),
            );
          },
          child: SizedBox(
                height: panelHeight,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(32)),
                  // Lightweight glass: sigma 16 instead of 24 — still reads as
                  // frosted but noticeably cheaper on GPU. RepaintBoundary
                  // stops it from repainting on every parent rebuild (e.g.
                  // progress-bar ticks from the player above it).
                  child: RepaintBoundary(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(32)),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: glassColors,
                                stops: const [0.0, 0.5, 1.0],
                              ),
                              border: Border(
                                top: BorderSide(color: borderColor, width: 0.5),
                              ),
                            ),
                            child: Column(children: [
                              // Drag-to-dismiss lives ONLY on this handle strip
                              // now. Previously the whole panel (including the
                              // list) was one big GestureDetector for vertical
                              // drag, which raced the CustomScrollView for
                              // gesture-arena ownership on every drag-from-top —
                              // that's what made scrolling feel like it needed
                              // a "second pull" to actually start. Confining it
                              // to the handle means the scrollable area below
                              // has zero competing recognizers — native,
                              // instant, smooth scroll from the very first
                              // pixel of drag.
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) {
                                  if (d.delta.dy > 0) {
                                    _springBackCtrl.stop();
                                    _dragY += d.delta.dy;
                                  }
                                },
                                onVerticalDragEnd: (d) {
                                  if (_dragY > 90 ||
                                      (d.primaryVelocity ?? 0) > 600) {
                                    _dismiss();
                                  } else {
                                    _springBackToZero();
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                      top: 12, bottom: 6),
                                  child: Container(
                                    width: 32,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: handleColor,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: FadeTransition(
                                  opacity: _tabFade,
                                  child: _buildTabContent(),
                                ),
                              ),
                              _buildTabBar(isLight),
                            ]),
                          ),
                          // Thin top edge-light — the bit of light a real
                          // glass pane catches. Pure paint, no extra blur,
                          // so it's free performance-wise.
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 1,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(32)),
                                gradient: LinearGradient(
                                  colors: [
                                    highlightColor,
                                    highlightColor.withAlpha(0),
                                  ],
                                  stops: const [0.0, 1.0],
                                ),
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
      },
    );
  }

  Widget _buildTabContent() {
    switch (_activeTab) {
      case 0:
        return const _QueuePage();
      case 1:
        return const _LyricsPage();
      case 2:
        return const _InfoPage();
      default:
        return const _QueuePage();
    }
  }

  Widget _buildTabBar(bool isLight) {
    final l10n = AppLocalizations.of(context)!;
    final tabs = [
      (Icons.queue_music_rounded, l10n.fpQueue),
      (Icons.lyrics_rounded, l10n.fpLyrics),
      (Icons.info_outline_rounded, l10n.fpInfo),
    ];

    final dividerColor =
        isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);
    final accent = context.watch<ThemeProvider>().accentColor;
    final inactiveColor =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(80);
    final inactiveTextColor =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(color: dividerColor, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: List.generate(tabs.length, (i) {
                final isActive = _activeTab == i;
                return Expanded(
                  child: AurumPressable(
                    scaleAmount: 0.94,
                    haptic: false,
                    onTap: () => _switchTab(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tabs[i].$1,
                            size: 20,
                            color: isActive ? accent : inactiveColor,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tabs[i].$2,
                            style: TextStyle(
                              color: isActive
                                  ? accent
                                  : inactiveTextColor,
                              fontSize: 11,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: isActive ? 18 : 0,
                            height: 2,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Page — Echo Nightly style
// ─────────────────────────────────────────────────────────────────────────────
class _QueuePage extends StatelessWidget {
  const _QueuePage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final mutedIcon =
        isLight ? AurumTheme.lightTextMuted.withAlpha(70) : Colors.white.withAlpha(22);
    final mutedText =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(60);

    return Selector<PlayerProvider, ({List<Song> queue, int? current, bool building})>(
      selector: (_, player) =>
          (queue: player.queue, current: player.currentIndex, building: player.isBuildingQueue),
      builder: (context, data, _) {
        final queue = data.queue;
        final current = data.current;

        if (queue.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.queue_music_rounded,
                    color: mutedIcon, size: 56),
                const SizedBox(height: 16),
                Text(
                  l10n.fpQueueEmpty,
                  style: TextStyle(
                    color: mutedText,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        }

        // Separate now playing from up next
        final upNext = <int>[];
        for (int i = 0; i < queue.length; i++) {
          if (i != current) upNext.add(i);
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Now Playing header
            if (current != null && current < queue.length)
              SliverToBoxAdapter(
                child: _NowPlayingHeader(song: queue[current]),
              ),
            // FIX ("Up Next looks empty/broken right after tapping play"):
            // _buildInitialSmartQueue runs fire-and-forget in the
            // background and can genuinely take several seconds (multiple
            // network signals, each with its own timeout) before any
            // songs land in `queue`. Before this, that whole window showed
            // nothing at all below "Now Playing" — indistinguishable from
            // a real bug, and no user is going to sit and wait 10-15s on
            // a blank screen before assuming the app is broken. This fills
            // that exact window with a visible "still working on it" state
            // instead, and disappears the instant either real songs land
            // (upNext.isNotEmpty above takes over) or the build genuinely
            // finishes empty (data.building flips false, matching the
            // notifyListeners() fix in player_provider.dart's finally
            // block that made sure this flag reliably reaches the UI even
            // when a build ends with zero results).
            if (upNext.isEmpty && data.building)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.fpUpNext,
                        style: TextStyle(
                          color: mutedText,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.8,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const AurumM3Loader(width: 22, height: 2.5),
                          const SizedBox(width: 12),
                          Text(
                            l10n.fpFindingSongs,
                            style: TextStyle(color: mutedText, fontSize: 13),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            // Up Next label
            if (upNext.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Text(
                    l10n.fpUpNext,
                    style: TextStyle(
                      color: mutedText,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
              ),
            // Up next list — drag handle reorders, swipe reveals delete,
            // long-press opens quick actions. SliverReorderableList keeps
            // this on the same lightweight sliver scroll as everything
            // else above (no nested scrollables, no extra scroll
            // controller wiring needed).
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              sliver: SliverReorderableList(
                itemCount: upNext.length,
                // Subtle lift while the item is being dragged (YT Music/
                // Spotify style) — a light scale-up + soft shadow so the
                // dragged tile visibly separates from the rest of the
                // list while it's following the finger. Single Transform +
                // DecoratedBox, no extra controllers — cheap enough to run
                // every frame of the drag.
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final t = Curves.easeOut.transform(animation.value);
                      final scale = 1.0 + (0.03 * t);
                      return Transform.scale(
                        scale: scale,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha((110 * t).round()),
                                blurRadius: 20 * t,
                                offset: Offset(0, 6 * t),
                              ),
                            ],
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: child,
                  );
                },
                onReorder: (oldListIdx, newListIdx) {
                  AurumHaptics.medium();
                  final fromQueueIdx = upNext[oldListIdx];
                  // ReorderableList gives newIndex assuming the item has
                  // already been removed from oldIndex — adjust the same
                  // way ReorderableListView does internally.
                  var toListIdx = newListIdx;
                  if (oldListIdx < newListIdx) toListIdx -= 1;
                  final toQueueIdx = upNext[toListIdx];
                  context.read<PlayerProvider>().moveQueueItem(fromQueueIdx, toQueueIdx);
                },
                itemBuilder: (context, listIdx) {
                  final queueIdx = upNext[listIdx];
                  final isNextUp = listIdx == 0;
                  // FIX ("full player queue reorder galat/sahi se nahi
                  // hota"): this used to wrap the ENTIRE tile in
                  // ReorderableDelayedDragStartListener, but _QueueTile
                  // has its own onTap, onLongPress (quick actions sheet),
                  // AND a horizontal swipe-to-delete gesture — all
                  // competing with the reorder drag's long-press in the
                  // same gesture arena. onLongPress especially interfered,
                  // so press-and-hold on the row read as "open quick
                  // actions" instead of starting a reorder. The drag
                  // trigger now lives ONLY on the drag_handle icon inside
                  // _QueueTile (via reorderIndex below), same fix already
                  // applied to Queue screen and the playlist tile — tap,
                  // long-press, and swipe elsewhere on the row are
                  // unaffected, and the handle is the sole way to drag.
                  return KeyedSubtree(
                    key: ValueKey('${queue[queueIdx].id}_$queueIdx'),
                    child: _QueueTile(
                      song: queue[queueIdx],
                      isCurrent: false,
                      isNextUp: isNextUp,
                      index: listIdx + 1,
                      reorderIndex: listIdx,
                      onTap: () {
                        AurumHaptics.selection();
                        context.read<PlayerProvider>().skipToIndex(queueIdx);
                      },
                      onRemove: () {
                        AurumHaptics.medium();
                        context.read<PlayerProvider>().removeFromQueue(queueIdx);
                      },
                      onPlayNext: () async {
                        AurumHaptics.selection();
                        final song = queue[queueIdx];
                        final p = context.read<PlayerProvider>();
                        await p.removeFromQueue(queueIdx);
                        await p.playNext(song);
                      },
                      onMoveToTop: () {
                        AurumHaptics.selection();
                        final p = context.read<PlayerProvider>();
                        final target = (p.currentIndex ?? 0) + 1;
                        p.moveQueueItem(queueIdx, target);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Header — large card at top of queue
// ─────────────────────────────────────────────────────────────────────────────
class _NowPlayingHeader extends StatelessWidget {
  final Song song;
  const _NowPlayingHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    // FIX: same white-on-white visibility issue as the main title block —
    // low alpha white washed out over bright artwork sections.
    final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(200);
    final cardBg = isLight
        ? AurumTheme.gold.withAlpha(22)
        : AurumTheme.gold.withAlpha(18);
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AurumTheme.gold.withAlpha(40), width: 0.5),
        ),
        child: Row(children: [
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AurumArtwork(url: song.artworkUrl, size: 54, borderRadius: 12),
            ),
            Positioned(
              bottom: 0, right: 0,
              child: Container(
                width: 18, height: 18,
                decoration: BoxDecoration(
                  color: AurumTheme.gold,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(child: _MiniEqualizerIcon(isPlaying: isPlaying)),
              ),
            ),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.fpNowPlaying,
                style: TextStyle(color: AurumTheme.gold.withAlpha(200),
                    fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
              const SizedBox(height: 3),
              Text(song.title,
                style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600, height: 1.2),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(song.artist,
                style: TextStyle(color: textSecondary, fontSize: 12),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini Equalizer Icon — for now playing badge. Bars animate only while
// actually playing; they settle to a calm low state when paused, instead of
// endlessly bouncing regardless of playback state.
// ─────────────────────────────────────────────────────────────────────────────
class _MiniEqualizerIcon extends StatefulWidget {
  final bool isPlaying;
  const _MiniEqualizerIcon({this.isPlaying = true});

  @override
  State<_MiniEqualizerIcon> createState() => _MiniEqualizerIconState();
}

class _MiniEqualizerIconState extends State<_MiniEqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    if (widget.isPlaying) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_MiniEqualizerIcon old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying && !old.isPlaying) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.isPlaying && old.isPlaying) {
      _ctrl.stop();
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
      builder: (_, __) {
        // While paused, bars settle to a low static height instead of
        // freezing mid-bounce at an arbitrary point.
        final v = widget.isPlaying ? _ctrl.value : 0.0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar(widget.isPlaying ? 0.4 + 0.6 * v : 0.3, 7),
            const SizedBox(width: 1),
            _bar(widget.isPlaying ? 0.9 - 0.5 * v : 0.45, 7),
            const SizedBox(width: 1),
            _bar(widget.isPlaying ? 0.6 + 0.4 * v : 0.3, 7),
          ],
        );
      },
    );
  }

  Widget _bar(double f, double maxH) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 2,
        height: maxH * f,
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          borderRadius: BorderRadius.circular(1),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Tile — Echo Nightly style with swipe-to-reveal delete + long-press
// quick actions + next-up accent highlight.
// ─────────────────────────────────────────────────────────────────────────────
class _QueueTile extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final bool isNextUp;
  final int index;
  // FIX: separate from `index` (the 1-based display number shown in the
  // tile) — this is the raw SliverReorderableList position needed by
  // ReorderableDragStartListener below to correctly identify which item
  // is being dragged. Reusing `index` directly would pass the display
  // number (already +1'd) instead of the real list position.
  final int reorderIndex;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onPlayNext;
  final VoidCallback onMoveToTop;

  const _QueueTile({
    required this.song,
    required this.isCurrent,
    this.isNextUp = false,
    required this.index,
    required this.reorderIndex,
    required this.onTap,
    required this.onRemove,
    required this.onPlayNext,
    required this.onMoveToTop,
  });

  @override
  State<_QueueTile> createState() => _QueueTileState();
}

class _QueueTileState extends State<_QueueTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swipeCtrl;
  late Animation<double> _settleAnim;
  double _dragOffset = 0;
  bool _swiped = false;

  static const double _deleteRevealWidth = 76.0;
  static const double _swipeOpenThreshold = 56.0;

  @override
  void initState() {
    super.initState();
    _swipeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _settleAnim = AlwaysStoppedAnimation(0.0);
  }

  @override
  void dispose() {
    _swipeCtrl.dispose();
    super.dispose();
  }

  void _handleSwipeEnd() {
    // Past the full delete-reveal width + a firm flick → remove outright.
    if (_dragOffset.abs() > _deleteRevealWidth + 30) {
      AurumHaptics.heavy();
      _swiped = true;
      _swipeCtrl.forward().then((_) {
        if (mounted) widget.onRemove();
      });
      return;
    }
    // Past the open threshold → snap fully open to reveal the delete
    // button (Spotify/YT Music style), rather than springing back.
    if (_dragOffset.abs() > _swipeOpenThreshold) {
      AurumHaptics.light();
      final fromOffset = _dragOffset;
      _settleAnim = Tween<double>(begin: fromOffset, end: -_deleteRevealWidth)
          .animate(CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic));
      _swipeCtrl.forward(from: 0.0).then((_) {
        if (mounted) setState(() => _dragOffset = -_deleteRevealWidth);
        _swipeCtrl.reset();
      });
      return;
    }
    // Otherwise spring back closed.
    final fromOffset = _dragOffset;
    _settleAnim = Tween<double>(begin: fromOffset, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _dragOffset = 0);
      _swipeCtrl.reset();
    });
  }

  void _closeSwipe() {
    if (_dragOffset == 0) return;
    final fromOffset = _dragOffset;
    _settleAnim = Tween<double>(begin: fromOffset, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _dragOffset = 0);
      _swipeCtrl.reset();
    });
  }

  void _confirmDelete() {
    AurumHaptics.heavy();
    setState(() => _swiped = true);
    widget.onRemove();
  }

  void _showQuickActions() {
    AurumHaptics.medium();
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (sheetCtx) => _QueueQuickActionsSheet(
        song: widget.song,
        isLight: isLight,
        onPlayNext: () {
          Navigator.pop(sheetCtx);
          widget.onPlayNext();
        },
        onMoveToTop: () {
          Navigator.pop(sheetCtx);
          widget.onMoveToTop();
        },
        onRemove: () {
          Navigator.pop(sheetCtx);
          _confirmDelete();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_swiped) return const SizedBox.shrink();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _swipeCtrl,
        builder: (_, child) {
          final offset = _swiped
              ? _dragOffset
              : (_swipeCtrl.isAnimating || _dragOffset == _settleAnim.value)
                  ? _settleAnim.value
                  : _dragOffset;
          final revealFrac =
              (offset.abs() / _deleteRevealWidth).clamp(0.0, 1.0);
          return Stack(
            children: [
              // ── Delete action revealed behind the tile (Spotify/YT
              // Music style) — fades/scales in as the tile slides away,
              // never visible at rest.
              if (revealFrac > 0)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: GestureDetector(
                          onTap: _confirmDelete,
                          child: Container(
                            width: _deleteRevealWidth - 8,
                            height: double.infinity,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Color.lerp(
                                  Colors.red.withAlpha(140),
                                  Colors.red.withAlpha(230),
                                  revealFrac),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Opacity(
                              opacity: revealFrac,
                              child: const Icon(Icons.delete_rounded,
                                  color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(offset, 0),
                child: child,
              ),
            ],
          );
        },
        child: GestureDetector(
          onTap: () {
            if (_dragOffset != 0) {
              _closeSwipe();
              return;
            }
            widget.onTap();
          },
          onLongPress: _showQuickActions,
          onHorizontalDragUpdate: (d) {
            _swipeCtrl.stop();
            setState(() {
              _dragOffset += d.delta.dx;
              _dragOffset = _dragOffset.clamp(-_deleteRevealWidth - 30, 0.0);
            });
          },
          onHorizontalDragEnd: (_) => _handleSwipeEnd(),
          child: Builder(builder: (context) {
            final tileBg = widget.isNextUp
                ? (isLight
                    ? AurumTheme.gold.withAlpha(20)
                    : AurumTheme.gold.withAlpha(16))
                : (isLight
                    ? AurumTheme.lightBgSurface.withAlpha(180)
                    : Colors.white.withAlpha(7));
            final tileBorder = widget.isNextUp
                ? AurumTheme.gold.withAlpha(isLight ? 70 : 55)
                : (isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(10));
            final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white.withAlpha(220);
            final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(80);
            final indexColor = widget.isNextUp
                ? AurumTheme.gold.withAlpha(200)
                : (isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(45));
            final dragColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(40);

            return Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: tileBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: tileBorder,
                  width: widget.isNextUp ? 1.0 : 0.5,
                ),
              ),
              child: Row(children: [
                // Subtle next-up accent bar — a quiet gradient sliver,
                // not a loud badge, so it reads as "this one's coming up"
                // without competing with the now-playing card above.
                if (widget.isNextUp)
                  Container(
                    width: 3,
                    height: 36,
                    margin: const EdgeInsets.only(right: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AurumTheme.gold.withAlpha(220),
                          AurumTheme.gold.withAlpha(90),
                        ],
                      ),
                    ),
                  ),
                SizedBox(
                  width: 22,
                  child: Text('${widget.index}',
                    style: TextStyle(color: indexColor, fontSize: 12, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center),
                ),
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(url: widget.song.artworkUrl, size: 44, borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.song.title,
                      style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(widget.song.artist,
                      style: TextStyle(color: textSecondary, fontSize: 11.5),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
                const SizedBox(width: 8),
                // FIX (YT Music-style "drag handle ko press karke song ko
                // list mein kahi bhi drop karna" not working reliably):
                // this used to be a plain ReorderableDragStartListener
                // (starts the reorder drag the instant ANY pan begins,
                // including near-zero horizontal jitter). But the handle
                // sits inside the same tile as the outer GestureDetector's
                // onHorizontalDragUpdate/onHorizontalDragEnd (swipe-to-
                // delete) above — both recognizers enter the SAME gesture
                // arena on touch-down at that point, and Flutter resolves
                // an ambiguous pan-vs-horizontal-drag race unpredictably,
                // so a press-and-drag on the handle was frequently getting
                // intercepted as a swipe-to-delete gesture instead of
                // starting the reorder, especially on a slightly diagonal
                // first movement (extremely common with a thumb, not a
                // precise mouse cursor).
                //
                // GestureDetector(behavior: opaque) wraps the handle with
                // its own hit-test boundary so its pan recognizer claims
                // the touch on this small icon before it can ever reach
                // the outer tile's horizontal-drag recognizer — the two
                // gestures no longer share an arena at all here. Switched
                // to the Delayed variant (small long-press-to-arm window
                // before the drag starts) so a quick tap still reaches
                // onTap/onLongPress normally, and once armed the item
                // follows the finger to ANY position in the list exactly
                // like YouTube Music/Spotify, not just adjacent swaps.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: ReorderableDelayedDragStartListener(
                    index: widget.reorderIndex,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.drag_handle_rounded, color: dragColor, size: 18),
                    ),
                  ),
                ),
              ]),
            );
          }),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Quick Actions Sheet — Play Next / Move to Top / Remove
// ─────────────────────────────────────────────────────────────────────────────
class _QueueQuickActionsSheet extends StatelessWidget {
  final Song song;
  final bool isLight;
  final VoidCallback onPlayNext;
  final VoidCallback onMoveToTop;
  final VoidCallback onRemove;

  const _QueueQuickActionsSheet({
    required this.song,
    required this.isLight,
    required this.onPlayNext,
    required this.onMoveToTop,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bg = isLight ? Colors.white : const Color(0xFF15141C);
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(120);
    final dividerColor = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(url: song.artworkUrl, size: 44, borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title,
                      style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(song.artist,
                      style: TextStyle(color: textSecondary, fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
              ]),
            ),
            Divider(color: dividerColor, height: 1),
            _actionTile(
              icon: Icons.skip_next_rounded,
              label: l10n.fpPlayNext,
              textPrimary: textPrimary,
              onTap: onPlayNext,
            ),
            _actionTile(
              icon: Icons.vertical_align_top_rounded,
              label: l10n.fpMoveToTop,
              textPrimary: textPrimary,
              onTap: onMoveToTop,
            ),
            _actionTile(
              icon: Icons.delete_outline_rounded,
              label: l10n.fpRemoveFromQueue,
              textPrimary: Colors.redAccent,
              onTap: onRemove,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required Color textPrimary,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(children: [
          Icon(icon, color: textPrimary, size: 21),
          const SizedBox(width: 16),
          Text(label,
              style: TextStyle(
                  color: textPrimary, fontSize: 14.5, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics Page
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPage extends StatefulWidget {
  const _LyricsPage();

  @override
  State<_LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<_LyricsPage> {
  LyricsResult? _result;
  bool _loading = true;
  bool _notFound = false;
  Song? _loadedFor;
  int _activeIndex = -1;

  // Bumped on every fetch so a late-arriving response from a previous
  // song's in-flight request can never overwrite the lyrics for whatever
  // song is current by the time it resolves (same fix as
  // _InlineLyricsStripState._fetch above).
  int _fetchGeneration = 0;

  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener = ItemPositionsListener.create();

  Future<void> _fetchLyrics() async {
    if (!mounted) return;
    final myGeneration = ++_fetchGeneration;
    final requestedForId = _loadedFor?.id;
    setState(() {
      _loading = true;
      _notFound = false;
      _result = null;
      _activeIndex = -1;
    });
    final result = await context.read<PlayerProvider>().fetchSyncedLyrics();
    if (!mounted) return;
    // Stale response — a newer song change (and fetch) happened while this
    // one was in flight. Ignore it so old lyrics can never clobber the
    // current song's.
    if (myGeneration != _fetchGeneration || requestedForId != _loadedFor?.id) {
      return;
    }
    setState(() {
      _loading = false;
      if (result.hasAny) {
        _result = result;
      } else {
        _notFound = true;
      }
    });
  }

  void _onPositionChanged(Duration position) {
    final result = _result;
    if (result == null || !result.hasSynced) return;
    final idx = result.activeIndexFor(position);
    if (idx != _activeIndex) {
      _activeIndex = idx;
      if (idx >= 0 && _scrollController.isAttached) {
        _scrollController.scrollTo(
          index: idx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          // Keeps the active line roughly a third of the way down the
          // viewport instead of pinned to the very top.
          alignment: 0.35,
        );
      }
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // FIX: this widget previously detected song changes only via
    // didChangeDependencies, which fires solely when THIS widget's own
    // InheritedWidget subscriptions change — and nothing on the actual
    // path from here up to _FullPlayerScreen's build() subscribed to
    // PlayerProvider (the tab content above is wrapped only in a
    // FadeTransition, no Selector/Consumer/context.watch on it). So
    // detection depended on some unrelated part of the tree happening to
    // rebuild first — exactly the gap that let the lyrics tab keep
    // showing the previous song after a skip. Explicitly watching
    // currentSong here makes this widget rebuild deterministically the
    // instant the song changes, every time, with no dependency on
    // anything else in the tree choosing to rebuild.
    final song = context.watch<PlayerProvider>().currentSong;
    if (song != null && song.id != _loadedFor?.id) {
      _loadedFor = song;
      // _fetchLyrics() calls setState, which can't run synchronously from
      // inside build() — schedule it for right after this frame instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchLyrics();
      });
    }

    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final mutedIcon =
        isLight ? AurumTheme.lightTextMuted.withAlpha(80) : Colors.white.withAlpha(25);
    final primaryMuted =
        isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(140);
    final secondaryMuted =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);

    Widget content;
    if (_loading) {
      content = const Center(
        key: ValueKey('loading'),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: AurumMorphLoader(),
        ),
      );
    } else if (_notFound) {
      content = Center(
        key: const ValueKey('not-found'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lyrics_rounded, color: mutedIcon, size: 52),
            const SizedBox(height: 16),
            Text(
              l10n.fpNoLyricsFound,
              style: TextStyle(
                color: primaryMuted,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.fpLyricsNotAvailable,
              style: TextStyle(color: secondaryMuted, fontSize: 13),
            ),
          ],
        ),
      );
    } else if (_result!.hasSynced) {
      final rawLines = _result!.synced!;
      final hasDevanagari = rawLines.any(
        (l) => DevanagariTransliterator.containsDevanagari(l.text),
      );
      // Always romanize when the fetched lyrics contain Devanagari — no
      // user toggle, this is the only display mode now.
      final displayLines = hasDevanagari
          ? rawLines
              .map((l) => LyricLine(
                    time: l.time,
                    text: DevanagariTransliterator.transliterate(l.text),
                  ))
              .toList()
          : rawLines;
      content = _SyncedLyricsView(
        key: const ValueKey('synced-lyrics'),
        lines: displayLines,
        activeIndex: _activeIndex,
        scrollController: _scrollController,
        positionsListener: _positionsListener,
        onPositionChanged: _onPositionChanged,
      );
    } else {
      final rawPlain = _result!.plain ?? '';
      final hasDevanagari = DevanagariTransliterator.containsDevanagari(rawPlain);
      final displayPlain = hasDevanagari
          ? DevanagariTransliterator.transliterate(rawPlain)
          : rawPlain;
      content = ValueListenableBuilder<LyricsStyle>(
        key: const ValueKey('plain-lyrics'),
        valueListenable: AudioPrefs.lyricsStyleNotifier,
        builder: (context, style, _) {
          final lyricsColor =
              isLight ? AurumTheme.lightTextPrimary : Colors.white.withAlpha(200);
          return TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(0, (1 - v) * 12),
                child: child,
              ),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: Text(
                displayPlain,
                textAlign: style.position == 'Left' ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: lyricsColor,
                  // FIX: was style.textSize + 6, same size-vs-setting
                  // mismatch as the synced view below — now truthful to
                  // what the user picked in settings.
                  fontSize: style.textSize,
                  height: style.lineSpacing,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          );
        },
      );
    }

    // Keep listening for playback position even while showing loading/
    // not-found content, so a late-arriving fetch is synced immediately.
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: content,
          ),
        ),
        Positioned.fill(
          child: _PositionListenerBridge(onPositionChanged: _onPositionChanged),
        ),
      ],
    );
  }
}

/// Invisible widget that just re-runs [onPositionChanged] whenever
/// PlayerProvider's position updates, without rebuilding the lyrics list
/// itself (that's handled manually via setState in the parent for the
/// active-line index only — avoids rebuilding all lyric rows every tick).
class _PositionListenerBridge extends StatelessWidget {
  final void Function(Duration) onPositionChanged;
  const _PositionListenerBridge({required this.onPositionChanged});

  @override
  Widget build(BuildContext context) {
    final position = context.select<PlayerProvider, Duration>((p) => p.position);
    WidgetsBinding.instance.addPostFrameCallback((_) => onPositionChanged(position));
    return const SizedBox.shrink();
  }
}

class _SyncedLyricsView extends StatelessWidget {
  final List<LyricLine> lines;
  final int activeIndex;
  final ItemScrollController scrollController;
  final ItemPositionsListener positionsListener;
  final void Function(Duration) onPositionChanged;

  const _SyncedLyricsView({
    super.key,
    required this.lines,
    required this.activeIndex,
    required this.scrollController,
    required this.positionsListener,
    required this.onPositionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ValueListenableBuilder<LyricsStyle>(
      valueListenable: AudioPrefs.lyricsStyleNotifier,
      builder: (context, style, _) {
        final activeColor =
            isLight ? AurumTheme.lightTextPrimary : Colors.white;
        final inactiveColor = isLight
            ? AurumTheme.lightTextMuted.withAlpha(150)
            : Colors.white.withAlpha(85);
        // Soft glow tint behind the active line — same hue as the text,
        // just a translucent halo. This is the detail that reads as
        // "paid app" rather than a plain bold-and-bigger swap: real
        // premium lyrics UIs (Spotify/Apple Music) give the current line
        // a subtle luminous quality, not just a weight change.
        final glowColor =
            (isLight ? AurumTheme.lightTextPrimary : Colors.white)
                .withAlpha(isLight ? 40 : 55);

        final list = ScrollablePositionedList.builder(
          key: const ValueKey('synced-list'),
          itemScrollController: scrollController,
          itemPositionsListener: positionsListener,
          physics: const BouncingScrollPhysics(),
          // Extra top padding gives the first few lines room to sit below
          // the fade mask instead of emerging from directly under it;
          // extra bottom padding keeps the last lines reachable above the
          // tab bar, same as before.
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 220),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final isActive = index == activeIndex;
            if (line.text.isEmpty) {
              return const SizedBox(height: 22);
            }
            // FIX ("full lyrics panel is bigger than the Settings →
            // Player & Audio lyrics size slider says"): this previously
            // added a flat +8 to style.textSize (then +4 more for the
            // active line), so a user who picked 16sp actually got 24–28sp
            // on screen — the size on screen never matched the number they
            // set. Now the base line genuinely IS style.textSize, so the
            // slider is truthful at every setting. The active line still
            // gets a proportional (not flat) bump — 12% larger — so it
            // stays the clear focal point at any chosen size without the
            // absolute offset overpowering small settings or barely
            // registering on large ones.
            final baseSize = style.textSize;
            final activeSize = baseSize * 1.12;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => context.read<PlayerProvider>().seekTo(line.time),
                child: AnimatedScale(
                  // Matches the 320ms scroll-to duration in
                  // _onPositionChanged so the line's own emphasis (scale +
                  // text style + glow) lands in the same beat as the
                  // scroll settling on it, instead of the text style
                  // finishing early and the scroll catching up after.
                  scale: isActive ? 1.05 : 1.0,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  alignment: style.position == 'Left'
                      ? Alignment.centerLeft
                      : Alignment.center,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    padding: const EdgeInsets.symmetric(
                        vertical: 11, horizontal: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: isActive
                          ? glowColor.withAlpha((glowColor.alpha * 0.5).round())
                          : Colors.transparent,
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: glowColor,
                                blurRadius: 28,
                                spreadRadius: -6,
                              ),
                            ]
                          : null,
                    ),
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      style: TextStyle(
                        color: isActive ? activeColor : inactiveColor,
                        fontSize: isActive ? activeSize : baseSize,
                        height: style.lineSpacing,
                        fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                        letterSpacing: 0.1,
                        // A faint text shadow only on the active line adds
                        // the last bit of depth/lift that makes it feel
                        // lit from within rather than just a font-weight
                        // swap — the same trick Apple Music's lyrics use.
                        shadows: isActive
                            ? [
                                Shadow(
                                  color: glowColor,
                                  blurRadius: 18,
                                ),
                              ]
                            : null,
                      ),
                      child: Text(
                        line.text,
                        textAlign: style.position == 'Left'
                            ? TextAlign.left
                            : TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );

        // Top/bottom fade mask — the detail that most reads as "premium
        // scrolling surface" rather than a plain list: lines don't hard-
        // clip at the viewport edge, they dissolve into the background,
        // exactly like Spotify/Apple Music's lyrics screens. Pure
        // ShaderMask, no extra widgets rebuilding per scroll tick.
        return ShaderMask(
          shaderCallback: (rect) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.06, 0.88, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: list,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info Page
// ─────────────────────────────────────────────────────────────────────────────
class _InfoPage extends StatelessWidget {
  const _InfoPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return const SizedBox.shrink();

    final cardBg = isLight ? AurumTheme.lightBgSurface : Colors.white.withAlpha(7);
    final cardBorder = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(12);
    final dividerColor = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(10);
    final labelColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);
    final valueColor = isLight ? AurumTheme.lightTextPrimary : Colors.white;

    final rows = <_InfoRow>[];
    if (song.album.isNotEmpty) rows.add(_InfoRow(l10n.fpSongInfoAlbum, song.album));
    if (song.artist.isNotEmpty) rows.add(_InfoRow(l10n.fpSongInfoArtist, song.artist));
    if (song.year != null && song.year!.isNotEmpty) {
      rows.add(_InfoRow(l10n.fpSongInfoYear, song.year!));
    }
    if (song.language != null && song.language!.isNotEmpty) {
      rows.add(_InfoRow(l10n.fpSongInfoLanguage, song.language!));
    }
    if (song.duration != null) {
      rows.add(_InfoRow(l10n.fpSongInfoDuration, song.durationString));
    }
    rows.add(_InfoRow(l10n.fpSourceLabel, song.isLocal ? l10n.fpLocalLibrary : l10n.fpOnlineStream));

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        _InfoHeader(song: song),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cardBorder, width: 0.5),
          ),
          child: Column(
            children: List.generate(rows.length, (i) {
              return Column(children: [
                _buildInfoRow(rows[i].label, rows[i].value, labelColor, valueColor),
                if (i < rows.length - 1)
                  Divider(
                    color: dividerColor,
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                  ),
              ]);
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, Color labelColor, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoHeader extends StatelessWidget {
  final Song song;
  const _InfoHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final titleColor = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final artistColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(120);

    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AurumArtwork(url: song.artworkUrl, size: 72, borderRadius: 14),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              song.title,
              style: TextStyle(
                color: titleColor,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              song.artist,
              style: TextStyle(
                color: artistColor,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ]);
  }
}

class _InfoRow {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// _BgLayer — Flagship quality background
//
// Architecture (GPU-budget aware):
//   Layer 0: Solid base color (0 cost)
//   Layer 1: Blurred artwork — rendered ONCE via ImageFiltered, no reblur on anim
//   Layer 2: Gradient overlay — cheap Container, no blur
//   Layer 3: 3 ambient glow orbs via CustomPainter (drawOval, no shader)
//   Layer 4: Vignette gradient — cheap Container
//
// Single AnimationController drives everything via AnimatedBuilder.
// RepaintBoundary isolates all repaints from parent tree.
// ─────────────────────────────────────────────────────────────────────────────
class _BgLayer extends StatelessWidget {
  final Song song;
  final AnimationController bgCtrl;
  final Color startBg1, startBg2, startBg3, startBg4;
  final Color targetBg1, targetBg2, targetBg3, targetBg4;
  final bool isDragging;

  const _BgLayer({
    required this.song,
    required this.bgCtrl,
    required this.startBg1,
    required this.startBg2,
    required this.startBg3,
    required this.startBg4,
    required this.targetBg1,
    required this.targetBg2,
    required this.targetBg3,
    required this.targetBg4,
    this.isDragging = false,
  });

  // FIX (lag): this used to be built entirely inside the AnimatedBuilder
  // driven by the breathe controller (18s continuous loop). That forced
  // the 40-42σ blurred-artwork layer — the most expensive single paint
  // op on this whole screen — to rebuild its widget subtree 60 times a
  // second, forever, any time the full player was on screen, whether or
  // not the song ever changed. RepaintBoundary alone doesn't prevent that
  // rebuild cost; only building it outside the animated scope does.
  //
  // Now: the blurred artwork is built ONCE per song (via a ValueKey on
  // song.id + bg1, so it only rebuilds on an actual track/palette change),
  // and only the cheap orb/gradient/vignette layers sit inside the
  // breathe-driven AnimatedBuilder.
  @override
  Widget build(BuildContext context) {
    // ROOT-CAUSE FIX (uniform gray/white wash on full-player open — see
    // the matching FIX comment on the initState color-seeding call site
    // above for the full mechanism). This is the more important of the
    // two call sites: _BgLayer is what actually paints the large blurred
    // background behind the entire player on every build, not just the
    // first. Reading Theme.of(context).brightness here directly — instead
    // of context.watch<ThemeProvider>().isDarkOf(context), the single
    // already-resolved source of truth main.dart/pushFullPlayer/this
    // screen's own Scaffold all use — meant this widget specifically could
    // still take the wrong (light) branch for a frame at route-mount time
    // even after every other call site in this file had already been
    // migrated to isDarkOf. context.watch (not read) so this also stays
    // correct if the user's theme genuinely changes while the player is
    // open, matching every other isDarkOf call site in this file.
    final isLight = !context.watch<ThemeProvider>().isDarkOf(context);

    return ValueListenableBuilder<bool>(
      valueListenable: AudioPrefs.showBlurredBgNotifier,
      builder: (context, showBlur, _) => AnimatedBuilder(
      animation: bgCtrl,
      builder: (context, _) {
        final t = bgCtrl.value; // 0→1: song change morph
        final bg1 = Color.lerp(startBg1, targetBg1, t)!;
        final bg2 = Color.lerp(startBg2, targetBg2, t)!;
        final bg3 = Color.lerp(startBg3, targetBg3, t)!;
        final bg4 = Color.lerp(startBg4, targetBg4, t)!;

        // FIX (black-flash on song change, part 2) — pairs with the
        // fadeIn:true fix inside _BlurredArtworkCore/AurumArtwork above.
        // That fix makes the NEW image fade in once it starts loading,
        // but the ValueKey below still means Flutter discards the OLD
        // _StaticBlurArtwork widget instantly the moment song.id changes
        // — so the previous blurred artwork was gone from the tree
        // before the new one had anything to show, leaving the same
        // gap (base ColoredBox showing through) for however long the
        // new image took to decode. Wrapping in AnimatedSwitcher keeps
        // the outgoing widget alive and cross-fades it out over the same
        // window the incoming one fades in, so there's always a blurred
        // image on screen during the transition — a proper dissolve
        // between covers instead of a flash to bare background.
        //
        // Settings → Appearance → "Show Blurred Background" (showBlur,
        // from the ValueListenableBuilder above). When off, skip the
        // blurred-artwork layer entirely — no ImageFiltered blur render,
        // no Ken Burns Transform/AnimatedBuilder tick, none of it. What's
        // left underneath (L0 base + L2 palette tint/vignette) already
        // reads as a clean, intentional gradient background on its own
        // — this is the true zero-blur-cost path, not just a cheaper blur.
        // FIX ("Solid mode jaisa hi Blur mode mein bhi — poore drag ke
        // dauraan blur bana rahe, jab tak dismiss COMPLETE na ho jaaye;
        // sirf background mein jo Home content ke saath ghost/blend
        // dikhta tha wahi clean ho, blur khud nahi"): a previous attempt
        // here hid the entire staticBlur subtree the instant isDragging
        // went true — that matched Solid mode's LOOK but not what was
        // actually asked for: the blur itself should stay fully present
        // for the whole swipe, exactly like Solid mode's flat color stays
        // present for the whole swipe. The actual problem was never the
        // blur being visible — it was the blur staying non-opaque (see
        // _DragTransform's opacity curve) long enough to visibly blend
        // with Home's live route underneath. That's fixed at the opacity
        // level in _DragTransform below (delayed to the very end of the
        // drag), not by removing this layer. Reverted to always render
        // when showBlur is on, regardless of isDragging — isDragging is
        // still used inside _StaticBlurArtwork/_BlurredArtworkCore to
        // freeze the Ken Burns motion (perf only, doesn't hide anything).
        final staticBlur = !showBlur
            ? const SizedBox.expand()
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.expand,
                  children: [...previousChildren, if (currentChild != null) currentChild],
                ),
                child: _StaticBlurArtwork(
                  key: ValueKey('${song.id}_${song.artworkUrl}'),
                  song: song,
                  isLight: isLight,
                  isDragging: isDragging,
                ),
              );

        return isLight
            ? _buildLight(bg1, bg2, bg3, bg4, staticBlur)
            : _buildDark(bg1, bg2, bg3, bg4, staticBlur);
      },
      ),
    );
  }

  // ── LIGHT MODE ── artwork color reads through clearly, just enough
  // warm-white lift to keep the "light mode" feel and text legible.
  //
  // SIMPLIFIED (3-layer, same cut as dark mode): dropped the separate
  // white-lift layer and the breathe-driven orb layer — one static
  // painter now handles both the subtle white lift and the vignette in
  // a single paint call, with no per-frame rebuild at all.
  Widget _buildLight(Color bg1, Color bg2, Color bg3, Color bg4, Widget staticBlur) {
    final dynamicColor = AudioPrefs.dynamicPlayerColorNotifier.value;
    final bgStyle = AudioPrefs.effectivePlayerBgStyle;
    if (!dynamicColor) {
      bg1 = Color.lerp(AurumTheme.gold, Colors.white, 0.52)!;
      bg2 = Color.lerp(AurumTheme.goldDark, Colors.white, 0.44)!;
      bg3 = Color.lerp(AurumTheme.goldDark, Colors.white, 0.35)!;
      bg4 = Color.lerp(AurumTheme.goldLight, Colors.white, 0.58)!;
    }

    if (bgStyle == 'Solid') return ColoredBox(color: bg1);

    return Stack(fit: StackFit.expand, children: [
      // L0: Neutral warm-grey base (was near-white — that pre-tinted
      // everything before the artwork colour even landed, which is what
      // made light mode read as washed out regardless of the art).
      // Nudged slightly warmer/deeper than a flat beige so it reads as
      // an intentional warm neutral rather than generic off-white.
      const ColoredBox(color: Color(0xFFE8E2D6)),

      // L1: Ken Burns blurred artwork — the whole "premium" effect.
      staticBlur,

      // L2: One static layer — barely-there palette-tinted lift (was its
      // own flat white ColoredBox layer) combined with the top/bottom
      // readability vignette, drawn once in a single CustomPaint.
      RepaintBoundary(
        child: CustomPaint(
          painter: _LightVignettePainter(tint: bg1),
          size: Size.infinite,
        ),
      ),
    ]);
  }

  // ── DARK MODE ── Echo Nightly spec: artwork IS the background.
  //
  // SIMPLIFIED (3-layer, Echo-exact): previously 5 stacked layers —
  // solid base, static blur, a breathe-driven radial gradient tint, a
  // breathe-driven 3-orb CustomPaint glow layer, and a static vignette.
  // The radial tint + orb layer were the heaviest things on this whole
  // screen (rebuilding every breathe frame, forever, while the full
  // player is open) and, next to the actual artwork motion, added very
  // little the eye reads as "premium" — Echo's own player gets that
  // entirely from the blurred art + a single palette-tinted gradient.
  // Cut down to exactly that: base → Ken Burns blurred artwork → one
  // static gradient that both tints with the palette color AND handles
  // the vignette in a single paint. Nothing left in this method needs
  // breatheCtrl at all anymore — the only remaining motion is the Ken
  // Burns drift already living inside `staticBlur` itself.
  Widget _buildDark(Color bg1, Color bg2, Color bg3, Color bg4, Widget staticBlur) {
    final dynamicColor = AudioPrefs.dynamicPlayerColorNotifier.value;
    final bgStyle = AudioPrefs.effectivePlayerBgStyle;
    if (!dynamicColor) {
      bg1 = Color.lerp(AurumTheme.gold, Colors.black, 0.35)!;
      bg2 = Color.lerp(AurumTheme.goldDark, Colors.black, 0.58)!;
      bg3 = Color.lerp(AurumTheme.goldDark, Colors.black, 0.78)!;
      bg4 = Color.lerp(AurumTheme.goldLight, Colors.black, 0.42)!;
    }

    if (bgStyle == 'Solid') {
      return ColoredBox(color: Color.lerp(bg1, Colors.black, 0.35)!);
    }

    return Stack(fit: StackFit.expand, children: [
      // L0: Pure black base.
      const ColoredBox(color: Color(0xFF000000)),

      // L1: Ken Burns blurred artwork — the whole "premium" effect.
      // Built once per song; its own slow zoom/pan lives inside this
      // widget and needs no external controller here.
      staticBlur,

      // L2: One static layer doing both jobs Echo's gradient_track +
      // tint does — palette color radiating from the upper-left, and a
      // dark vignette top/bottom so controls and text stay readable.
      // Fully static (no AnimatedBuilder): a RadialGradient can't be
      // cheaply layered with a top/bottom LinearGradient in one
      // BoxDecoration, so this uses a tiny CustomPaint that draws both
      // in a single paint call, once, ever (shouldRepaint: false).
      if (bgStyle != 'Gradient')
        RepaintBoundary(
          child: CustomPaint(
            painter: _StaticTintVignettePainter(
              tint1: bg1.withAlpha(130),
              tint2: bg2.withAlpha(90),
            ),
            size: Size.infinite,
          ),
        )
      else
        const RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xA0000000),
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xD2000000),
                ],
                stops: [0.0, 0.18, 0.60, 1.0],
              ),
            ),
          ),
        ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _StaticBlurArtwork — built once per song (keyed on song id + artwork url)
// instead of every breathe-controller tick. This single change removes the
// majority of the full player's idle GPU cost, since this was previously
// rebuilding 60x/sec forever.
//
// BUGFIX (perf): sigma was 40-42, which on a 1.55x-scaled full-screen layer
// is one of the single most expensive paint ops Flutter can do on a mobile
// GPU — this alone was responsible for the visible stall on full-player
// open and the stutter on every song change/skip (the layer is rebuilt
// once per song, so every song change re-paid this cost). Dropped to
// 20/22σ: after the 1.55x scale-up and the existing 220px capped decode
// (see AurumArtwork._cacheSize), detail is already destroyed well before
// 40σ — visually the two are effectively indistinguishable, but 20-22σ is
// roughly a quarter of the GPU cost.
//
// Also: AurumArtwork's CachedNetworkImage normally fades in over 280ms —
// fine for artwork you look at directly, but wasteful here since this
// layer sits under Opacity(~0.88) and a blur filter, both of which hide
// any pop-in anyway. Every frame of that 280ms fade was forcing Flutter to
// re-composite the blur, on top of the blur's own per-song cost. Passing
// fadeIn: false skips that animation for this specific instance only.
//
// KEN BURNS MOTION: the blur itself is still built exactly once per song
// (BlurredArtworkCore below) — that part never re-renders. What's new is
// a cheap outer Transform (scale + pan) driven by breatheCtrl, the same
// 18s controller that already drives the ambient orbs. A GPU transform on
// an already-composited layer costs nothing like re-running the blur
// filter would, so this reads as a slow Echo-style Ken Burns drift on the
// background artwork for ~0 extra frame cost.
// ─────────────────────────────────────────────────────────────────────────────
class _StaticBlurArtwork extends StatelessWidget {
  final Song song;
  final bool isLight;
  final bool isDragging;

  const _StaticBlurArtwork({
    super.key,
    required this.song,
    required this.isLight,
    this.isDragging = false,
  });

  @override
  Widget build(BuildContext context) {
    // NOTE: previously short-circuited to SizedBox.shrink() here when
    // song.artworkUrl was empty, which skipped this whole layer for local
    // songs with no embedded artwork — see the matching FIX comment in
    // _BlurredArtworkCore below for why that caused a flat white/cream
    // "layer" during swipe-to-dismiss. _BlurredArtworkCore now handles
    // the empty-artwork case itself (gradient placeholder instead of
    // nothing), so it's safe to always build it here too.
    // SPEED FIX (Spotify-level instant open): Ken Burns pan/zoom drift was
    // a perpetually-running Transform on top of the heaviest layer on this
    // whole screen (22σ blur + 1.55x scaled full-bleed artwork), ticking
    // every frame for as long as the full player stayed open — pure
    // ongoing GPU cost with no bearing on how fast the screen opens, but
    // it does compete for frame budget with the open transition itself on
    // lower-end devices, which is exactly what reads as "atakta hai" right
    // when the player is trying to slide up. Spotify/YT Music/Apple Music
    // don't animate their blurred backdrop at all — it's static. Removing
    // this entirely (not just freezing it) means _BlurredArtworkCore is
    // now truly built ONCE per song with zero per-frame cost forever
    // after, matching that reference behavior.
    return _BlurredArtworkCore(song: song, isLight: isLight);
  }
}

// The actual blur render — split out from _StaticBlurArtwork so the Ken
// Burns Transform wrapper above can sit outside it without ever forcing
// this (expensive) subtree to rebuild. This widget itself is still only
// built once per song via the ValueKey at the call site.
class _BlurredArtworkCore extends StatelessWidget {
  final Song song;
  final bool isLight;

  const _BlurredArtworkCore({required this.song, required this.isLight});

  @override
  Widget build(BuildContext context) {
    // FIX ("white/flat layer on swipe-down for local songs with no
    // embedded artwork"): this used to return SizedBox.shrink() whenever
    // song.artworkUrl was empty — which is common for local/offline files
    // scanned by local_music_service.dart when the MP3 has no embedded
    // art and MediaStore has nothing cached for it either (see e.g. "Gora
    // Rang", "Jodaa" in the library — generic note icon, no artwork).
    // Skipping this layer entirely left only _BgLayer's flat L0 base
    // (Color(0xFFE8E2D6) in light mode) plus a near-invisible low-alpha
    // vignette on screen — a plain, colorless sheet that reads as a
    // "white layer" sliding down during the swipe-to-dismiss drag, since
    // _DragTransform fades/translates this whole background along with
    // everything else and there was nothing but flat color underneath it
    // to fade. A soft static gradient placeholder here (no image decode
    // needed, so cost is negligible) keeps this layer visually present
    // for every song, artwork or not, so the drag always fades something
    // with actual depth instead of a flat wash.
    if (song.artworkUrl.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? [const Color(0xFFDCD3C0), const Color(0xFFC9BCA0)]
                : [const Color(0xFF241F38), const Color(0xFF120F24)],
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: ClipRect(
        // FIX ("swipe down karte waqt blur background bahut upar tak
        // chala jaata hai / edges ke bahar dikhta hai"): this blur layer
        // scales its artwork to 1.55x (deliberate overscan so the blur's
        // own soft edge never shows a hard boundary) but was never
        // clipped to its own bounds here — it only relied on the far
        // outer _DragTransform's ClipRect, which wraps the ENTIRE scaled+
        // translated Scaffold during a dismiss drag. That outer clip is
        // correct for the screen edges in the static, non-dragging case,
        // but once _DragTransform's own Transform.scale (anchored at
        // Alignment.center, shrinking the whole Scaffold slightly as it
        // slides down) is combined with a translate, the composited
        // stacking order can let this layer's own unclipped 1.55x
        // overscan visibly poke out past the top/edges before the outer
        // clip catches it — exactly the "blur upar tak chala jaata hai"
        // artifact. Clipping the overscan to its own bounds right here,
        // at the source, means it can never leak regardless of whatever
        // transform is applied to it further up the tree — the outer
        // ClipRect in _DragTransform is now a second, redundant safety
        // net instead of the only thing preventing this.
        child: Opacity(
          opacity: isLight ? 0.90 : 0.88,
          child: Transform.scale(
            scale: 1.55,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: isLight ? 20 : 22,
                sigmaY: isLight ? 20 : 22,
                tileMode: TileMode.clamp,
              ),
              child: AurumArtwork(
                url: song.artworkUrl,
                size: double.infinity,
                borderRadius: 0,
                isBlurredBackground: true,
              // FIX (black-flash on song change) — this was `fadeIn: false`.
              // The background blur layer is keyed by
              // ValueKey('${song.id}_${song.artworkUrl}') at the _BgLayer
              // call site, which makes Flutter discard and rebuild this
              // entire widget the instant the song changes — the previous
              // blurred image disappears immediately, not gradually. With
              // fadeIn off, CachedNetworkImage's fadeInDuration was zero,
              // so there was no crossfade to cover that gap: for however
              // long the new artwork took to decode (worse on a cold
              // cache/slow network), the screen showed nothing but this
              // layer's ColoredBox base underneath — which in dark mode
              // is a near-black color, reading as a hard black flash
              // exactly at the moment the title/artwork-disc had already
              // switched to the new song. Enabling fadeIn restores
              // CachedNetworkImage's built-in 280ms fade-in / 120ms
              // fade-out crossfade, so the transition reads as an
              // intentional dissolve instead of a jarring cut — this is
              // the single biggest lever for the "paid app" feel here,
              // since it's the layer covering ~90% of the screen.
              fadeIn: true,
            ),
          ),
        ),
      ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _StaticTintVignettePainter — dark mode's single L2 layer.
//
// Replaces what used to be two separate breathe-driven layers (a radial
// gradient tint + a 3-orb ambient glow, both rebuilding 60x/sec forever
// while the full player was open). Paints the palette-color radial tint
// AND the top/bottom readability vignette in one paint() call, once —
// shouldRepaint only fires on an actual palette change (song change),
// never on a timer.
// ─────────────────────────────────────────────────────────────────────────────
class _StaticTintVignettePainter extends CustomPainter {
  final Color tint1, tint2;
  const _StaticTintVignettePainter({required this.tint1, required this.tint2});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final fullRect = Rect.fromLTWH(0, 0, w, h);

    // Palette-color radial tint, upper-left — same footprint as Echo's
    // gradient_track tint, deepens the artwork colour so it stays
    // saturated even on AMOLED blacks.
    final tintRect = Rect.fromCircle(
      center: Offset(w * -0.25, h * -0.55),
      radius: w * 1.35,
    );
    final tintPaint = Paint()
      ..shader = RadialGradient(
        colors: [tint1, tint2, tint2.withAlpha(0)],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(tintRect);
    canvas.drawRect(fullRect, tintPaint);

    // Top/bottom vignette so controls and text stay readable over the
    // artwork.
    final vignettePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xA0000000),
          Colors.transparent,
          Colors.transparent,
          Color(0xD2000000),
        ],
        stops: [0.0, 0.18, 0.60, 1.0],
      ).createShader(fullRect);
    canvas.drawRect(fullRect, vignettePaint);
  }

  @override
  bool shouldRepaint(_StaticTintVignettePainter old) =>
      tint1 != old.tint1 || tint2 != old.tint2;
}

// ─────────────────────────────────────────────────────────────────────────────
// _LightVignettePainter — light mode's single L2 layer.
//
// BUGFIX (light mode felt "muddy"/generic, not premium): this used to be
// a completely flat, colorless white wash + white vignette — the same
// on every single song regardless of the artwork's own palette. That's
// what read as "not premium": nothing here ever varied, so it never felt
// tied to the actual art the way Echo's does. Now takes the song's
// extracted palette color and uses a soft warm tint of it (not plain
// white) for both the lift and the vignette, so light mode gets the same
// "this background belongs to this song" feeling dark mode already had.
// Still a single static paint call — no added per-frame cost.
// ─────────────────────────────────────────────────────────────────────────────
class _LightVignettePainter extends CustomPainter {
  final Color tint;
  const _LightVignettePainter({required this.tint});

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Warm, low-saturation lift tinted from the song's own palette color
    // instead of flat white — this is what makes it feel tied to the
    // artwork rather than a generic overlay.
    final liftColor = Color.lerp(Colors.white, tint, 0.16)!.withAlpha(26);
    canvas.drawRect(fullRect, Paint()..color = liftColor);

    final vignetteTop = Color.lerp(Colors.white, tint, 0.10)!.withAlpha(70);
    final vignetteBottom = Color.lerp(Colors.white, tint, 0.10)!.withAlpha(88);
    final vignettePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          vignetteTop,
          Colors.transparent,
          Colors.transparent,
          vignetteBottom,
        ],
        stops: const [0.0, 0.09, 0.78, 1.0],
      ).createShader(fullRect);
    canvas.drawRect(fullRect, vignettePaint);
  }

  @override
  bool shouldRepaint(_LightVignettePainter old) => tint != old.tint;
}

// ─────────────────────────────────────────────────────────────────────────────
// Marquee Text
// ─────────────────────────────────────────────────────────────────────────────
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scrollAnim;
  bool _overflowing = false;

  // Cached TextPainter + the (text, style) it was built for. Rebuilding
  // and re-laying-out a TextPainter on every animation tick (60/sec while
  // scrolling) was a real perf hit — measurable jank that made drag
  // gestures on this screen feel like they were dropping frames /
  // "auto-snapping". Now layout only runs when the text or style
  // actually changes.
  TextPainter? _tp;
  String? _tpText;
  TextStyle? _tpStyle;

  TextPainter _painterFor(String text, TextStyle style) {
    if (_tp != null && _tpText == text && _tpStyle == style) return _tp!;
    _tpText = text;
    _tpStyle = style;
    _tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    return _tp!;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 10500));
    _scrollAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.857, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final tp = _painterFor(widget.text, widget.style);

      final overflow = tp.width > constraints.maxWidth;

      if (overflow != _overflowing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _overflowing = overflow);
          if (overflow) {
            _ctrl.repeat();
          } else {
            _ctrl.stop();
            _ctrl.reset();
          }
        });
      }

      if (!overflow) {
        return Text(widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
      }

      return ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent
          ],
          stops: [0.0, 0.04, 0.92, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SizedBox(
          height: tp.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                final shift = -(tp.width + 40) * _scrollAnim.value;
                return Stack(children: [
                  Positioned(
                      left: shift,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                  Positioned(
                      left: shift + tp.width + 40,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                ]);
              },
            ),
          ),
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered Track Shape
// ─────────────────────────────────────────────────────────────────────────────
class _BufferedTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);

    if (secondaryOffset != null) {
      final trackRect = getPreferredRect(
          parentBox: parentBox,
          offset: offset,
          sliderTheme: sliderTheme,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete);
      final paint = Paint()
        ..color = Colors.white.withAlpha(40)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
          trackRect.left, trackRect.top, secondaryOffset.dx, trackRect.bottom);
      context.canvas.drawRRect(
          RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
          paint);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Equalizer Icon — animated bars
// ─────────────────────────────────────────────────────────────────────────────
class _EqualizerIcon extends StatefulWidget {
  const _EqualizerIcon();

  @override
  State<_EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<_EqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final v = _ctrl.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(0.3 + 0.7 * v),
              _bar(0.8 - 0.6 * v),
              _bar(0.5 + 0.5 * v),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double f) => Container(
        width: 3.5,
        height: 18 * f,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Icon Button
// ─────────────────────────────────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  // FIX: color used to be optional with a Theme.of(context).brightness
  // fallback (app theme mode) — but every caller of this shared button
  // sits directly over the artwork/background and needs an artwork-
  // luma-derived color, not a theme-derived one. Making it required
  // forces every call site to make that choice explicitly instead of
  // silently getting the wrong contrast source.
  final Color color;
  final String? semanticLabel;

  const _IconBtn({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: AurumPressable(
        scaleAmount: 0.85,
        haptic: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control Button
// ─────────────────────────────────────────────────────────────────────────────
class _CtrlBtn extends StatefulWidget {
  final IconData icon;
  final double size;
  final bool active;
  final Color? color;
  // FIX ("buttons illegible depending on artwork brightness"): this
  // widget used to compute its own inactive-state fallback from
  // Theme.of(context).brightness (app light/dark MODE) whenever a caller
  // didn't pass `color` — but app theme and artwork color are unrelated,
  // so a dark-mode user with bright artwork (or the reverse) got the
  // wrong contrast. Every current call site now passes an explicit,
  // artwork-luminance-derived inactiveColor (see _Controls above), so
  // this is required rather than optional — there's no theme-based
  // fallback left to silently do the wrong thing.
  final Color inactiveColor;
  final String? semanticLabel;
  final VoidCallback onTap;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    required this.inactiveColor,
    this.size = 24,
    this.active = false,
    this.color,
    this.semanticLabel,
  });

  @override
  State<_CtrlBtn> createState() => _CtrlBtnState();
}

// PREMIUM POLISH PASS 2 ("shuffle/repeat feel dead — make them feel
// premium and clickable"): pass 1 (see the animation notes preserved
// below) handled color/icon transitions but the buttons still had no felt
// depth — flat icon in empty space, a barely-visible 4px dot the only
// active signal, and a generic 0.85 press-scale shared with every other
// control on the screen (skip/prev/next included), so shuffle/repeat
// never read as distinct, "considered" controls.
//
// This pass is scoped ONLY to shuffle/repeat: skip/prev/next and the play
// button are untouched, still using the plain _CtrlBtn/_PremiumPlayButton
// paths elsewhere on screen — this widget is StatefulWidget now (needed
// for the press-pulse AnimationController below) but every call site
// still constructs it identically (`_CtrlBtn(...)`), so nothing else in
// the file needed to change.
//
// Three additions, all deliberately restrained (no glow, no shadow, no
// color outside the existing gold/inactive palette already used
// everywhere else on this screen — an isolated flourish here would read
// as inconsistent rather than premium):
//  1. A soft circular backdrop fades in behind the icon when active
//     (gold at ~10% opacity) — gives the toggle actual depth/weight
//     instead of just a color change, same visual language as how
//     "selected" chips read elsewhere in the app.
//  2. The active indicator changed from a 4px dot to a short underline
//     bar beneath the icon — reads as a more confident, considered
//     status mark (closer to how Apple Music signals active
//     shuffle/repeat) rather than a barely-visible pixel.
//  3. A brief press-pulse: the backdrop scales up and its opacity ticks
//     slightly on tap-down, settling back on release — gives the tap
//     itself a felt moment rather than only the eventual state change
//     being visible. Purely additive to the existing AurumPressable
//     scale — that press-scale on the whole button is untouched.
class _CtrlBtnState extends State<_CtrlBtn> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _onPressDown(_) => _pulseCtrl.forward();
  void _onPressEnd(_) => _pulseCtrl.reverse();
  void _onPressCancel() => _pulseCtrl.reverse();

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? (widget.active ? AurumTheme.gold : widget.inactiveColor);

    // Same restrained language as before (no pill, no glow, no shadow —
    // that restraint is what reads as premium rather than gamified) but
    // refines the motion quality:
    //  - The icon's color now animates (AnimatedDefaultTextStyle-style
    //    tween via TweenAnimationBuilder) instead of snapping instantly
    //    between muted/gold on toggle — a deliberate, considered
    //    transition rather than a hard cut.
    //  - Icon swap crossfade slowed very slightly (180ms -> 200ms) and
    //    paired with a tiny scale so it reads as a soft transition rather
    //    than a flicker.
    // Only shuffle/repeat pass `active`; skip/prev/next never do, so all
    // of this only affects the two toggle buttons.
    final showActiveMark = widget.color == null;

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: AurumPressable(
        scaleAmount: 0.85,
        haptic: false, // callers already fire their own haptic per action
        onTap: widget.onTap,
        child: Listener(
          onPointerDown: showActiveMark ? _onPressDown : null,
          onPointerUp: showActiveMark ? _onPressEnd : null,
          onPointerCancel: showActiveMark ? (_) => _onPressCancel() : null,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (showActiveMark)
                        AnimatedBuilder(
                          animation: _pulseCtrl,
                          builder: (_, __) {
                            final pulse = _pulseCtrl.value;
                            // Backdrop is visible when active OR mid-press
                            // (so even a tap that ends up toggling OFF
                            // still gets a felt moment on press-down),
                            // fading smoothly between the two.
                            final baseOpacity = widget.active ? 0.12 : 0.0;
                            final opacity =
                                (baseOpacity + pulse * 0.10).clamp(0.0, 0.22);
                            final scale = 1.0 + pulse * 0.08;
                            if (opacity <= 0.001) return const SizedBox.shrink();
                            return Transform.scale(
                              scale: scale,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AurumTheme.gold.withOpacity(opacity),
                                ),
                              ),
                            );
                          },
                        ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.88, end: 1.0).animate(anim),
                            child: child,
                          ),
                        ),
                        // Keyed on the icon shape only (not color) — a
                        // pure color change (shuffle/repeat toggling
                        // active while the icon shape stays the same)
                        // animates smoothly via the TweenAnimationBuilder
                        // below instead of retriggering the fade/scale
                        // switch, which is reserved for genuine icon
                        // shape changes (repeat -> repeat-one).
                        child: TweenAnimationBuilder<Color?>(
                          key: ValueKey(widget.icon),
                          tween: ColorTween(end: c),
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          builder: (_, animatedColor, __) => Icon(
                            widget.icon,
                            size: widget.size,
                            color: animatedColor ?? c,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (showActiveMark) ...[
                  const SizedBox(height: 2),
                  // Short underline bar replaces the old 4px dot — a
                  // more confident, deliberate status mark. Width
                  // animates in from a sliver rather than just fading,
                  // so it reads as "drawing itself" on activation.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    width: widget.active ? 14 : 3,
                    height: 2.5,
                    decoration: BoxDecoration(
                      color: AurumTheme.gold
                          .withOpacity(widget.active ? 1.0 : 0.0),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
