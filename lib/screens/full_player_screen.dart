import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../main.dart' show aurumRouteObserver;
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui show Image;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
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
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/audio_prefs.dart';
import '../services/waveform_service.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/aurum_play_pause_icon.dart';
import '../widgets/premium_gate.dart';
import 'library_screen.dart' show showAddToPlaylistSheet;
import '../widgets/audio_output_sheet.dart';
import '../widgets/cast_button.dart';
import 'settings_player_screen.dart' show SleepTimerService, SleepTimerSheet, EqualizerScreen;
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

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
  // EXACT MATCH (Echo Nightly's tap-anywhere-to-reveal-fullscreen-blur):
  // Echo's PlayerFragment toggles a single playerBgVisible flag on tap —
  // true fades OUT the foreground (fgContainer + playerMoreContainer)
  // and hides system UI, leaving only the already-rendered bg_image
  // (its blurred Ken Burns artwork) visible full-screen; tapping again
  // reverses it. No new blur is ever created — Echo already has the
  // blurred layer sitting behind the UI at all times, it's just always
  // covered. Reproduced identically here: this flag fades out
  // SafeArea(_buildBody(...)) — the foreground content Column (top bar,
  // artwork, title, seekbar, controls) — over the already-present
  // _BgLayer/_StaticBlurArtwork, which needs zero changes and keeps
  // running its Ken Burns drift underneath exactly as it already does
  // when covered. Cheapest possible implementation for a low-end
  // device: one bool, one AnimatedOpacity, nothing re-rendered.
  bool _bgFullscreenRevealed = false;
  // Raw pointer-down position for the Listener-based tap detector above
  // — see the BUGFIX comment at that call site for why this is a
  // Listener instead of a GestureDetector.
  Offset? _bgTapDownPos;

  void _toggleBgFullscreenReveal() {
    // EXACT MATCH (Echo's own guard in PlayerFragment.onClick: "if
    // (binding.bgImage.drawable == null && !hasVideo) return"): don't
    // reveal fullscreen if there's nothing back there to actually show
    // — with the blur setting off, or no artwork loaded yet, this would
    // just fade the UI away onto a flat black/gradient base, which
    // reads as broken rather than a deliberate reveal.
    if (!AudioPrefs.showBlurredBgNotifier.value) return;
    AurumHaptics.selection();
    setState(() => _bgFullscreenRevealed = !_bgFullscreenRevealed);
  }
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
      // The immersive-lyrics restore itself now happens earlier, in
      // didChangeDependencies (before first paint, so there's no
      // thumbnail-then-lyrics flash on reopen — see the FIX comment
      // there). One thing genuinely can't move that early though:
      // _kenBurnsKey's target widget hasn't built yet at
      // didChangeDependencies time, so calling .pause() there would
      // hit a null currentState and silently do nothing. By this
      // postFrameCallback the first frame (already showing lyrics
      // settled, per the restore above) has built, so the Ken Burns
      // background artwork drift can now actually be paused behind it —
      // matching exactly what a fresh _openImmersiveLyrics() call does.
      if (_immersiveLyricsOpen) {
        _pauseAmbientAnims();
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
    _immersiveCtrl.dispose();
    _springBackCtrl.dispose();
    _dragYNotifier.dispose();
    super.dispose();
  }

  /// Smoothly animates _dragY back to 0 after a cancelled drag, instead
  /// of snapping instantly. Uses an easeOutBack curve for a subtle
  /// "settle" feel rather than a linear slide.
  // FIX ("swipe down/up ekdam makkhan jaisa, Echo Nightly ki
  // BottomSheetBehavior jaisa settle honा chahiye"): this used to always
  // animate back over a fixed 420ms regardless of how the finger was
  // moving at release — a slow, deliberate half-drag and a fast flick-back
  // both took exactly 420ms to settle, which reads as canned/robotic
  // rather than physical. Android's BottomSheetBehavior (what Echo
  // Nightly's panel actually rides on) settles with duration scaled to
  // the release velocity — a fast flick snaps back quickly, a slow
  // release eases back unhurried. Scaling duration by how far AND how
  // fast the drag was releasing reproduces that same felt-weight without
  // adding any physics engine or extra dependency — just a duration
  // computed from the same velocity Flutter's gesture callback already
  // hands us for free.
  void _springBackDrag([double velocity = 0]) {
    final start = _dragY;
    if (start == 0) return;
    // Distance-only fallback duration (used when no velocity is known,
    // e.g. onVerticalDragCancel), clamped to a sensible premium range.
    var durationMs = (start.abs() / 2).clamp(180, 420).round();
    // A fast release should settle noticeably quicker than a slow one —
    // this is the actual "makkhan" feel: it responds to how you let go,
    // not a single fixed timing for every release.
    final speed = velocity.abs();
    if (speed > 0) {
      final velocityMs = (start.abs() / speed * 1000).clamp(120, 420);
      durationMs = velocityMs.round();
    }
    _springBackCtrl.duration = Duration(milliseconds: durationMs);
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
      // Both spring paths (_springBackDrag and _completeDismissDrag)
      // share this one controller and set their own .duration on every
      // call before forward()'ing, so restoring it here isn't load-
      // bearing for correctness — kept only so the controller's resting
      // value matches its actual declared default (320ms, see initState)
      // rather than a stale value from whichever call ran last.
      _springBackCtrl.duration = const Duration(milliseconds: 320);
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
      // FIX ("full player swipe-down se close karo, dubara kholo to
      // lyrics hat jaata hai" — flash-on-reopen follow-up): the earlier
      // version of this restore lived inside build()'s
      // addPostFrameCallback, which runs AFTER the first frame already
      // painted with the fresh-State defaults (_immersiveLyricsOpen =
      // false, thumbnail showing) — so on reopen there was a real,
      // visible one-frame flash of the thumbnail before it snapped over
      // to lyrics a beat later. didChangeDependencies runs before that
      // first frame is ever painted (same reasoning as the palette seed
      // right below), so restoring here means the very first frame
      // already shows lyrics settled in place — no flash, no snap,
      // genuinely seamless on reopen.
      if (context.read<PlayerProvider>().immersiveLyricsWasOpen) {
        _immersiveLyricsOpen = true;
        _immersiveCtrl.value = 1.0;
      }
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
          // FIX ("light mode mein artist name kitna awkward/washed-out lag
          // raha hai, especially white/cream cover arts pe" — root cause):
          // this seed path (runs first, on initial mount, straight from
          // ArtworkPaletteCache) used its OWN older light-mode formula —
          // lerp toward Colors.white by a small amount (0.10-0.20) — which
          // is a completely different design from the "REWORK" formula a
          // few dozen lines below (used once the async PaletteGenerator
          // recompute lands) that deliberately keeps light mode's
          // background dark-leaning (same dark-mode-tuned values, only a
          // small uniform 0.16 white lift at the very end). For light/
          // pale album art (dominant swatch already close to white), the
          // old small-lift formula left _currentBg2 sufficiently LIGHT
          // (luma >= 0.5) that the title/artist block above (which reads
          // bgLuma directly off _currentBg2 to decide text color) treated
          // the background as light and drew the artist line in
          // lightTextSecondary — a muted grey — instead of white. Against
          // this seed path's actually-light background that grey read as
          // barely legible. The REWORK formula's background is
          // deliberately kept dark regardless of app theme, so it always
          // resolves bgIsLight to false and draws white artist text
          // instead — the two formulas disagreeing is what made the seed
          // frame (and any song whose PaletteGenerator recompute is slow/
          // cached-miss) look different from the steady state.
          // Matching the REWORK formula exactly here — dark-mode-tuned
          // values first, then the same small 0.16 lift toward white in
          // light theme — means the seeded background always agrees with
          // the recomputed one, so bgIsLight (and therefore artist-text
          // color) is consistent from the very first frame.
          const lightLift = 0.16;
          final seeded1 = isLight
              ? ensureContrastSafe(Color.lerp(
                  ensureContrastSafe(Color.lerp(c1, Colors.black, 0.22)!, isLight: false),
                  Colors.white, lightLift)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c1, Colors.black, 0.22)!, isLight: false);
          final seeded2 = isLight
              ? ensureContrastSafe(Color.lerp(
                  ensureContrastSafe(Color.lerp(c2, Colors.black, 0.48)!, isLight: false),
                  Colors.white, lightLift)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c2, Colors.black, 0.48)!, isLight: false);
          final seeded3 = isLight
              ? ensureContrastSafe(Color.lerp(
                  ensureContrastSafe(Color.lerp(c3, Colors.black, 0.70)!, isLight: false),
                  Colors.white, lightLift)!, isLight: true)
              : ensureContrastSafe(Color.lerp(c3, Colors.black, 0.70)!, isLight: false);
          final seeded4 = isLight
              ? ensureContrastSafe(Color.lerp(
                  ensureContrastSafe(Color.lerp(c4, Colors.black, 0.30)!, isLight: false),
                  Colors.white, lightLift)!, isLight: true)
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

  // PERF FIX (godmode recheck): existed solely to stop/restart the
  // now-removed _breatheCtrl loop (see that field's own FIX comment
  // above for the full history) — nothing else in this screen was ever
  // driven by them, UNTIL the Ken Burns pan/zoom on the blurred
  // background was reinstated (see _StaticBlurArtworkState) to exactly
  // match Echo Nightly's own KenBurnsView. That controller now genuinely
  // needs pausing here too — same battery reasoning as everything else
  // in this file: no ticker should run while backgrounded or while the
  // Up Next/Lyrics/Info panel is covering this layer entirely. A
  // GlobalKey lets this screen reach into that State without threading a
  // callback down through every intermediate widget.
  final GlobalKey<_StaticBlurArtworkState> _kenBurnsKey = GlobalKey();

  void _pauseAmbientAnims() {
    _kenBurnsKey.currentState?.pause();
  }

  void _resumeAmbientAnims() {
    _kenBurnsKey.currentState?.resume();
  }

  // Immersive Lyrics overlay — full-screen thumbnail↔lyrics morph, driven
  // entirely in-place (no pushed route) so it can reuse _currentBg1..4,
  // the live song, and _pauseAmbientAnims/_resumeAmbientAnims directly
  // with zero prop plumbing, exactly like _openPanel reuses them for the
  // Up Next/Lyrics/Info sheet above.
  bool _immersiveLyricsOpen = false;
  // 3.8s open (glow builds → holds/breathes longer → releases lyrics,
  // Gemini-paced — increased again from 3.2s so the aura has real
  // presence instead of rushing through), faster 420ms close
  // (dismissal should feel snappy, not slow like the reveal).
  late final AnimationController _immersiveCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5200),
    reverseDuration: const Duration(milliseconds: 420),
  );
  double _immersiveDragY = 0.0;
  bool _immersiveDragging = false;

  void _openImmersiveLyrics() {
    // FIX: this used to hard-return if lyrics were already open, so the
    // same trigger button did nothing on a second tap — closing only
    // worked via the overlay's own tap-anywhere/swipe/back handlers.
    // Now the trigger button itself toggles: tap again while open closes
    // it, matching how a play/pause-style toggle button should behave.
    if (_immersiveLyricsOpen) {
      _closeImmersiveLyrics();
      return;
    }
    AurumHaptics.medium();
    setState(() => _immersiveLyricsOpen = true);
    // Persisted on PlayerProvider (survives this screen's own route
    // pop/push) so a swipe-down-dismiss-then-reopen restores lyrics
    // instead of resetting — see the didChangeDependencies restore
    // above (near _didSeedInitialPalette).
    context.read<PlayerProvider>().immersiveLyricsWasOpen = true;
    _pauseAmbientAnims();
    _immersiveCtrl.forward(from: 0.0);
  }

  void _closeImmersiveLyrics() {
    if (!_immersiveLyricsOpen) return;
    AurumHaptics.light();
    context.read<PlayerProvider>().immersiveLyricsWasOpen = false;
    _immersiveDragY = 0.0;
    _immersiveCtrl.reverse(from: _immersiveCtrl.value).whenComplete(() {
      if (!mounted) return;
      setState(() => _immersiveLyricsOpen = false);
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _resumeAmbientAnims();
      }
    });
  }

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
      // REWORK ("light mode ko ekdam dark mode jaisa hi rakho, bas
      // thoda sa glow/lift do — aankh pe zor na pade"): every previous
      // attempt here built light mode as its OWN separate formula
      // (different swatch, different white-lift per channel) — that's
      // exactly why it kept drifting out of sync with dark mode and
      // needed a fresh patch every time a new mismatch showed up (milky
      // solid fill, hazy gradient corner, etc.). Root cause was
      // structural: two independently-tuned formulas for the same
      // artwork can never guarantee to look like "the same design,
      // slightly lighter" — they're just two different designs.
      // Now light mode starts from the EXACT SAME dark-mode-tuned
      // values (same c1..c4 mapping, same black-lerp amounts) and only
      // then lifts the whole result a small, uniform amount toward
      // white — same lift fraction on every channel, so whatever
      // relationship/contrast dark mode has between bg1..bg4 is
      // preserved exactly, just gently brightened. This can't reproduce
      // any of the old per-channel bugs (no channel is ever alone at a
      // different dilution than its neighbors) and it can never look
      // like a different app in light mode — it's the same background,
      // softened.
      const lightLift = 0.16; // small — enough to ease eye strain, not wash out
      final darkBg1 = ensureContrastSafe(Color.lerp(c1, Colors.black, 0.22)!, isLight: false);
      final darkBg2 = ensureContrastSafe(Color.lerp(c2, Colors.black, 0.48)!, isLight: false);
      final darkBg3 = ensureContrastSafe(Color.lerp(c3, Colors.black, 0.70)!, isLight: false);
      final darkBg4 = ensureContrastSafe(Color.lerp(c4, Colors.black, 0.30)!, isLight: false);
      _targetBg1 = ensureContrastSafe(Color.lerp(darkBg1, Colors.white, lightLift)!, isLight: true);
      _targetBg2 = ensureContrastSafe(Color.lerp(darkBg2, Colors.white, lightLift)!, isLight: true);
      _targetBg3 = ensureContrastSafe(Color.lerp(darkBg3, Colors.white, lightLift)!, isLight: true);
      _targetBg4 = ensureContrastSafe(Color.lerp(darkBg4, Colors.white, lightLift)!, isLight: true);
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
      // STABILITY FIX ("Up Next panel ko fast/bade upward swipe se kholne
      // par kabhi-kabhi 'chhut jaata hai', jagah pe fit nahi hota — jaisa
      // detached/glitchy ho gaya"): showModalBottomSheet's own built-in
      // drag-to-dismiss was left at its default (enableDrag: true), which
      // runs Flutter's OWN internal AnimationController driving this
      // sheet's real vertical position — completely independent of and in
      // parallel with _PremiumContentPanelState's own complete custom
      // drag system (_dragYNotifier, _springBackCtrl, _exitCtrl,
      // Transform.translate). Two separate systems both trying to own the
      // same sheet's position is exactly the class of bug that produces
      // "position doesn't match what was expected" — a fast/large
      // upward-then-release gesture could leave Flutter's internal sheet
      // animation and this panel's own custom transform disagreeing about
      // where the sheet actually is, reading as the panel detaching from
      // or not settling into its correct position. Since every drag/
      // dismiss interaction the panel needs (handle-drag, list-swipe-
      // down-to-dismiss, spring-back, animated exit) is already fully and
      // deliberately implemented inside _PremiumContentPanelState itself,
      // there is no remaining reason for the framework's own competing
      // drag system to be active at all — disabling it here removes the
      // second, conflicting source of truth entirely.
      enableDrag: false,
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
    // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
    // so the scrim always has an explicit barrierColor.
    showAurumModalBottomSheet(
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
                  _springBackDrag(velocity);
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
                // No velocity available on a cancel — falls back to the
                // distance-only duration inside _springBackDrag.
                _springBackDrag();
              },
              child: _DragTransform(
                dragYListenable: _dragYNotifier,
                child: PopScope(
                  // FIX ("back karne pe bhi hat jata hai — ye bhi band
                  // karo, jab tak button dubara click na ho tab tak
                  // hamesha khula rahe"): system/gesture back button used
                  // to close the immersive lyrics overlay (same
                  // "innermost thing closes first" pattern as the Up
                  // Next/Lyrics/Info sheet). Per the updated spec, the
                  // overlay must ONLY close via its own toggle button —
                  // not swipe, not tap, and now not back either. canPop
                  // stays true even while the overlay is open (so back
                  // still closes the whole PLAYER as normal, one level
                  // up), but back no longer touches the immersive overlay
                  // itself — onPopInvokedWithResult here is now a no-op
                  // for the overlay case.
                  canPop: true,
                  onPopInvokedWithResult: (didPop, _) {},
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
                              kenBurnsKey: _kenBurnsKey,
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
                          // EXACT MATCH (Echo Nightly tap-to-reveal): a
                          // single AnimatedOpacity around the entire
                          // foreground Column — cheapest possible toggle
                          // for a low-end device, since nothing new is
                          // ever built or re-rendered; this only fades
                          // opacity on an already-composited subtree.
                          // IgnorePointer while hidden lets the tap that
                          // triggers this (below) and the Ken Burns
                          // background underneath receive gestures
                          // instead of this now-invisible layer eating
                          // them.
                          AnimatedOpacity(
                            opacity: _bgFullscreenRevealed ? 0.0 : 1.0,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            child: IgnorePointer(
                              ignoring: _bgFullscreenRevealed,
                              child: SafeArea(
                                child: RepaintBoundary(
                                  child: _buildBody(context, player, song),
                                ),
                              ),
                            ),
                          ),
                          // Tap-anywhere-to-reveal-fullscreen-blur. Placed
                          // after (so, visually above) the foreground
                          // Column in this Stack — but a bare Listener
                          // never consumes/blocks hit-testing the way a
                          // GestureDetector can, so every button inside
                          // _buildBody still receives its own taps
                          // completely normally; this only ever silently
                          // observes the same pointer events alongside
                          // them. Only active when nothing else is
                          // already claiming taps/drags on this screen
                          // (immersive lyrics overlay open) — same
                          // restraint Echo itself applies (its onClick
                          // no-ops while its own More sheet is expanded).
                          //
                          // BUGFIX ("swipe down/up ke saath tap conflict
                          // ho sakta hai, kabhi stuck reh sakta hai"): this
                          // was a GestureDetector(onTap: ...), gated on
                          // `!_isDragging` — but _isDragging only flips
                          // true inside the OUTER drag detector's
                          // onVerticalDragStart callback, one setState/
                          // frame after the finger actually goes down.
                          // For that one frame, this Positioned.fill
                          // GestureDetector and the outer screen-wide drag
                          // GestureDetector are both live at once, and
                          // both enter the SAME Flutter gesture arena for
                          // that pointer — a tap recognizer and a
                          // vertical-drag recognizer competing on literally
                          // the same touch, which is exactly the class of
                          // race that produces "gesture won by the wrong
                          // widget" or "arena never resolved cleanly"
                          // stuck-state bugs. A plain Listener (raw
                          // pointer callbacks) never enters the gesture
                          // arena at all — no recognizer, nothing to
                          // compete with the outer drag detector, so
                          // there's no window for that race to exist in
                          // the first place. Tap is detected manually:
                          // record where the pointer went down, and on
                          // pointer-up, fire only if it lifted close to
                          // where it went down (a real tap) rather than
                          // having traveled (which the outer detector will
                          // already be handling as a drag by then).
                          Positioned.fill(
                            child: Listener(
                              behavior: _bgFullscreenRevealed
                                  ? HitTestBehavior.opaque
                                  : HitTestBehavior.translucent,
                              onPointerDown: (e) => _bgTapDownPos = e.position,
                              onPointerCancel: (_) => _bgTapDownPos = null,
                              onPointerUp: (e) {
                                final start = _bgTapDownPos;
                                _bgTapDownPos = null;
                                if (start == null) return;
                                if (_immersiveLyricsOpen ||
                                    _immersiveCtrl.value > 0) {
                                  return;
                                }
                                // Same slop tolerance Flutter's own tap
                                // recognizer uses internally (kTouchSlop
                                // is 18 logical px) — anything within that
                                // is a tap, anything beyond is a drag the
                                // outer detector is already tracking.
                                if ((e.position - start).distance <= 18) {
                                  _toggleBgFullscreenReveal();
                                }
                              },
                            ),
                          ),
                          // Full-screen edge glow — the Gemini-style aura
                          // covers the WHOLE player (top bar, title, seek
                          // bar, controls included), while the actual
                          // thumbnail↔lyrics swap stays confined to the
                          // artwork box inside _buildBody/_Artwork above.
                          // Kept mounted only while opening/open/closing,
                          // same lifecycle reasoning as the content swap.
                          if (_immersiveLyricsOpen || _immersiveCtrl.value > 0)
                            Positioned.fill(
                              // RepaintBoundary here — this layer repaints
                              // every animation tick (breathing glow, ~60
                              // times/sec) for the full 3.8s open/420ms
                              // close duration. Without its own boundary,
                              // that continuous repaint work would get
                              // grouped with whatever's above/below it in
                              // the same layer, forcing more to redraw
                              // than necessary each frame — costly on a
                              // low-end device. Isolating it here keeps
                              // the glow's per-frame cost contained to
                              // just this layer.
                              child: RepaintBoundary(
                                child: _ImmersiveGlowLayer(controller: _immersiveCtrl),
                              ),
                            ),
                        ],
                      ),
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
            ValueListenableBuilder<LyricsViewMode>(
              valueListenable: AudioPrefs.lyricsViewModeNotifier,
              builder: (context, viewMode, _) => TopBarWithCastBanner(
                song: song,
                bgLuma: _currentBg2.computeLuminance(),
                onMore: () => _showOptions(context),
                showLyricsTrigger: viewMode == LyricsViewMode.fullscreen,
                lyricsTriggerActive: _immersiveLyricsOpen,
                onLyricsTrigger: _openImmersiveLyrics,
              ),
            ),
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
              immersiveOpen: _immersiveLyricsOpen,
              immersiveCtrl: _immersiveCtrl,
              immersiveDragY: _immersiveDragY,
              immersiveDragging: _immersiveDragging,
              onCloseImmersive: _closeImmersiveLyrics,
              onImmersiveDragStart: () =>
                  setState(() => _immersiveDragging = true),
              onImmersiveDragUpdate: (dy) =>
                  setState(() => _immersiveDragY = dy),
              onImmersiveDragEnd: (shouldClose) {
                setState(() => _immersiveDragging = false);
                if (shouldClose) {
                  _closeImmersiveLyrics();
                } else {
                  setState(() => _immersiveDragY = 0.0);
                }
              },
              bg1: _currentBg1,
              bg2: _currentBg2,
              bg3: _currentBg3,
              bg4: _currentBg4,
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
                      onLyricsTap: _openImmersiveLyrics,
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
            // opens straight to the full Lyrics tab. Hidden (not removed)
            // while the immersive full-screen lyrics overlay is open —
            // showing a redundant single-line ticker underneath the
            // full-screen lyrics view it triggers would be the exact
            // "awkward moment" the overlay is meant to avoid. Reappears
            // the instant the overlay closes, same as before.
            ValueListenableBuilder<bool>(
              valueListenable: AudioPrefs.showLyricsOnPlayerNotifier,
              builder: (context, show, _) {
                return ValueListenableBuilder<LyricsViewMode>(
                  valueListenable: AudioPrefs.lyricsViewModeNotifier,
                  builder: (context, viewMode, __) {
                    // Inline strip only exists in Inline mode — Full Screen
                    // mode routes exclusively through the trigger button,
                    // same as Spotify's two lyrics presentations never
                    // showing at once.
                    if (!show ||
                        _immersiveLyricsOpen ||
                        viewMode == LyricsViewMode.fullscreen) {
                      return const SizedBox.shrink();
                    }
                    return Row(
                      children: [
                        Expanded(
                          child: _InlineLyricsStrip(
                            hPad: hPad,
                            bgLuma: _currentBg2.computeLuminance(),
                            // FIX: this used to call _openPanel(initialTab: 1),
                            // which pushed the old bottom-sheet Lyrics tab —
                            // completely bypassing the full-screen immersive
                            // glow overlay below. This strip's own tap opens
                            // the same full-screen experience; there's no
                            // sheet-based lyrics view left in the flow now.
                            onTap: _openImmersiveLyrics,
                          ),
                        ),
                        SizedBox(width: hPad * 0.5),
                      ],
                    );
                  },
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
              // Immersive Lyrics trigger moved to the top bar (see
              // TopBarWithCastBanner above) — this row is back to just
              // the quality pills, no reserved right-side padding or
              // Positioned overlay needed anymore, so it never fights
              // for space with LOCAL/language/year pills on narrower
              // screens or longer pill sets.
              child: Center(
                child: _QualityPills(song: song, hPad: hPad, bgLuma: _currentBg2.computeLuminance()),
              ),
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
        // FIX ("swipe down/up karte waqt right side pe gap ban jaata hai,
        // dheere dheere zyada hota jaata hai" — root cause): Matrix4's
        // ..scale(dragScale, dragScale) here scales around the ORIGIN
        // (0,0) — the screen's top-left corner — not around its center.
        // Since dragScale shrinks a little below 1.0 during the swipe
        // (the "card getting smaller" feedback), scaling from the
        // top-left means the left and top edges stay pinned exactly in
        // place while the right and bottom edges pull inward toward that
        // corner — visible as a growing gap specifically on the right
        // (and, to a smaller degree, the bottom), never the left/top,
        // exactly matching the reported asymmetric gap. A uniform "shrink
        // toward the middle" effect needs the scale to happen around the
        // screen's center instead: translating by minus half the
        // screen's size, scaling, then translating back undoes the
        // origin bias so every edge moves inward by the same amount.
        final screenW = MediaQuery.of(context).size.width;
        final matrix = Matrix4.identity()
          ..translate(0.0, ty)
          ..translate(screenW / 2, screenH / 2)
          ..scale(dragScale, dragScale)
          ..translate(-screenW / 2, -screenH / 2);
        return Stack(
          children: [
            // FIX ("swipe down mein light mode mein background screen
            // white/flat ho jaata hai, sirf light mode mein" — confirmed
            // NOT a bug in the player itself: every layer inside
            // FullPlayerScreen was already correctly theme-aware and
            // hardcoded-dark where needed. The actual cause is structural:
            // pushFullPlayer uses `opaque: false` (see its own FIX comment
            // for why — needed so Home keeps rendering live frames during
            // the drag instead of a frozen one). That means as this
            // Opacity below fades the player out while dragging, Home's
            // own Scaffold — whose backgroundColor is AurumTheme.bgOf(
            // context), i.e. the real light-mode cream (0xFFF8F6F0) —
            // becomes genuinely visible behind it. In dark mode that same
            // exposed Home background is near-black, so it invisibly
            // blends with the player's own dark tones and reads as
            // intentional; in light mode the cream reads as a flat,
            // unstyled "white layer" by contrast, exactly as reported.
            // Fixing this in Home itself isn't right — Home's background
            // IS supposed to be light-cream in light mode; the flatness
            // only shows up specifically while it's exposed mid-drag
            // behind a fading player. So the fix lives here instead: a
            // dark scrim sitting OUTSIDE the player's own Opacity (so it
            // never fades with it) and OUTSIDE this Stack's translate/
            // scale (positioned before the transformed child, filling the
            // full route) — it dims whatever of Home is showing through,
            // in exactly the same "premium dismiss" way Spotify/YT Music
            // scrim their background during a card swipe-away, in every
            // theme, not just light. Opacity ramps with the same
            // dismissProgress driving the player's own fade, so it's
            // invisible at rest (0 at drag start) and fully gone again
            // the instant the drag ends (spring-back or completed pop).
            IgnorePointer(
              child: Opacity(
                opacity: (dismissProgress * 0.55).clamp(0.0, 0.55),
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            Opacity(
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
            ),
          ],
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
  // Immersive Lyrics trigger now lives here instead of squeezed into the
  // LOCAL/quality-pill row lower down — that row already has to fit a
  // variable number of pills (LOCAL badge, language, year) depending on
  // the song, so a 4th thing competing for the same 28px-tall strip was
  // the actual source of the crowded feel. The top bar has exactly one
  // icon on each side (chevron, more-menu) with a fixed-width pill
  // between them — always the same layout regardless of song metadata,
  // so adding a small third icon here can never collide with anything
  // else on any song, on any screen width. Nullable + only built when
  // non-null so a song with Immersive Lyrics off (or a song where it's
  // simply unavailable) renders the exact same two-icon bar as before —
  // no dead space, no placeholder gap.
  final bool showLyricsTrigger;
  final bool lyricsTriggerActive;
  final VoidCallback? onLyricsTrigger;
  const _TopBar({
    required this.song,
    required this.bgLuma,
    required this.onMore,
    this.showLyricsTrigger = false,
    this.lyricsTriggerActive = false,
    this.onLyricsTrigger,
  });

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
        // Small gap + the lyrics trigger, immediately after the chevron
        // — a deliberately different (smaller, circular, tinted) shape
        // from the two square-ish _IconBtns either side of it, so at a
        // glance it reads as "a distinct feature toggle", not just a
        // third nav icon.
        if (showLyricsTrigger) ...[
          const SizedBox(width: 4),
          _ImmersiveLyricsTriggerButton(
            bgLuma: bgLuma,
            isActive: lyricsTriggerActive,
            onTap: onLyricsTrigger!,
          ),
        ],
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
                song.album.isNotEmpty ? song.album : 'Astra Music', // brand name — not translated
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
  final bool showLyricsTrigger;
  final bool lyricsTriggerActive;
  final VoidCallback? onLyricsTrigger;
  const TopBarWithCastBanner({
    super.key,
    required this.song,
    required this.bgLuma,
    required this.onMore,
    this.showLyricsTrigger = false,
    this.lyricsTriggerActive = false,
    this.onLyricsTrigger,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _TopBar(
        song: song,
        bgLuma: bgLuma,
        onMore: onMore,
        showLyricsTrigger: showLyricsTrigger,
        lyricsTriggerActive: lyricsTriggerActive,
        onLyricsTrigger: onLyricsTrigger,
      ),
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
  // Immersive lyrics wiring — the overlay now renders INSIDE this
  // widget's own artwork box (see build() below) instead of covering
  // the full player via Positioned.fill from the parent Stack. That
  // was the root cause of "poori screen lyrics se bhar jaati hai" —
  // the top bar, title, seek bar, and controls were all being
  // physically covered by the overlay instead of staying visible
  // with just the artwork swapping out in place.
  final bool immersiveOpen;
  final AnimationController immersiveCtrl;
  final double immersiveDragY;
  final bool immersiveDragging;
  final VoidCallback onCloseImmersive;
  final VoidCallback onImmersiveDragStart;
  final ValueChanged<double> onImmersiveDragUpdate;
  final ValueChanged<bool> onImmersiveDragEnd;
  final Color bg1, bg2, bg3, bg4;

  const _Artwork({
    required this.song,
    required this.player,
    required this.hPad,
    required this.h,
    required this.w,
    required this.bgLuma,
    required this.artworkAnim,
    required this.immersiveOpen,
    required this.immersiveCtrl,
    required this.immersiveDragY,
    required this.immersiveDragging,
    required this.onCloseImmersive,
    required this.onImmersiveDragStart,
    required this.onImmersiveDragUpdate,
    required this.onImmersiveDragEnd,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bg4,
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
                // Confined to exactly the artwork's own box — the
                // immersive lyrics overlay lives INSIDE this SizedBox
                // (same width/height as the artwork it replaces) so it
                // can only ever occupy the artwork's footprint, never
                // the rest of the player. Top bar, title/artist, seek
                // bar, and transport controls all sit outside this
                // SizedBox in the parent Column and are structurally
                // untouched by the overlay.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ArtworkVisual(
                      dragDx: _dragDx,
                      dragging: _dragging,
                      artworkAnim: widget.artworkAnim,
                      song: widget.song,
                      player: widget.player,
                      bgIsLight: bgIsLight,
                      maxArtSize: maxArtSize,
                    ),
                    if (widget.immersiveOpen || widget.immersiveCtrl.value > 0)
                      // RepaintBoundary — same reasoning as the
                      // full-screen glow layer: this repaints every
                      // animation tick for the whole open/close
                      // duration, and sits in the same Stack as
                      // _ArtworkVisual (which has its own drag/scale
                      // transforms). Isolating it stops the two from
                      // forcing each other to repaint on every frame.
                      RepaintBoundary(
                        child: _ImmersiveLyricsOverlay(
                          controller: widget.immersiveCtrl,
                          song: widget.song,
                          bg1: widget.bg1,
                          bg2: widget.bg2,
                          bg3: widget.bg3,
                          bg4: widget.bg4,
                          dragY: widget.immersiveDragY,
                          isDragging: widget.immersiveDragging,
                          maxArtSize: maxArtSize,
                          onClose: widget.onCloseImmersive,
                          onDragStart: widget.onImmersiveDragStart,
                          onDragUpdate: widget.onImmersiveDragUpdate,
                          onDragEnd: widget.onImmersiveDragEnd,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// Original artwork's transform/decoration/shadow content, pulled out
// unchanged from _Artwork.build so it can sit as one Stack layer
// alongside the immersive overlay above, instead of being the entire
// contents of the artwork box. No behavior/visual change from before —
// straight extraction.
class _ArtworkVisual extends StatelessWidget {
  final double dragDx;
  final bool dragging;
  final Animation<double> artworkAnim;
  final Song song;
  final PlayerProvider player;
  final bool bgIsLight;
  final double maxArtSize;

  const _ArtworkVisual({
    required this.dragDx,
    required this.dragging,
    required this.artworkAnim,
    required this.song,
    required this.player,
    required this.bgIsLight,
    required this.maxArtSize,
  });

  @override
  Widget build(BuildContext context) {
    // Artwork stays pinned in place — no vertical float. Only the
    // horizontal swipe-drag offset and its scale feedback remain; the
    // idle up/down "breathing" motion has been removed so the artwork
    // reads as static/fixed, matching a premium/paid-app look.
    return Transform.translate(
      offset: Offset(dragDx * 0.3, 0),
      child: Transform.scale(
        scale: dragging ? (1.0 - (dragDx.abs() / 800).clamp(0.0, 0.08)) : 1.0,
        child: AnimatedBuilder(
          animation: artworkAnim,
          builder: (_, child) => Transform.scale(
            scale: artworkAnim.value,
            child: child,
          ),
          // SPEED FIX (Spotify-level lightweight): this Hero had no
          // matching Hero anywhere else in the app (mini_player.dart
          // and every other artwork call site use plain AurumArtwork,
          // no Hero tag) — confirmed via a full grep for tag
          // 'aurum_artwork'. An unmatched Hero never gets to play a
          // flight animation, so it was pure dead weight: every build
          // here still paid for Hero's own GlobalKey registration/
          // lookup machinery for zero visual benefit, and it's a
          // latent risk for an unexpected flight animation to trigger
          // later if any other screen ever reuses this exact tag by
          // accident. Removed entirely — the child renders exactly the
          // same without it.
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
                    // black background), but on light theme it sat on
                    // top of a pale surface as a hard, inky ring around
                    // the artwork — not the soft, low-alpha lift
                    // Spotify/Apple Music use on light backgrounds.
                    // Halved the alpha and blur/spread in light mode so
                    // it reads as a gentle elevation shadow instead of
                    // a dark outline.
                    // FIX ("charo corner ka curve toda sa off/torn lagta
                    // hai"): the first shadow used spreadRadius: 4 while
                    // painting at the SAME corner radius as the artwork
                    // beneath it — a BoxShadow's rounded corner doesn't
                    // grow with its spread the way the artwork's actual
                    // rounded-rect does, so the spread shadow's corner
                    // reads visibly tighter/sharper than the image's own
                    // corner right behind it — a jagged mismatch exactly
                    // at each of the 4 corners. Dropping spreadRadius to 0
                    // (the blur alone already gives plenty of soft lift)
                    // keeps the shadow's rounded corner geometrically
                    // identical to the artwork's, so the edge reads as one
                    // continuous clean curve instead of two slightly
                    // offset ones.
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(bgIsLight
                            ? (player.isPlaying ? 55 : 34)
                            : (player.isPlaying ? 150 : 100)),
                        blurRadius: bgIsLight
                            ? (player.isPlaying ? 40 : 24)
                            : (player.isPlaying ? 70 : 44),
                        offset: const Offset(0, 16),
                      ),
                      BoxShadow(
                        color: Colors.black.withAlpha(bgIsLight ? 24 : 70),
                        blurRadius: bgIsLight ? 12 : 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: AurumArtwork(
                      url: song.artworkUrl,
                      size: double.infinity,
                      borderRadius: radius,
                      // FIX (white flash on song tap / swipe-down
                      // dismiss / collapse — root cause): see
                      // suppressWhiteShimmer doc comment in
                      // aurum_artwork.dart. This is the hero disc
                      // artwork rendered at full screen size — the
                      // white _ShimmerPulse loading state that's
                      // harmless at tile size was covering the entire
                      // player here while local/content:// album art
                      // loaded.
                      suppressWhiteShimmer: true,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
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
  // New standalone lyrics trigger — sits below the cast/output pill in
  // the same right-aligned icon column, its own dedicated spot rather
  // than crowding into the heart or the cast pill.
  final VoidCallback onLyricsTap;

  const _SongInfo({
    required this.song,
    required this.hPad,
    required this.isTablet,
    required this.isFav,
    required this.onFavTap,
    required this.bgLuma,
    required this.onLyricsTap,
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
              const SizedBox(height: 8),
              // Standalone lyrics trigger — own dedicated spot beneath
              const SizedBox(height: 8),
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
// ─────────────────────────────────────────────────────────────────────────────
// Immersive Lyrics — trigger button + full-screen overlay.
//
// Trigger: a small pill-style icon button sitting next to the inline
// lyrics strip. Tapping it opens a full-screen, theme-matched lyrics view
// with a glow-aura loading transition (the "Gemini-style" morph the user
// asked for) — album art fades out through a soft accent-colored glow
// pulse, settling into a calm, static (non-glowing) lyrics screen once
// the transition completes. Reuses _LyricsPage for the actual lyrics
// content/fetch/scroll/sync logic rather than duplicating it — that
// widget is already fully self-contained (watches PlayerProvider,
// fetches, romanizes Devanagari, tracks the active line) so it drops in
// unchanged.
//
// Kept as an in-place overlay inside _FullPlayerScreenState (not a
// pushed route) so it can read _currentBg1..4 / the live song directly,
// same reasoning as _openPanel's sheet above.
// ─────────────────────────────────────────────────────────────────────────────
class _ImmersiveLyricsTriggerButton extends StatelessWidget {
  final double bgLuma;
  final bool isActive;
  final VoidCallback onTap;
  const _ImmersiveLyricsTriggerButton({
    required this.bgLuma,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgIsLight = bgLuma >= 0.5;
    // FIX ("buttons ekdam clean/professional lage, paid app jaisa"):
    // this toggle previously looked identical whether the lyrics
    // overlay was open or closed — a proper toggle button needs to show
    // its own ON state, not just fire onTap. Active state now gets the
    // accent-tinted fill + a thin matching border (the same restrained
    // "lit" treatment used on the active lyric line elsewhere in this
    // file), so at a glance the button itself communicates "this is on"
    // — exactly the kind of state feedback paid/production apps have
    // and free-feeling ones skip.
    final iconColor = isActive
        ? (bgIsLight ? AurumTheme.lightTextPrimary : Colors.white)
        : (bgIsLight
            ? AurumTheme.lightTextSecondary
            : Colors.white.withAlpha(180));
    final fillColor = isActive
        ? (bgIsLight
            ? AurumTheme.lightTextPrimary.withAlpha(30)
            : Colors.white.withAlpha(42))
        : (bgIsLight
            ? AurumTheme.lightTextPrimary.withAlpha(18)
            : Colors.white.withAlpha(22));
    final borderColor = isActive
        ? (bgIsLight
            ? AurumTheme.lightTextPrimary.withAlpha(60)
            : Colors.white.withAlpha(90))
        : Colors.transparent;

    // Relocated to the LOCAL/quality-pill row (28px tall) — resized from
    // 34px down to 26px so it fits that row cleanly instead of
    // overflowing it, and re-iconed to a sparkle (Gemini's own mark for
    // its AI features) instead of the generic expand-arrows glyph, so
    // the button itself signals "AI-styled lyrics" rather than reading
    // as a plain fullscreen toggle.
    return AurumPressable(
      onTap: onTap,
      scaleAmount: 0.90,
      child: AnimatedContainer(
        // Same 320ms/easeOutCubic beat as the rest of this screen's
        // premium transitions (active lyric line, glow fades) — a
        // consistent animation "voice" across every touch point reads
        // as intentional design, not a grab-bag of different timings.
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: fillColor,
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: isActive
            // FIX ("button attractive lage"): when active, the sparkle
            // icon itself carries the same red/yellow/green/blue Gemini
            // palette the full-screen glow uses — a plain single-color
            // icon didn't read as tied to the colorful aura it triggers.
            // ShaderMask is a one-time cheap paint (no animation, no
            // per-frame cost) — this only differs from the inactive
            // state's flat Icon, adding nothing to the glow layer's own
            // ongoing per-frame cost discussed above.
            ? ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [
                    Color(0xFFEA4335),
                    Color(0xFFFBBC05),
                    Color(0xFF34A853),
                    Color(0xFF4285F4),
                  ],
                ).createShader(bounds),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 13,
                  color: Colors.white,
                ),
              )
            : Icon(
                Icons.auto_awesome_rounded,
                size: 13,
                color: iconColor,
              ),
      ),
    );
  }
}

/// Full-screen edge aura glow — separate from the thumbnail↔lyrics
/// content swap (which lives confined to the artwork's own box inside
/// _Artwork). This layer paints across the ENTIRE player screen — top
/// bar, title, seek bar, controls all included — exactly like the real
/// Gemini full-screen treatment, while the actual content swap stays
/// confined to the artwork box beneath it. Purely decorative
/// (IgnorePointer): taps/drags for opening/closing/scrolling lyrics are
/// still owned by the content overlay inside the artwork box, not here.
class _ImmersiveGlowLayer extends StatelessWidget {
  final AnimationController controller;
  const _ImmersiveGlowLayer({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // PERF FIX ("low-end device pe heating/battery ekdam 0% jaisa
        // rahe, Google app jaisa optimize"): this painter runs 4
        // RadialGradient shader rebuilds + a blurred stroke every
        // single call — at a raw 60fps drive that's real, sustained
        // GPU work for the whole open/hold/close duration, exactly the
        // kind of sustained cost that heats up a weak device during a
        // long breathing-glow hold. The visual motion here (a slow
        // sinusoidal "breathe") has no fast detail — nothing about it
        // needs 60 distinct paints per second to look smooth.
        // Quantizing to 30 discrete steps/sec BEFORE constructing the
        // painter means _GlowAuraPainter.shouldRepaint sees the exact
        // same `t` on alternating vsync ticks and skips the actual
        // raster for that frame — the painter's paint() genuinely only
        // executes ~30 times/sec instead of ~60, roughly halving this
        // layer's GPU cost, with zero perceptible difference in a slow
        // ambient glow. The breathe math/timing itself (below) is
        // completely untouched — this only throttles how often it gets
        // repainted, not how it behaves.
        final rawT = (controller.value * 30).round() / 30;
        // Same build → hold → release pulse timing as the content swap,
        // so the full-screen glow and the artwork-box cross-fade stay
        // in sync even though they're now two separate widgets.
        // FIX ("aura ka time thoda aur increase karo, top-class/
        // professional lage"): ramp-in slightly slower (0.14 instead of
        // 0.18) and the hold window widened to 0.14→0.90 (was 0.18→0.85)
        // — with the controller's own total duration also increased, the
        // aura now genuinely breathes on screen longer before it starts
        // releasing, reading as a deliberate, unhurried premium reveal
        // instead of a quick flash. Release window kept proportionally
        // similar (last ~10%) so the exit still feels controlled, not
        // dragged out.
        final glowVisibility = rawT < 0.14
            ? Curves.easeOut.transform((rawT / 0.14).clamp(0.0, 1.0))
            : rawT > 0.90
                ? Curves.easeIn.transform((1.0 - ((rawT - 0.90) / 0.10)).clamp(0.0, 1.0))
                : 1.0;
        if (glowVisibility <= 0.001) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            painter: _GlowAuraPainter(visibility: glowVisibility, t: rawT),
          ),
        );
      },
    );
  }
}

class _ImmersiveLyricsOverlay extends StatefulWidget {
  final AnimationController controller;
  final Song song;
  final Color bg1, bg2, bg3, bg4;
  final double dragY;
  final bool isDragging;
  final double maxArtSize;
  final VoidCallback onClose;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final ValueChanged<bool> onDragEnd; // true = should close

  const _ImmersiveLyricsOverlay({
    required this.controller,
    required this.song,
    required this.bg1,
    required this.bg2,
    required this.bg3,
    required this.bg4,
    required this.dragY,
    required this.isDragging,
    required this.maxArtSize,
    required this.onClose,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  State<_ImmersiveLyricsOverlay> createState() => _ImmersiveLyricsOverlayState();
}

class _ImmersiveLyricsOverlayState extends State<_ImmersiveLyricsOverlay> {
  // Drag-to-dismiss threshold — matches the feel of the player's own
  // swipe-down-to-dismiss elsewhere in this file (distance-based, with a
  // velocity escape hatch for a fast flick that hasn't crossed the
  // distance threshold yet).
  static const double _dismissDistance = 120.0;

  @override
  Widget build(BuildContext context) {
    // FIX ("kona ekdam thumbnail jaisa hona chahiye, space na chute" —
    // corner-radius mismatch): this overlay used to hardcode
    // BorderRadius.circular(20) regardless of the user's actual Settings
    // → Appearance → Artwork Shape choice. The real artwork right behind
    // it can be Circle (maxArtSize/2), Square (4.0), or Rounded (20.0) —
    // so on Circle or Square, the overlay's corners never matched the
    // artwork's own edge, reading as a visible seam/gap right at the
    // corners once the cross-fade landed. Reading the same
    // artworkShapeNotifier _ArtworkVisual already uses, with the exact
    // same radius formula, guarantees the overlay's box is pixel-for-
    // pixel the same shape as the artwork it's replacing, in all 4
    // corners, for every shape setting.
    return ValueListenableBuilder<String>(
      valueListenable: AudioPrefs.artworkShapeNotifier,
      builder: (context, shape, _) {
        final radius = shape == 'Circle'
            ? widget.maxArtSize / 2
            : shape == 'Square'
                ? 4.0
                : 20.0;
        return _buildOverlay(context, radius);
      },
    );
  }

  Widget _buildOverlay(BuildContext context, double radius) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        // t: 0 = fully closed (thumbnail/player visible, overlay
        // invisible), 1 = fully open (lyrics settled, glow gone).
        final rawT = widget.controller.value;
        // Eased progress drives every visual below — a raw linear t reads
        // mechanical; easeInOutCubic gives the transition a soft
        // start/end, the "weighted" feel premium transitions use instead
        // of a constant-speed morph.
        final t = Curves.easeInOutCubic.transform(rawT);

        // Edge-aura glow (matches the real Gemini full-screen treatment —
        // a soft multi-color wash that lives around the screen's BORDER,
        // pulsing/breathing while active, rather than a line/band that
        // sweeps across the middle). glowVisibility now drives a
        // build → hold → release pulse instead of a wipe position.
        // Ramps in over the first 14%, holds (breathing) through the
        // middle, releases over the last 10% as lyrics settle in — kept
        // in sync with _ImmersiveGlowLayer's own timing above (both
        // widened together so the aura stays present longer, per the
        // "top class/professional" timing pass).
        final glowVisibility = t < 0.14
            ? Curves.easeOut.transform((t / 0.14).clamp(0.0, 1.0))
            : t > 0.90
                ? Curves.easeIn.transform((1.0 - ((t - 0.90) / 0.10)).clamp(0.0, 1.0))
                : 1.0;

        // Thumbnail and lyrics cross-fade in place — no sweep line, no
        // left/right reveal edge. FIX (dead empty-background gap):
        // thumbnail used to fully vanish at t=0.45 while lyrics had
        // only just started fading in from t=0.40, leaving nearly a
        // full second of the transition showing bare gradient with
        // neither thumbnail nor legible lyrics — read as an awkward
        // "hang" mid-animation. Lyrics now start fading in from the
        // very beginning (t=0) and reach full opacity by t=0.55,
        // solidly overlapping thumbnail's own fade-out window, so
        // there's always at least one of the two clearly visible.
        final artOpacity = (1.0 - (t / 0.45)).clamp(0.0, 1.0);
        final lyricsOpacity = (t / 0.55).clamp(0.0, 1.0);

        // Subtle scale — thumbnail eases outward slightly as it
        // dissolves, lyrics ease inward slightly as they settle in.
        // Kept small so it stays premium, not gimmicky.
        final artScale = 1.0 + (1 - artOpacity) * 0.05;
        final lyricsScale = 0.98 + lyricsOpacity * 0.02;
        final artBlur = glowVisibility * 4.0;

        // Drag-to-dismiss: follows the finger 1:1 while dragging, and
        // fades proportionally so it reads as "pulling the lyrics away"
        // rather than the whole screen just sliding with no feedback.
        final dragT = widget.isDragging
            ? (widget.dragY / (MediaQuery.of(context).size.height * 0.6))
                .clamp(0.0, 1.0)
            : 0.0;
        final overlayOpacity = t * (1 - dragT);

        if (t <= 0.0 && !widget.isDragging) {
          return const SizedBox.shrink();
        }

        return IgnorePointer(
          // Was "t < 0.98" — meant the overlay ate zero taps/scrolls for
          // almost the entire 2.5s open animation, so scrolling lyrics or
          // tapping to dismiss right after opening did nothing until the
          // reveal had basically finished. Interactive as soon as it's
          // meaningfully on screen instead.
          ignoring: t < 0.05,
          child: Opacity(
            opacity: overlayOpacity,
            child: Transform.translate(
              offset: Offset(0, widget.isDragging ? widget.dragY : 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // FIX ("swipe down pe hat jata hai, ye band karo — jab
                // tak button dubara click na ho tab tak na hate"): tap-
                // anywhere-closes and swipe-down-to-dismiss are both
                // removed entirely (no vertical-drag handlers registered
                // at all here anymore) — so the lyrics ScrollablePosition-
                // edList underneath owns vertical drag/scroll cleanly on
                // its own, with nothing above it racing for the gesture
                // or misreading a scroll as a dismiss swipe. The ONLY way
                // to close this overlay now is the same sparkle button
                // that opened it (wired to onClose by the parent).
                // Rounded to match the artwork's own corner radius so
                // the gradient background and lyrics content read as
                // occupying the exact same rounded box the artwork did
                // — no square-corner mismatch peeking out from behind
                // the artwork's rounded shape mid-transition.
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  child: Stack(
                    fit: StackFit.expand,
                  children: [
                    // FIX ("thumbnail ke upar lyrics text tairte hue
                    // awkward lagta hai, koi separation nahi"): with no
                    // background here, once the thumbnail image started
                    // fading, lyrics text sat directly on top of the
                    // still-partially-visible artwork photo with nothing
                    // behind it — reading as messy overlap instead of a
                    // clean swap. Same 4-color corner gradient in both
                    // modes now (see the _buildLight/_buildDark rework
                    // above — light mode is dark mode's exact structure
                    // plus one uniform white wash, never its own separate
                    // formula), so this panel automatically matches
                    // whatever the rest of the player is doing instead of
                    // needing its own hand-kept-in-sync light-mode branch.
                    Opacity(
                      opacity: (1 - artOpacity).clamp(0.0, 1.0),
                      child: Builder(builder: (context) {
                        final isLight =
                            Theme.of(context).brightness == Brightness.light;
                        return Stack(fit: StackFit.expand, children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(radius),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  widget.bg1,
                                  widget.bg2,
                                  widget.bg3,
                                  widget.bg4,
                                ],
                              ),
                            ),
                          ),
                          // Same small, uniform white lift _buildLight
                          // applies to the whole player background — kept
                          // identical here so the panel never reads as a
                          // differently-tuned patch of the screen.
                          if (isLight)
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(radius),
                                  color: const Color.fromRGBO(255, 255, 255, 0.14),
                                ),
                              ),
                            ),
                        ]);
                      }),
                    ),
                    // Outgoing thumbnail/artwork — eases outward and
                    // softly blurs as the glow-wash sweeps over it, so it
                    // reads as being "consumed" by the glow rather than
                    // just fading in place.
                    if (artOpacity > 0.001)
                      Opacity(
                        opacity: artOpacity,
                        child: Transform.scale(
                          scale: artScale,
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: artBlur,
                              sigmaY: artBlur,
                            ),
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: Padding(
                                  padding: const EdgeInsets.all(48),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: AurumArtwork(
                                      url: widget.song.artworkUrl,
                                      size: double.infinity,
                                      borderRadius: 24,
                                      fadeIn: false,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // Incoming lyrics content — reuses _LyricsPage as-is
                    // (self-contained fetch/sync/scroll), eased inward
                    // (scale 0.97→1.0) as it's released from the glow so
                    // the swap reads as one continuous morph rather than
                    // a flat cross-dissolve on top of the same theme-
                    // matched gradient.
                    //
                    // FIX: this was wrapped in SafeArea, which made sense
                    // when this overlay covered the whole screen (needed
                    // to dodge the status bar) but is meaningless now
                    // that it's confined to the artwork's own box deep
                    // inside the player's Column — SafeArea here was
                    // just eating unnecessary top inset space from a box
                    // that was never near the status bar to begin with.
                    if (lyricsOpacity > 0.001)
                      Opacity(
                        opacity: lyricsOpacity,
                        child: Transform.scale(
                          scale: lyricsScale,
                          child: Column(
                            children: [
                              const SizedBox(height: 8),
                              Container(
                                width: 36,
                                height: 4,
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.white.withAlpha(60),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const Expanded(child: _LyricsPage()),
                            ],
                          ),
                        ),
                      ),
                    // Dedicated in-overlay close button — fades in together
                    // with the lyrics content (same lyricsOpacity curve) so
                    // it's on screen the instant immersive lyrics is opened
                    // from the inline strip, instead of requiring the user
                    // to look back up at the top-bar sparkle toggle to find
                    // a way out. Still just calls the same widget.onClose
                    // callback as that top-bar button — one close path,
                    // two entry points. Ignored while effectively invisible
                    // so it never eats a tap meant for the lyrics list
                    // underneath during the very start of the transition.
                    if (lyricsOpacity > 0.001)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: IgnorePointer(
                          ignoring: lyricsOpacity < 0.4,
                          child: Opacity(
                            opacity: lyricsOpacity,
                            child: AurumPressable(
                              onTap: widget.onClose,
                              scaleAmount: 0.90,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black.withAlpha(70),
                                  border: Border.all(
                                    color: Colors.white.withAlpha(50),
                                    width: 1,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                              ),
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
}

/// Edge aura glow — the actual Gemini treatment: a soft multi-color wash
/// (red/yellow/green/blue) that lives around the screen's BORDER and
/// breathes/pulses in intensity while active, rather than a band that
/// sweeps across the middle. Four soft radial blooms, one anchored past
/// each edge/corner, each independently drifting in strength so the
/// whole frame reads as one living aura rather than a static ring.
/// Thumbnail↔lyrics is a separate plain cross-fade (see artOpacity/
/// lyricsOpacity above) — this painter is pure ambient light, it does
/// not drive the swap itself. Kept to soft radial gradients only (no
/// stroke paths, no multi-layer shaders) so it stays cheap on low-end
/// devices, matching this file's other perf-conscious painters (see
/// _WaveformPainter, _StaticTintVignettePainter above).
class _GlowAuraPainter extends CustomPainter {
  final double visibility; // 0..1 — overall glow opacity (build → hold → release)
  final double t; // 0..1 — overall transition progress, drives the breathing/hue cycle
  const _GlowAuraPainter({
    required this.visibility,
    required this.t,
  });

  // REVERTED to the confirmed-good version ("isme aura wala bhahut sahi
  // hai" — this exact implementation, verified on-device, is the one to
  // keep). A later attempt added an explicit saveLayer + ImageFilter.blur
  // pass to make the fog "provably" soft-focused — technically a real
  // blur, but it changed how this reads on an actual device (heavier,
  // different falloff) compared to this simpler version, which was
  // already doing its softening via the RadialGradient's own alpha ramp
  // + the breathing animation + the multi-color overlap of 4 blooms —
  // apparently enough to read as genuinely foggy without an extra
  // offscreen blur pass. Restored byte-for-byte from the confirmed
  // version rather than re-tuned, so there's no risk of a "close but not
  // quite" mismatch.

  // Gemini's own multi-color palette (red/yellow/green/blue) — one
  // color anchored to each edge bloom below.
  static const List<Color> _palette = [
    Color(0xFFEA4335), // red — top
    Color(0xFFFBBC05), // yellow — right
    Color(0xFF34A853), // green — bottom
    Color(0xFF4285F4), // blue — left
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (visibility <= 0.001) return;

    final w = size.width;
    final h = size.height;
    // Bloom radius scales with the screen's larger dimension so the
    // wash reads consistently across phone/tablet aspect ratios.
    final radius = math.max(w, h) * 0.62;

    // Each edge bloom's center sits just outside that edge, at the
    // midpoint of the edge — glow falls off toward the screen center,
    // so the strongest light hugs the border, exactly like the
    // reference (glow concentrated at the frame, center left clear for
    // content).
    final blooms = <_EdgeBloom>[
      _EdgeBloom(Offset(w * 0.5, -h * 0.12), _palette[0]), // top
      _EdgeBloom(Offset(w * 1.12, h * 0.5), _palette[1]),  // right
      _EdgeBloom(Offset(w * 0.5, h * 1.12), _palette[2]),  // bottom
      _EdgeBloom(Offset(-w * 0.12, h * 0.5), _palette[3]), // left
    ];

    for (var i = 0; i < blooms.length; i++) {
      // Gentle per-bloom breathing so the aura feels alive rather than
      // a static fixed-intensity frame — each bloom is offset in phase
      // so they don't all pulse in lockstep.
      final phase = (t * 2 * math.pi * 1.4) + (i * math.pi / 2);
      final breathe = 0.75 + 0.25 * (0.5 + 0.5 * math.sin(phase));
      final alpha = (190 * visibility * breathe).round().clamp(0, 255);

      final bloom = blooms[i];
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            bloom.color.withAlpha(alpha),
            bloom.color.withAlpha((alpha * 0.35).round()),
            bloom.color.withAlpha(0),
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(Rect.fromCircle(center: bloom.center, radius: radius));
      canvas.drawCircle(bloom.center, radius, paint);
    }

    // A soft white inner rim right at the very edge of the screen, the
    // "sharper inner line" the real Gemini aura layers under the wide
    // soft wash — kept thin and heavily blurred so it reads as a glint,
    // not a hard border.
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withAlpha((90 * visibility).round())
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawRect(
      Rect.fromLTWH(1.5, 1.5, w - 3, h - 3),
      rimPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GlowAuraPainter oldDelegate) =>
      oldDelegate.visibility != visibility || oldDelegate.t != t;
}

class _EdgeBloom {
  final Offset center;
  final Color color;
  const _EdgeBloom(this.center, this.color);
}

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
// Play/Pause button. Tap drives AurumPlayPauseIcon's own path-morph
// animation (triangle↔bars, ported from Echo Nightly's animated-vector
// icon) — no separate ripple ring, just the icon transform itself.
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

class _PremiumPlayButtonState extends State<_PremiumPlayButton> {
  void _handleTap() {
    if (widget.isLoading) return;
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
          // Kept at 68x68 — sits in a Row(mainAxisAlignment: spaceBetween)
          // alongside shuffle/prev/next, so growing this widget's own
          // footprint would push those neighbouring buttons apart and
          // make the whole control row look asymmetric/cramped.
          width: 68,
          height: 68,
          child: Container(
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
                  // Outer switcher only handles the loading-spinner ↔
                  // icon swap (a genuine crossfade is correct there —
                  // there's no matching path to morph a spinner into).
                  // The actual play↔pause transition happens INSIDE via
                  // AurumPlayPauseIcon, which is a pixel-for-pixel port
                  // of Echo Nightly's animated-vector icon
                  // (ic_play_to_pause_48dp_anim.xml /
                  // ic_pause_to_play_48dp_anim.xml) — the triangle
                  // visibly reshapes into the two bars frame-by-frame
                  // (real path-data interpolation, not an icon crossfade)
                  // plus the same 90° rotation + 1.25x scale pop Echo's
                  // XML defines. See aurum_play_pause_icon.dart for the
                  // full breakdown of how the source path data was
                  // ported.
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: widget.isLoading
                      ? const SizedBox(
                          key: ValueKey('loading'),
                          width: 26,
                          height: 26,
                          child:
                              Center(child: AurumM3Loader(width: 26, height: 2.5)),
                        )
                      : AurumPlayPauseIcon(
                          key: const ValueKey('playpause'),
                          isPlaying: widget.isPlaying,
                          color: iconColor,
                          size: 36,
                        ),
            ),
          ),
        ),
      ),
    );
  }
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
  // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
  // so the scrim always has an explicit barrierColor.
  showAurumModalBottomSheet(
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
  // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
  // so the scrim always has an explicit barrierColor.
  showAurumModalBottomSheet(
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

  // Shared, deduped toast handler — see aurum_snack.dart for why this
  // replaced a hand-copied per-file implementation (this one previously
  // never set backgroundColor, so it fell back to Flutter's default
  // Material snackbar color instead of Astra's themed elevated surface —
  // now consistent with every other screen's toast).
  void _snack(String msg) {
    AurumSnack.show(context, msg);
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
      // ECHO NIGHTLY MATCH: same reasoning as song_tile.dart's grid —
      // Echo's own bottom-sheet buttons are all one flat neutral color
      // (icon included), never a per-action rainbow. The press-state
      // tint here already used `action.color` only as a brief on-tap
      // highlight, so switching every action to `textPrimary` keeps
      // that same press feedback mechanism while making the resting
      // icon color neutral instead of colorful.
      _SheetAction(Icons.skip_next_rounded, l10n.fpPlayNext, textPrimary, () {
        Navigator.pop(context);
        widget.player.playNext(song);
      }),
      _SheetAction(Icons.queue_music_rounded, l10n.fpAddToQueue, textPrimary, () {
        Navigator.pop(context);
        widget.player.addToQueue(song);
        _snack(l10n.fpAddedToQueue);
      }),
      _SheetAction(
        isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        isLiked ? l10n.fpLiked : l10n.fpLikeAction,
        textPrimary,
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
      _SheetAction(Icons.share_rounded, l10n.fpShare, textPrimary, () {
        Navigator.pop(context);
        shareSong(context, song);
      }),
      _SheetAction(Icons.playlist_add_rounded, l10n.fpSaveToPlaylist, textPrimary, () {
        Navigator.pop(context);
        showAddToPlaylistSheet(widget.rootContext, song);
      }),
      _SheetAction(Icons.equalizer_rounded, l10n.fpAudioEffects, textPrimary, () {
        Navigator.pop(context);
        Navigator.of(widget.rootContext).push(AurumPageRoute(
          builder: (_) => EqualizerScreen(audioEngine: widget.player.handler),
        ));
      }),
      _SheetAction(
        sleepActive ? Icons.bedtime_rounded : Icons.timer_outlined,
        sleepActive ? l10n.fpSleepRemaining(sleepRemainingLabel) : l10n.fpSleepTimer,
        textPrimary,
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
        textPrimary,
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

  // Removed: unused fade controller. Tab switching now uses a plain
  // AnimatedSwitcher (see _buildTabContent) — cheaper, and avoids the
  // size-jump jank a single-controller FadeTransition had when pages
  // of different heights swapped mid-fade.
  static const _tabSwitchDuration = Duration(milliseconds: 140);

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
    _springBackCtrl.dispose();
    _exitCtrl.dispose();
    _dragYNotifier.dispose();
    super.dispose();
  }

  void _switchTab(int idx) {
    if (idx == _activeTab) return;
    AurumHaptics.selection();
    // Instant switch, Echo Nightly style (fragment show/hide — no
    // blank/flicker gap). AnimatedSwitcher below handles the crossfade
    // purely visually so this stays a single, cheap setState.
    setState(() => _activeTab = idx);
  }

  void _springBackToZero() {
    _springBackAnim = Tween<double>(begin: _dragY, end: 0).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.elasticOut),
    );
    _springBackCtrl
      ..reset()
      ..forward();
  }

  // Captures the live drag offset (in px) at the moment dismiss is
  // committed, so _exitCtrl's slide-out can continue seamlessly from
  // wherever the panel actually was — instead of snapping back to 0
  // first. See _dismiss() below.
  double _dismissStartDragY = 0;

  void _dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    AurumHaptics.light();
    // FIX ("thoda sa niche karo to panel turant invisible ho jata hai,
    // phir ekdum niche chala jata hai — awkward jump"): _dismiss() used to
    // just start _exitCtrl and leave _dragY frozen at whatever pixel value
    // the finger released at. The live-drag opacity math above already
    // reaches 0 by _dragY == 90px (this handle's own dismiss threshold —
    // see the comment on panelDragFraction/dragOpacity), so ANY dismiss
    // triggered by crossing that threshold was, by construction, already
    // fully transparent the instant _dismiss() ran — before _exitCtrl's
    // 280ms translate had moved it anywhere. The panel then kept sliding
    // for another 280ms while completely invisible, only to pop() at the
    // end: "vanish first, THEN jump down".
    //
    // An earlier version of this fix hard-reset _dragY to 0 right here to
    // remove that frozen drag-opacity term. That traded one bug for
    // another: since _exitCtrl hasn't advanced yet at the instant
    // forward() is called, offset/opacity/scale all evaluate to their
    // fully-open resting values (0, 1.0, 1.0) for exactly one frame before
    // the exit animation's own translate starts moving — a visible snap
    // BACK to fully-open, then a slide down, right at release. Capturing
    // the actual release position instead (_dismissStartDragY) and having
    // the exit's offset/opacity continue FROM there (see the
    // ValueListenableBuilder below, which now blends _dismissStartDragY
    // with _exitCtrl's own progress once dismissing) means there is no
    // reset frame at all — the panel simply continues its motion smoothly
    // from wherever the finger let go, all the way off-screen, as one
    // unbroken slide+fade. This matches the full player's own swipe-down
    // dismiss, which never resets position before its exit animation
    // either.
    _springBackCtrl.stop();
    _dismissStartDragY = _dragY;
    _exitCtrl.forward().then((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenW = MediaQuery.of(context).size.width;
    final screenH = MediaQuery.of(context).size.height;
    final topInset = MediaQuery.of(context).padding.top;
    // FIX ("niche aur kinaro pe white/grey gap dikhta hai, dheere dheere
    // fill hota hai"): useSafeArea:false on the showModalBottomSheet call
    // means THIS build() is responsible for the full physical screen
    // height, bottom system inset included. panelHeight used to be
    // measured purely against screenH with no bottomInset term at all —
    // so on any gesture-nav / 3-button-nav device (i.e. virtually all of
    // them), the sheet's ClipRRect stopped short of the true bottom edge
    // by exactly that inset, and the raw barrierColor/scaffold behind it
    // showed through as a flat grey/white strip along the bottom (and
    // briefly at the very edges during the first layout pass, since the
    // SizedBox was never pinned to an explicit full width either — hence
    // the "gap that fills in over a couple frames" look). Adding
    // bottomInset here and consuming it as extra panel height (not
    // padding-in-content) means the glass/blur itself now genuinely
    // reaches the physical bottom edge — same fix pattern Echo Nightly's
    // fragment_player_more.xml gets for free from insetting against
    // WindowInsetsCompat natively.
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // FIX ("Up Next page Echo Nightly jitni height pe nahi ja raha"):
    // 0.80 * screenH capped this panel noticeably shorter than Echo
    // Nightly's PlayerMoreFragment, which sits almost flush under the
    // status bar (see fragment_player_more.xml's tiny fixed top margin).
    // Bumped to 0.92 — still leaves a sliver of the full player/status
    // bar visible above it (so it never reads as a full-screen route
    // swap), but now genuinely matches the reference height instead of
    // stopping noticeably short.
    final panelHeight = (screenH * 0.92 + bottomInset)
        .clamp(360.0, screenH - topInset - 12.0 + bottomInset);
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

    // FIX ("dark mode AUR light mode dono mein panel ke kinare aur neeche
    // white/mismatched gap dikhta hai, kuch seconds mein dheere-dheere
    // fill hota hai"): the bottomInset extension to panelHeight above
    // gets the glass panel's own content to reach the true bottom edge,
    // but doesn't stop the OS from painting its system nav bar ON TOP of
    // that edge in whatever color it last had — which, since this sheet
    // (useSafeArea:false) never sets its own SystemUiOverlayStyle, is
    // whatever the full player screen behind it left configured. Making
    // the nav bar fully transparent here means there is nothing for the
    // OS to paint there at all, in either theme, with zero lag/settle
    // time — the panel's own bottomInset-extended background shows
    // straight through instead.
    final overlayStyle = isLight
        ? SystemUiOverlayStyle.dark.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness: Brightness.dark,
          )
        : SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness: Brightness.light,
          );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: AnimatedBuilder(
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
            // FIX (continued from _dismiss()): once a dismiss is committed,
            // freeze the drag-position term at exactly where the finger
            // released (_dismissStartDragY) instead of continuing to read
            // the live _dragYNotifier — which _dismiss() no longer resets,
            // so it stays exactly at the release value anyway, but reading
            // it explicitly here makes the intent unambiguous. Opacity
            // also stops depending on dragOpacity once dismissing: if the
            // release happened past the 90px threshold, dragOpacity is
            // already pinned at 0, which would keep this panel invisible
            // for the entire exit — instead, _exitFade alone (1.0 → 0
            // over the last 30% of the 280ms exit) now owns opacity during
            // dismissal, so the panel stays visibly on-screen and simply
            // slides+fades out as one continuous motion with no reset and
            // no premature vanish.
            // FIX ("Up Next ko hand se niche kro to woh bahut jaldi/
            // achanak gayab ho jata hai — thoda sa drag karte hi
            // invisible, full player ke swipe-down jaisa natural/
            // gradual nahi lagta"): opacity here used to fade against
            // panelDragFraction = dragY/90 — i.e. the SAME 90px used
            // only as the release-dismiss threshold. Since dragOpacity's
            // falloff window was (panelDragFraction-0.75)/0.25, the
            // panel went from fully opaque to fully invisible across
            // just ~22px of real finger movement (67.5px→90px) — a tiny
            // flick, nowhere close to how far the panel had actually
            // moved on screen. The full player's own swipe-down
            // (_DragTransform above) fades against the FULL screen
            // height instead — dismissProgress = dragY/screenH, with
            // fade only in the last 25% of that full-screen drag — so
            // it stays visibly present and tracks the hand the entire
            // way down, only dissolving right at the very end. Using
            // that exact same screenH-relative formula here (instead of
            // the 90px one) gives Up Next the identical natural, full-
            // hand-travel feel: drag it all the way down like the full
            // player, or barely nudge it and let go to spring back —
            // the 90px/600px-velocity numbers below still decide WHEN a
            // release counts as "dismiss" vs "spring back", they just no
            // longer also drive how fast the panel visually fades.
            final effectiveDragY = _isDismissing ? _dismissStartDragY : dragY;
            final dragFraction = (effectiveDragY / screenH).clamp(0.0, 1.0);
            final dragOpacity =
                1.0 - ((dragFraction - 0.75) / 0.25).clamp(0.0, 1.0);
            final scale = (1.0 - dragFraction * 0.06).clamp(0.88, 1.0);
            final opacity = _isDismissing
                ? _exitFade.value
                : (dragOpacity * _exitFade.value).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(
                  0,
                  // FIX (continued): translate used to hard-clamp at
                  // screenH * 0.5, so even a full, deliberate drag all
                  // the way to the bottom of the screen stopped moving
                  // visually at the halfway point — while the opacity
                  // fade above (now correctly screenH-relative) kept
                  // expecting the drag to continue past that. The panel
                  // would sit frozen at half-screen, still fading, which
                  // read as stuck rather than following the hand. Full
                  // player's own _DragTransform clamps to the actual
                  // screenH so the live drag can travel the entire way
                  // off-screen with the finger — matching that here
                  // means Up Next can genuinely be dragged all the way
                  // down (or pulled back up) by hand, exactly like the
                  // full player itself.
                  effectiveDragY.clamp(0.0, screenH) + exitOffsetY),
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
                width: screenW,
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
                              // FIX ("swipe down se panel band hi nahi hota
                              // tha"): the drag-to-dismiss GestureDetector
                              // used to wrap ONLY the 32×4px handle bar
                              // itself — a genuinely tiny target, especially
                              // one-handed with a thumb, so most swipe-down
                              // attempts landed just outside it and did
                              // nothing. Widened to the full handle+padding
                              // strip (32px tall touch band across the
                              // panel's whole width) so any swipe-down
                              // starting near the top of the sheet — not
                              // just a pixel-perfect hit on the small bar —
                              // registers. The visual handle indicator
                              // stays the same small pill; only the hit
                              // area grew.
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) {
                                  // FIX ("hand se upar bhi le ja sakte
                                  // — thoda niche khींchne ke baad
                                  // wapas upar dhakka do to turant
                                  // follow kare, sirf release ke baad
                                  // spring-back animation ka intezaar
                                  // na karna pade"): only d.delta.dy > 0
                                  // (downward) was ever applied to
                                  // _dragY — any upward movement mid-
                                  // drag was silently dropped, so
                                  // pulling back up with the finger
                                  // still down did nothing until you
                                  // let go and the separate spring-back
                                  // animation kicked in. Clamping the
                                  // running total to >= 0 (instead of
                                  // gating on delta direction) lets the
                                  // panel track the finger smoothly in
                                  // BOTH directions during the live
                                  // drag — exactly how the full
                                  // player's own swipe-down already
                                  // behaves — while still never going
                                  // negative (which would push the
                                  // panel above its resting position).
                                  _springBackCtrl.stop();
                                  _dragY = (_dragY + d.delta.dy)
                                      .clamp(0.0, double.infinity);
                                },
                                onVerticalDragEnd: (d) {
                                  if (_dragY > 90 ||
                                      (d.primaryVelocity ?? 0) > 600) {
                                    _dismiss();
                                  } else {
                                    _springBackToZero();
                                  }
                                },
                                child: Container(
                                  width: double.infinity,
                                  color: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                  alignment: Alignment.center,
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
                              _buildTabBar(isLight),
                              Expanded(
                                // FIX ("Up Next list ke andar se swipe-down
                                // se panel band nahi hota, sirf upar wale
                                // chhote handle se hota tha"): drag-to-
                                // dismiss lived only on the handle strip so
                                // it would never fight the list's own
                                // scroll gesture — correct for the middle
                                // of a long list, but it meant a swipe-down
                                // starting ANYWHERE on the list itself (the
                                // far more natural, YouTube/Echo-Nightly-
                                // like place to start that gesture) did
                                // nothing at all. OverscrollNotification is
                                // the right native signal for this: with
                                // ClampingScrollPhysics (no rubber-band),
                                // Flutter still emits one the instant a
                                // drag continues past the list's top edge
                                // — i.e. only once there's nowhere left to
                                // scroll. Feeding that into the exact same
                                // _dragY/_dismiss path the handle already
                                // uses means the list scrolls completely
                                // normally right up until it's actually at
                                // the top, and only then does further
                                // downward drag hand off to closing the
                                // panel — no competing recognizer, no
                                // stolen scroll gestures, just the natural
                                // "can't scroll further, so the swipe
                                // closes the sheet" feel.
                                child: NotificationListener<ScrollNotification>(
                                  // FIX ("Up Next list se fast swipe-down
                                  // karne par panel bahut fast/black jaisa
                                  // dikhta hai aur band nahi hota, sirf
                                  // back button se hatta hai"): the
                                  // dismiss decision used to live on a
                                  // sibling GestureDetector's
                                  // onVerticalDragEnd — but once the
                                  // ListView's own scroll drag wins the
                                  // gesture arena (which it always does,
                                  // being the more specific/nested
                                  // recognizer), that GestureDetector's
                                  // pan recognizer never starts, so its
                                  // onVerticalDragEnd never fires. Only
                                  // the OverscrollNotification below was
                                  // still reaching _dragY, so a fast
                                  // swipe pushed the panel almost fully
                                  // off-screen/transparent via
                                  // Transform.translate + Opacity, but
                                  // _dismiss()/_springBackToZero() were
                                  // never called on release — the panel
                                  // was left stranded exactly where the
                                  // finger let go (reading as "black"/
                                  // stuck) until an unrelated code path
                                  // (the system back button) popped the
                                  // route instead. ScrollEndNotification
                                  // is the correct native "finger lifted
                                  // after this scroll gesture" signal —
                                  // listening for it here (instead of a
                                  // competing GestureDetector) means the
                                  // same drag/scroll gesture that moved
                                  // _dragY is also what decides, on
                                  // release, whether to dismiss or spring
                                  // back — no arena conflict possible.
                                  onNotification: (notification) {
                                    if (notification is OverscrollNotification &&
                                        notification.overscroll < 0) {
                                      _springBackCtrl.stop();
                                      _dragY += -notification.overscroll;
                                    } else if (notification is ScrollEndNotification) {
                                      if (_dragY > 90) {
                                        _dismiss();
                                      } else if (_dragY > 0) {
                                        _springBackToZero();
                                      }
                                    }
                                    return false;
                                  },
                                  child: AnimatedSwitcher(
                                  duration: _tabSwitchDuration,
                                  switchInCurve: Curves.easeOut,
                                  switchOutCurve: Curves.easeIn,
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  ),
                                  layoutBuilder:
                                      (currentChild, previousChildren) =>
                                          Stack(
                                    alignment: Alignment.topCenter,
                                    children: [
                                      ...previousChildren,
                                      if (currentChild != null) currentChild,
                                    ],
                                  ),
                                  child: KeyedSubtree(
                                    key: ValueKey(_activeTab),
                                    child: Padding(
                                      padding: EdgeInsets.only(bottom: bottomInset),
                                      child: _buildTabContent(),
                                    ),
                                  ),
                                ),
                                ),
                              ),
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
    ),
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

  // Echo Nightly's actual PlayerMoreFragment spec (fragment_player_more.xml
  // + styles.xml): MaterialButtonToggleGroup, 48dp tall, 6dp gap between
  // segments (each segment its own rounded button, not one shared track
  // with a sliding highlight), active segment = solid filled button,
  // inactive = flat/transparent. Matched 1:1 here instead of the smaller
  // 40dp single-track version from before.
  Widget _buildTabBar(bool isLight) {
    final l10n = AppLocalizations.of(context)!;
    final tabs = [l10n.fpQueue, l10n.fpLyrics, l10n.fpInfo];

    final inactiveBg =
        isLight ? Colors.black.withAlpha(10) : Colors.white.withAlpha(16);
    final activeBg =
        isLight ? Colors.white : Colors.white.withAlpha(235);
    final activeText = Colors.black87;
    final inactiveText =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(150);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: SizedBox(
        height: 48,
        child: Row(
          children: List.generate(tabs.length, (i) {
            final isActive = _activeTab == i;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  left: i == 0 ? 0 : 3,
                  right: i == tabs.length - 1 ? 0 : 3,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _switchTab(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: isActive ? activeBg : inactiveBg,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: Colors.black.withAlpha(30),
                                blurRadius: 6,
                                offset: const Offset(0, 1),
                              ),
                            ]
                          : null,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      tabs[i],
                      style: TextStyle(
                        color: isActive ? activeText : inactiveText,
                        fontSize: 13,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
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

        // FIX ("Up Next mein songs upar-niche stuck jaisa lagta tha,
        // reorder drag ke time list ka apna bounce/rubber-band feel
        // usse fight karta tha"): BouncingScrollPhysics (iOS-style
        // rubber-band overscroll) actively resists/springs back against
        // SliverReorderableList's own autoscroll-near-edge behavior —
        // dragging a tile close to the top/bottom of this list fights
        // the bounce instead of scrolling cleanly, which is exactly what
        // reads as "stuck". Echo Nightly (and every Android-native list)
        // uses a flat, no-bounce ClampingScrollPhysics — the list simply
        // stops dead at its edges with zero spring resistance, so a
        // reorder-drag's autoscroll near an edge is perfectly smooth and
        // predictable instead of fighting a rubber band.
        return CustomScrollView(
          physics: const ClampingScrollPhysics(),
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
            // Up next list — drag handle reorders (long-press-free, grabs
            // instantly), tap X removes. SliverReorderableList keeps this
            // on the same lightweight sliver scroll as everything else
            // above (no nested scrollables, no extra scroll controller
            // wiring needed).
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

class _QueueTileState extends State<_QueueTile> {
  // FIX ("Up Next songs Echo Nightly jaisa fixed layout — hamesha ek
  // visible X, swipe hataa do"): this used to carry its own
  // AnimationController + drag-offset state + a Stack/reveal-behind-tile
  // layer purely to support swipe-to-delete (Spotify/YT Music style).
  // Replacing that with a plain always-visible X icon is both what was
  // asked for AND meaningfully lighter: every tile in a long Up Next
  // list no longer owns a live AnimationController or runs an
  // AnimatedBuilder on every frame of a swipe gesture — on a low-end
  // device with 50+ queued songs that's a real number of controllers
  // removed, not just fewer lines of code.
  void _confirmDelete() {
    AurumHaptics.heavy();
    widget.onRemove();
  }

  void _showQuickActions() {
    AurumHaptics.medium();
    final isLight = Theme.of(context).brightness == Brightness.light;
    // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
    // so the scrim always has an explicit barrierColor.
    showAurumModalBottomSheet(
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
    final isLight = Theme.of(context).brightness == Brightness.light;

    return RepaintBoundary(
      child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: _showQuickActions,
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
                // Screenshot spec: X (remove) is always visible, sits
                // just left of the drag handle — tap removes immediately,
                // no swipe/reveal step needed. A plain IconButton here is
                // the lightest possible way to do this: no controller, no
                // extra gesture arena, nothing to animate at rest.
                IconButton(
                  onPressed: _confirmDelete,
                  icon: Icon(Icons.close_rounded, color: dragColor, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                      minWidth: 32, minHeight: 32),
                  splashRadius: 18,
                ),
                const SizedBox(width: 4),
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
                // FIX ("drag ekdam natural, Echo Nightly ka
                // ItemTouchHelper jaisa instant"): the handle already
                // has its own isolated opaque GestureDetector above, so
                // there's no ambiguous gesture to wait out — the 500ms
                // long-press-to-arm delay (ReorderableDelayedDragStartListener)
                // that made sense back when this shared an arena with
                // swipe-to-delete is no longer needed now that swipe-to-
                // delete is gone entirely (replaced by the always-visible
                // X). Android's ItemTouchHelper (what Echo Nightly's
                // queue actually rides on) starts a drag the instant you
                // press and move on its handle — no wait at all. Switching
                // to the non-delayed listener matches that: press the
                // handle, it's already grabbed, follows the finger from
                // the very first pixel of movement.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: ReorderableDragStartListener(
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
      // FIX ("line change hote hi lyrics bounce karke niche aa jaate
      // hain, Spotify jaisa stable nahi" — CONFIRMED still present in
      // the post-frame-setState version): posting setState() to the
      // frame AFTER scrollTo() starts avoided the same-frame conflict,
      // but scrollTo()'s own 320ms animation and the active line's
      // AnimatedScale/AnimatedContainer/AnimatedDefaultTextStyle (also
      // 320ms, starting one frame later) still ran CONCURRENTLY —
      // ScrollablePositionedList keeps re-measuring item extents as
      // they change, so while the target line was still mid-grow, the
      // list could still nudge/correct its own offset under it. Net
      // result: still a small but visible settle/overshoot right as
      // the line finished growing, same symptom as before, just
      // smaller. Splitting this into two explicit phases removes the
      // overlap entirely: (1) setState() first so the target line
      // jumps straight to its FINAL grown size/height with no
      // animation, (2) only THEN call scrollTo() against that already-
      // stable extent. The line's grow is now visually carried by
      // AnimatedScale/AnimatedContainer's own 320ms tween starting from
      // its last frame's smaller values (Flutter's implicit animations
      // interpolate from whatever was on screen, not from a hard reset)
      // — so the growth still animates smoothly in place exactly as
      // before, it's just that ScrollablePositionedList now targets a
      // number that never moves under it mid-flight.
      if (mounted) setState(() {});
      if (idx >= 0 && _scrollController.isAttached) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scrollController.isAttached) {
            _scrollController.scrollTo(
              index: idx,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              // Keeps the active line roughly a third of the way down
              // the viewport instead of pinned to the very top.
              alignment: 0.35,
            );
          }
        });
      }
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
      // FIX ("Hindi + English dono mixed dikh raha hai, ekdam clean
      // nahi"): this used to always romanize Devanagari lyrics into
      // Roman-script text with no toggle — but the source lyrics here
      // often already carry a mix of Devanagari and romanized words in
      // the same line (as seen in the reported screenshot), so
      // re-transliterating on top of that produced garbled, mixed
      // output. The inline lyrics strip elsewhere on this screen
      // never transliterates — it shows the fetched line exactly as
      // returned — and that's what reads as clean. Matching that here:
      // show the raw synced text unchanged, same as the inline strip.
      final displayLines = rawLines;
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
      // Same fix as the synced-lyrics branch above — show raw text,
      // matching the inline strip's always-original display.
      final displayPlain = rawPlain;
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
                // FIX ("lyrics dead lagta hai, live/human feel chahiye —
                // top grade, awkward nahi"): a tiny vertical settle
                // (2px → 0) layered on top of the existing scale, so the
                // active line reads as gently "rising into place" rather
                // than a flat in-place scale-up — the same subtle motion
                // Apple Music/Spotify lines have that makes them feel
                // alive instead of a mechanical size toggle. Pure
                // AnimatedSlide (implicit, same cost class as the
                // AnimatedScale already here) — no new controller, no
                // extra rebuild, safe on low-end devices.
                child: AnimatedSlide(
                  offset: isActive ? Offset.zero : const Offset(0, 0.03),
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
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
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // FIX ("white line jaata hai next line pe, kuch sec
                      // tak upar rehta hai phir awkward tarike se niche
                      // jaata hai"): the glow used to live inside an
                      // AnimatedContainer's `decoration` (color +
                      // boxShadow), toggled null ↔ non-null per line.
                      // Flutter's BoxDecoration tween can't interpolate a
                      // null boxShadow, so instead of a smooth 320ms fade
                      // it SNAPPED the glow fully on for the new active
                      // line while the old line's glow was still
                      // mid-fade-out on its own separate frame — reading
                      // as a stray glow/line hanging in place for a beat
                      // before jumping. The glow box now always exists in
                      // the tree (same size, same position) and only its
                      // OPACITY is animated, which Flutter tweens
                      // perfectly smoothly frame-to-frame — no snap, no
                      // stray leftover glow, both old and new line fade
                      // in perfect lockstep.
                      Positioned.fill(
                        child: AnimatedOpacity(
                          opacity: isActive ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              // FIX ("doodh jaisa"/milky smudge in light
                              // mode): the pill fill used to be glowColor
                              // (near-black at ~16% alpha) halved again —
                              // a very faint grey wash that reads as a
                              // dirty smudge on a light background instead
                              // of a solid highlight. Dark mode's white
                              // glow at low alpha looks fine because white
                              // washes read as a soft light; the same
                              // trick with black just looks muddy. Light
                              // mode now gets its own solid, clearly
                              // visible pill fill (still tinted from the
                              // artwork palette via activeColor, just at
                              // an opacity that actually reads as
                              // "highlighted" rather than "smudged"), and
                              // dark mode keeps the original glow look.
                              color: isLight
                                  ? activeColor.withAlpha(22)
                                  : glowColor.withAlpha(
                                      (glowColor.alpha * 0.5).round()),
                              boxShadow: isLight
                                  ? null
                                  : [
                                      BoxShadow(
                                        color: glowColor,
                                        blurRadius: 28,
                                        spreadRadius: -6,
                                      ),
                                    ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: 11, horizontal: 14),
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
                    ],
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
  final GlobalKey<_StaticBlurArtworkState> kenBurnsKey;

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
    required this.kenBurnsKey,
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
                  key: kenBurnsKey,
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
  // ── LIGHT MODE ──
  // REWORK ("light mode ekdam dark mode jaisa hi ho, bas thoda sa glow
  // do — aankh pe zor na pade — ekdam production grade"): this used to
  // be a COMPLETELY separate implementation from _buildDark — different
  // L0 base color (warm-grey vs pure black), different Solid formula,
  // different vignette painter. Two independently-built layer stacks for
  // the same artwork is exactly why every previous fix here only patched
  // one symptom at a time (milky solid fill, hazy gradient corner, etc)
  // without ever converging — they were two different designs, not one
  // design in two brightnesses. Light mode now reuses _buildDark's exact
  // layer structure verbatim (same base, same staticBlur, same vignette
  // painter, same Solid-mode branch) and applies exactly ONE additional
  // thing on top: a thin, uniform white wash whose opacity is the only
  // light/dark knob in the whole screen. Everything else — proportions,
  // which layer sits where, how Solid mode differs from Gradient mode —
  // is now guaranteed identical between the two modes by construction,
  // not by keeping two formulas in sync by hand.
  Widget _buildLight(Color bg1, Color bg2, Color bg3, Color bg4, Widget staticBlur) {
    // Same dark-mode-tuned stack, unchanged. isLight/dynamicColor still
    // reach _buildDark via the bg1..4 values already computed for light
    // mode in _applyPalette (same formula as dark, just pre-lifted
    // toward white by a small uniform amount) — so this call renders the
    // identical structure dark mode gets, just with slightly brighter
    // input colors already baked in.
    final darkStack = _buildDark(bg1, bg2, bg3, bg4, staticBlur);
    // The extra, deliberately small lift on top: a flat white wash at
    // low, constant opacity. This is the ONLY difference from dark mode
    // — no separate base color, no separate vignette math, no separate
    // Solid-mode formula — just enough to keep the screen from reading
    // as "basically dark mode" while staying nowhere near bright enough
    // to strain the eyes the way the old washed-out attempts did.
    return Stack(fit: StackFit.expand, children: [
      darkStack,
      const IgnorePointer(
        child: ColoredBox(color: Color.fromRGBO(255, 255, 255, 0.14)),
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
      // FIX ("background me thoda glow badhao, ekdam clean/stable/
      // professional lage"): same single static paint call as before
      // (zero added cost — shouldRepaint stays false, no extra layer),
      // just richer tint alphas so the palette glow reads more present
      // behind the artwork instead of a faint wash.
      if (bgStyle != 'Gradient')
        RepaintBoundary(
          child: CustomPaint(
            painter: _StaticTintVignettePainter(
              tint1: bg1.withAlpha(165),
              tint2: bg2.withAlpha(120),
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
class _StaticBlurArtwork extends StatefulWidget {
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
  State<_StaticBlurArtwork> createState() => _StaticBlurArtworkState();
}

// EXACT MATCH ("Echo Nightly ka blur background genuinely slowly pans/
// zooms — Ken Burns — usse hataana galat tha"): Echo Nightly's own
// bg_image is a KenBurnsView (fragment_player.xml), not a static image —
// confirmed by reading the actual layout. It was removed here for
// performance when the background was still a LIVE blur shader running
// every frame — animating a Transform on top of THAT was genuinely
// expensive (re-compositing a 20-22σ blur every frame). Now that
// _BlurredArtworkCore bakes the blur to a static bitmap once per song
// (see that class's own comment), a slow pan/zoom on top of the finished
// bitmap is just a single cheap GPU transform on an already-rasterized
// texture — the same category of cost as the drag-transform elsewhere in
// this file, not the blur shader's cost. Restoring it now matches Echo
// exactly while staying just as lightweight as the fully-static version
// was.
// REWRITE ("Echo Nightly jaisa ekdam same, background mein continuously
// run ho — pehle wala bilkul freeze tha"): the previous implementation
// drove this off an AnimationController that was created in initState
// and only ever started via .repeat(reverse: true) there or in resume().
// That controller lived on THIS State object, but this widget is given
// the same GlobalKey (kenBurnsKey) at every _BgLayer rebuild (_BgLayer
// itself rebuilds on every bgCtrl tick during a song-change color morph,
// and sits inside an AnimatedSwitcher keyed the same way) — a GlobalKey
// is only ever supposed to be attached to one live Element at a time,
// and reusing it across what's meant to be "the same" widget in
// different rebuild passes is exactly the situation Flutter's GlobalKey
// contract warns about corrupting: it can silently cause the framework
// to detach/reattach the Element (and therefore this State) instead of
// simply reusing it, which drops the ticker before it ever gets a
// visible frame — no crash, no error, it just never visibly moves.
// That's a fragile foundation for something that has to run forever in
// the background, so this drops the AnimationController entirely.
//
// EXACT MATCH to how Echo Nightly actually does this: Echo doesn't
// hand-roll any animation code for this at all (confirmed by reading
// its source — there is no Ken Burns controller anywhere in its Kotlin).
// It sets the blurred bitmap on a KenBurnsView and that third-party
// view's own internal Choreographer-driven loop starts automatically
// the moment it has an image, and keeps running for as long as the view
// is attached — no external controller to create, restart, or
// accidentally lose. This reproduces that exact model in Flutter: a
// single Ticker (not an AnimationController) that reads elapsed
// wall-clock time directly every frame and derives the pan/zoom from
// it. There's no .forward()/.repeat() call to forget, no "did the
// controller actually start" state to track, and — critically — no
// GlobalKey-driven Element churn can ever stop it, because the ticker
// isn't gated behind an initState-only kickoff: it starts the instant
// this State exists and runs every frame until disposed, full stop.
class _StaticBlurArtworkState extends State<_StaticBlurArtwork>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  // The Ticker's own callback arg restarts from zero every time .start()
  // is called (a fresh ticker "session"), so _elapsed is tracked here as
  // the running total instead — each session's ticks are added on top of
  // whatever had already accumulated, and stop() below folds the current
  // session into that total. This is what makes stop()/start() (pause/
  // resume, drag start/end, GlobalKey pause/resume — all of them) a pure
  // freeze-in-place with zero jump on resume: the very first tick of a
  // new session continues exactly from the last frame of the previous
  // one instead of the phase silently skipping forward by however long
  // the pause lasted.
  Duration _accumulated = Duration.zero;
  Duration _sessionElapsed = Duration.zero;

  // 18s round trip — same tempo as before/as the app's other ambient
  // motion — kept as a plain constant now that there's no
  // AnimationController duration to read it from.
  static const _cycle = Duration(seconds: 18);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    if (!widget.isDragging) _startTicker();
  }

  void _onTick(Duration sessionElapsed) {
    if (!mounted) return;
    setState(() => _sessionElapsed = sessionElapsed);
  }

  Duration get _currentElapsed => _accumulated + _sessionElapsed;

  void _startTicker() {
    _sessionElapsed = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    _ticker.stop();
    _accumulated += _sessionElapsed;
    _sessionElapsed = Duration.zero;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_StaticBlurArtwork old) {
    super.didUpdateWidget(old);
    // Pause/resume on drag start/end — same behavior as before, just
    // driven by starting/stopping the Ticker directly instead of an
    // AnimationController. Skipped if the parent already paused this
    // for a different reason (backgrounded/panel open) — that pause
    // should only be lifted by resume() below, not by the drag ending.
    if (widget.isDragging && !old.isDragging) {
      _stopTicker();
    } else if (!widget.isDragging && old.isDragging && !_pausedByParent) {
      _startTicker();
    }
  }

  // Reached via GlobalKey from _FullPlayerScreenState's
  // _pauseAmbientAnims/_resumeAmbientAnims — stops this ticker while the
  // app is backgrounded or the Up Next/Lyrics/Info panel is covering this
  // layer, so no GPU time is spent animating something nobody can see.
  bool _pausedByParent = false;

  void pause() {
    _pausedByParent = true;
    _stopTicker();
  }

  void resume() {
    if (!_pausedByParent) return;
    _pausedByParent = false;
    if (!widget.isDragging) _startTicker();
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: previously short-circuited to SizedBox.shrink() here when
    // song.artworkUrl was empty, which skipped this whole layer for local
    // songs with no embedded artwork — see the matching FIX comment in
    // _BlurredArtworkCore below for why that caused a flat white/cream
    // "layer" during swipe-to-dismiss. _BlurredArtworkCore now handles
    // the empty-artwork case itself (gradient placeholder instead of
    // nothing), so it's safe to always build it here too.
    // t: 0→1→0 continuous ping-pong derived straight from wall-clock
    // elapsed time (no controller value to be out of sync with) — this
    // is what actually guarantees it runs the instant the ticker is
    // ticking, with nothing else that could gate it off.
    final phase =
        (_currentElapsed.inMilliseconds % _cycle.inMilliseconds) /
            _cycle.inMilliseconds;
    final t = Curves.easeInOut.transform(
      phase < 0.5 ? phase * 2 : (1 - phase) * 2,
    );
    // Small, slow drift — a scale of 1.0→1.06 and a few px of pan,
    // same subtlety as Echo's own KenBurnsView defaults (a gentle
    // "the photo is quietly alive" feel, never a noticeable zoom).
    final scale = 1.0 + 0.06 * t;
    final dx = -6.0 + 12.0 * t;
    final dy = -4.0 + 8.0 * t;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..translate(dx, dy)
        ..scale(scale),
      child: RepaintBoundary(
        child: _BlurredArtworkCore(song: widget.song, isLight: widget.isLight),
      ),
    );
  }
}

// The actual blur render — split out from _StaticBlurArtwork so the Ken
// Burns Transform wrapper above can sit outside it without ever forcing
// this (expensive) subtree to rebuild. This widget itself is still only
// built once per song via the ValueKey at the call site.
//
// BATTERY FIX ("Echo Nightly jitna lightweight feel kyun nahi aata" — root
// cause): being built once per song (via ValueKey) only means the WIDGET
// TREE doesn't rebuild every frame — it never meant the GPU stopped
// working. ImageFiltered/ImageFilter.blur is a live shader: Flutter's
// compositor re-runs the actual Gaussian blur on every single composited
// frame this layer is on screen, for as long as the full player stays
// open, even though the artwork underneath is 100% unchanged the whole
// time. That's genuinely one of the most expensive things a mobile GPU can
// be asked to do continuously, and it's exactly what Echo Nightly does NOT
// do — its loadBlurred() (Coil's BlurTransformation) runs the blur exactly
// ONCE, off the render thread, produces a plain bitmap, and from then on
// it's just drawing a static image — zero ongoing shader cost, however
// long the screen stays open.
//
// This now reproduces that same one-time-bake approach in Flutter:
// _BlurredArtworkCore renders the expensive ImageFiltered subtree exactly
// once inside an offstage RepaintBoundary, captures it to a ui.Image via
// toImage() the instant it's painted, and from then on displays that
// captured bitmap with a plain RawImage — which costs Flutter nothing more
// than blitting a texture, the same as any normal photo. The blur shader
// itself now runs once per song instead of ~60 times/sec for the entire
// time the full player is open, which is the actual, structural fix for
// the battery/heaviness gap — not a tuning tweak.
class _BlurredArtworkCore extends StatefulWidget {
  final Song song;
  final bool isLight;

  const _BlurredArtworkCore({required this.song, required this.isLight});

  @override
  State<_BlurredArtworkCore> createState() => _BlurredArtworkCoreState();
}

class _BlurredArtworkCoreState extends State<_BlurredArtworkCore> {
  final GlobalKey _repaintKey = GlobalKey();
  ui.Image? _snapshot;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    // PERF FIX (low-end devices: full player's edges/bottom visibly take
    // an extra beat to "fill in" after opening, instead of being complete
    // from the first frame): toImage() below is a genuine GPU→CPU
    // readback — on a slow device it can itself take multiple frames to
    // complete, not the "effectively instant" it is on a fast one. Firing
    // it from the very first post-frame callback means that readback is
    // competing for the same frame budget as the route's own 380ms
    // slide-up transition AND every other widget's first layout/paint —
    // exactly the kind of contention that reads as "screen slowly
    // finishing filling itself in" on weaker hardware, even though
    // nothing is actually un-laid-out; it's a paint/GPU stall, not a
    // sizing bug. Delaying the first attempt past the transition's own
    // duration means the bake only starts once the route has visually
    // settled and stopped competing for frame time, so the live
    // ImageFiltered blur (already correctly sized/positioned from frame
    // one) simply stays on screen a little longer instead of stalling
    // everything else. The existing debugNeedsPaint retry loop below is
    // unchanged and still covers artwork that's slower to decode than
    // this delay.
    Future.delayed(const Duration(milliseconds: 420), () {
      if (mounted) _capture();
    });
  }

  @override
  void didUpdateWidget(_BlurredArtworkCore old) {
    super.didUpdateWidget(old);
    // New song (this widget is only rebuilt at all when the ValueKey at
    // the call site changes, i.e. a genuinely new song) — drop the old
    // bitmap and re-bake for the new artwork.
    if (old.song.id != widget.song.id ||
        old.song.artworkUrl != widget.song.artworkUrl) {
      _snapshot?.dispose();
      _snapshot = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    }
  }

  Future<void> _capture() async {
    if (_capturing || !mounted) return;
    _capturing = true;
    // One extra frame so AurumArtwork's own async decode (network/content://
    // /file, whichever this song uses) has actually painted something real
    // before the snapshot — capturing too early would just bake the
    // shimmer/placeholder in as a permanent "blurred" image for this song.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        // Not ready yet (artwork still decoding) — try again next frame
        // rather than baking in an incomplete/placeholder paint.
        _capturing = false;
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
        }
        return;
      }
      // devicePixelRatio 1.0 is deliberate: the source artwork is already
      // decoded at a small capped resolution (AurumArtwork._cacheSize) and
      // then heavily blurred — baking at full device pixel ratio would
      // capture detail the blur immediately destroys anyway, for several
      // times the memory and capture cost. This mirrors AurumArtwork's own
      // existing "why decode more than the blur can preserve" reasoning.
      final image = await boundary.toImage(pixelRatio: 1.0);
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() {
        _snapshot?.dispose();
        _snapshot = image;
      });
    } catch (_) {
      // Capture failures (e.g. zero-size boundary during a transient
      // layout pass) just mean this song keeps showing the live blur —
      // never worse than before this fix, never a crash.
    } finally {
      _capturing = false;
    }
  }

  @override
  void dispose() {
    _snapshot?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Empty-artwork case is already the cheapest possible paint (a flat
    // gradient, no image, no blur) — capturing/snapshotting it would only
    // add overhead for zero benefit, so this bypasses the whole bake
    // pipeline and always renders live (which costs nothing extra here).
    if (widget.song.artworkUrl.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: widget.isLight
                ? [const Color(0xFFDCD3C0), const Color(0xFFC9BCA0)]
                : [const Color(0xFF241F38), const Color(0xFF120F24)],
          ),
        ),
      );
    }
    final snapshot = _snapshot;
    return RepaintBoundary(
      child: ClipRect(
        // FIX ("bake complete hote hi ek chhota pop/flicker awkward lag
        // sakta hai"): switching from the live blur to the baked bitmap
        // is a genuine widget swap (different subtree entirely), and even
        // though both paint the same blurred artwork, a live shader vs a
        // rasterized bitmap can differ by a sub-pixel of softness — enough
        // to read as a faint pop on a hard cut, right at the one moment
        // this whole optimization is supposed to be invisible. A short
        // crossfade (same 220ms/easeOut used everywhere else artwork
        // fades in this app — AurumArtwork._FadeInImage) makes the
        // hand-off imperceptible instead of a snap, at effectively zero
        // extra cost since it only plays once per song, right after the
        // one-time bake.
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [
              ...previousChildren,
              if (currentChild != null) currentChild,
            ],
          ),
          child: snapshot != null
              // Post-bake: a plain static bitmap. No shader, no live filter —
              // this is exactly as cheap as drawing any other photo, no
              // matter how long the full player stays open.
              ? SizedBox.expand(
                  key: const ValueKey('baked'),
                  child: RawImage(image: snapshot, fit: BoxFit.cover),
                )
              // Pre-bake (first frame or first frame of a new song only):
              // the real live-blur subtree, wrapped in its own
              // RepaintBoundary so _capture() above can snapshot it. This
              // is the only moment the shader actually runs per song.
              : RepaintBoundary(
                  key: _repaintKey,
                  child: _LiveBlurArtwork(
                    song: widget.song,
                    isLight: widget.isLight,
                  ),
                ),
        ),
      ),
    );
  }
}

// The genuinely expensive subtree (Transform.scale 1.55x + 20-22σ blur
// shader) — isolated here so _BlurredArtworkCoreState above can capture it
// via its own RepaintBoundary and then never build it again for this song.
class _LiveBlurArtwork extends StatelessWidget {
  final Song song;
  final bool isLight;

  const _LiveBlurArtwork({required this.song, required this.isLight});

  @override
  Widget build(BuildContext context) {
    // NOTE: the empty-artwork short-circuit lives in
    // _BlurredArtworkCoreState.build() now (this widget is only ever
    // constructed once artworkUrl is known non-empty), so this subtree
    // can assume real artwork exists.
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
        // EXACT MATCH FIX: Echo Nightly's own bg_image (the KenBurnsView
        // holding the blurred artwork in fragment_player.xml) has no
        // alpha attribute at all — it's fully opaque (1.0). All of the
        // darkening/tinting look comes from the SEPARATE gradient_track
        // radial overlay drawn on top of it (already replicated by
        // _StaticTintVignettePainter below — see that class's own
        // comment confirming it targets the same footprint). Aurum's artwork layer was carrying its own
        // 0.88-0.90 opacity on top of that, effectively double-applying
        // the darkening the vignette layer already does correctly —
        // matching Echo's actual 1.0 here is both the literal exact
        // match and removes a redundant blend the vignette already
        // covers.
        child: Opacity(
          opacity: 1.0,
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

// EXACT MATCH ("Echo Nightly jaisa ekdam top grade — full animation ke
// saath, sab kuch clean"): Echo Nightly's own repeat/shuffle buttons
// (confirmed by reading PlayerFragment.kt) carry no backdrop, no glow,
// no underline mark at all — the entire "feel" comes from exactly one
// thing: on tap, the icon itself morphs via an AnimatedVectorDrawable
// (repeat ↔ repeat-one ↔ repeat-off, each a real path-morph animation
// baked into the drawable) instead of an instant swap. That's the whole
// design language: restrained everywhere except the one moment that
// matters (the tap), where the icon itself performs.
//
// Flutter has no AnimatedVectorDrawable equivalent, so this reproduces
// the same felt effect — the icon visibly transforming into its new
// shape, not just cross-fading — with a short combined rotate+scale-
// through on the MaterialIcon swap: the old icon shrinks/rotates away
// and the new one grows/rotates in from the opposite direction, timed
// tight enough (180ms) to read as one continuous morph rather than two
// separate fades. Every other bit of chrome from the previous pass
// (press-pulse backdrop, active-state underline bar) is removed — Echo
// has none of it, and this pass is about matching Echo exactly, not
// adding to it.
class _CtrlBtnState extends State<_CtrlBtn> {
  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? (widget.active ? AurumTheme.gold : widget.inactiveColor);

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      child: AurumPressable(
        scaleAmount: 0.85,
        haptic: false, // callers already fire their own haptic per action
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Center(
              child: AnimatedSwitcher(
                // Fast — a real tap-triggered morph, not a lingering
                // transition. Long enough to read as motion, short
                // enough that rapid re-tapping (spamming repeat mode
                // through its 3 states) never feels laggy.
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) {
                  // Incoming icon: rotates in from -45° while scaling
                  // up from 0.6 and fading in. Outgoing icon (the
                  // reverse animation on the child leaving the tree)
                  // gets the exact mirrored motion for free since
                  // AnimatedSwitcher runs the same transitionBuilder on
                  // both — together they read as one shape rotating
                  // through itself into the new one, the closest
                  // Flutter-native equivalent to a real vector path
                  // morph.
                  return FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1.0).animate(anim),
                      child: RotationTransition(
                        turns: Tween<double>(begin: -0.125, end: 0.0).animate(anim),
                        child: child,
                      ),
                    ),
                  );
                },
                // Keyed on icon shape + color together — unlike the
                // previous pass (which kept color animating separately
                // so pure activation didn't retrigger the switch), Echo
                // itself re-plays its icon animation on every tap
                // regardless of whether the shape changed (see
                // trackShuffle/trackRepeat's onClick in PlayerFragment.kt
                // — the Animatable always restarts) — matching that
                // means every tap gets the morph, every time, exactly
                // like Echo.
                child: Icon(
                  widget.icon,
                  key: ValueKey('${widget.icon}_${widget.active}'),
                  size: widget.size,
                  color: c,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

