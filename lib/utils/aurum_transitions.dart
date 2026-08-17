import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import 'aurum_motion.dart';

// ─────────────────────────────────────────────────────────────────────────────
// _EdgeSwipeBack — Spotify-style left-edge swipe-to-go-back
// • Only reacts to drags starting within a thin strip on the LEFT edge of
//   the screen (Spotify's own back-swipe zone is similarly narrow — a full
//   iOS-style "drag from anywhere" zone was explicitly ruled out).
// • Drives the route's own transitionAnimation controller directly as the
//   finger moves — 1px of drag = a precise fraction of the pop transition,
//   not a separate fade layered on top — so lifting the finger partway
//   through shows exactly the paused mid-transition frame, same as
//   Spotify/iOS. On release: fling forward to complete the pop if the drag
//   passed a threshold or had enough velocity, otherwise fling back to
//   fully-open with the same curve.
// • Reuses AurumMotion.standardReverse for the settle animations so a
//   swipe-back still feels like the same motion language as a tap-back.
// • Disabled automatically when it's the first route on the stack (nothing
//   to pop to) or when "Back Animations" is off, in which case the plain
//   OS back button / gesture still works via default Navigator behavior.
// ─────────────────────────────────────────────────────────────────────────────

class _EdgeSwipeBack extends StatefulWidget {
  const _EdgeSwipeBack({
    required this.animationController,
    required this.child,
  });

  final AnimationController animationController;
  final Widget child;

  @override
  State<_EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<_EdgeSwipeBack> with WidgetsBindingObserver {
  // Width of the draggable strip along the left edge, matching the narrow
  // "just the edge" feel Spotify uses rather than a whole-screen drag zone.
  static const double _edgeWidth = 24.0;
  double? _dragStartX;
  bool _dragging = false;

  // ROOT FIX (white/gray wash — can appear on ANY screen, not just
  // Shorts): every handler above (_onDragCancel, _onDragEnd,
  // didChangeAppLifecycleState, dispose) only resets the controller if
  // `_dragging` is still true when THAT handler fires. But
  // HorizontalDragGestureRecognizer can lose the gesture arena to a
  // competing vertical Scrollable/PageView (main app has plenty —
  // ListView, PageView, mini-player drag-up, etc.) in a way that fires
  // NONE of onEnd/onCancel/dispose/lifecycle on this recognizer at all —
  // the arena just silently reassigns the pointer to the winner. When
  // that happens, `_dragging` never flips back to false and
  // animationController.value can sit at whatever partial fraction the
  // first few pixels of drag reached, with no in-app signal left to
  // correct it. That stray value is what a downstream secondaryAnimation
  // consumer (any screen behind this route) paints as a permanent
  // translucent gray/white scrim, on any screen, without a full drag
  // ever completing.
  // Fix: don't rely solely on recognizer callbacks. Independently watch
  // every frame while `_dragging` is true; if the pointer stream goes
  // quiet (no update for longer than a real drag ever pauses) the arena
  // was silently lost — snap back to fully-open immediately, same as
  // the existing onCancel path.
  static const Duration _staleDragTimeout = Duration(milliseconds: 120);
  DateTime? _lastDragUpdate;

  void _watchdogTick(Duration _) {
    if (!_dragging || _lastDragUpdate == null) return;
    if (DateTime.now().difference(_lastDragUpdate!) > _staleDragTimeout) {
      _dragging = false;
      widget.animationController.value = 1.0;
      return;
    }
    WidgetsBinding.instance.scheduleFrameCallback(_watchdogTick);
  }

  // FIX: AudioPrefs.backAnimations is now a live ValueNotifier-backed
  // getter (was a plain static bool that only got read once at route
  // construction — see audio_prefs.dart), so this now always reflects
  // the current toggle state even for a route that was already pushed
  // before the setting changed.
  bool get _enabled =>
      AurumMotion.enabled && AudioPrefs.backAnimations;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // FIX ("offline song bajao, app background karo, wapas aao — screen
  // permanently dimmed/stuck, swipe-up kabhi kaam karta hai kabhi nahi"):
  // the onCancel fix above only covers the gesture ARENA taking the
  // pointer away mid-drag (a competing scroll/drag winning resolution).
  // It does NOT cover the app itself being backgrounded mid-drag — e.g.
  // the user's thumb is mid-swipe on the left edge exactly when they hit
  // Recents/home, or a local/downloaded song's playback notification or a
  // system dialog steals focus during the gesture. Android does not
  // guarantee onEnd or onCancel fires on the in-flight recognizer when the
  // Activity is paused this way — the pointer stream can simply stop
  // being delivered, leaving _dragging stuck true and
  // animationController.value frozen at whatever partial fraction the
  // drag had reached. That same controller drives the PREVIOUS route's
  // secondaryAnimation (the dim/parallax in AurumSlidePageRoute and
  // AurumPageRoute below) — so resuming shows that screen permanently
  // dimmed, and since the controller's value is stuck mid-range rather
  // than at a clean 0 or 1, gesture detection built on top of it (e.g.
  // whether a subsequent swipe-up opens the full player) becomes
  // inconsistent, matching the "kabhi kaam karta hai kabhi stuck" report.
  // This symptom skews toward local/offline playback simply because
  // that's when a user is most likely to background the app right after
  // starting a swipe (no network round-trip holding their attention on
  // the screen first) — it's not actually specific to local songs at the
  // code level, any mid-drag backgrounding triggers it.
  // Fix: observe app lifecycle here too, same as the dispose() safety net
  // already does for widget teardown — the instant the app is paused
  // (or detached) mid-drag, stop tracking the drag and snap the shared
  // controller back to fully-open immediately, no animation, no waiting
  // for a pointer event that may never arrive.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) &&
        _dragging) {
      _dragging = false;
      _lastDragUpdate = null;
      widget.animationController.value = 1.0;
    }
  }

  // Safety net alongside the onCancel fix above: if this widget itself
  // gets torn down mid-drag (route disposed from elsewhere, hot-reload,
  // etc.) with _dragging still true, don't leave the shared route
  // controller frozen at a partial value — snap it back to fully-open so
  // whatever screen reads it as secondaryAnimation is never left dimmed.
  @override
  void dispose() {
    if (_dragging) {
      widget.animationController.value = 1.0;
    }
    _dragging = false;
    _lastDragUpdate = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (!_enabled) return;
    if (details.globalPosition.dx > _edgeWidth) return;
    if (!Navigator.of(context).canPop()) return;
    _dragStartX = details.globalPosition.dx;
    _dragging = true;
    _lastDragUpdate = DateTime.now();
    // PERF (low-end/production): cache the screen width once at drag
    // start instead of re-reading MediaQuery.of(context).size.width on
    // every single onUpdate call (an InheritedWidget lookup that would
    // otherwise repeat 60+ times/sec for the whole drag — Echo Nightly's
    // native back gesture never re-queries layout mid-frame like this,
    // so this keeps the two feeling equally light on a slow device).
    // Width can't meaningfully change mid-drag (no rotation handling
    // needed here — a rotation cancels the gesture arena anyway).
    _dragWidth = MediaQuery.of(context).size.width;
    WidgetsBinding.instance.scheduleFrameCallback(_watchdogTick);
  }

  double? _dragWidth;

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    _lastDragUpdate = DateTime.now();
    final width = _dragWidth;
    if (width == null || width <= 0) return;
    // Controller runs 0 (fully pushed/visible) -> 1 (fully open, i.e. the
    // route's "entered" state); popping animates it back toward 0. Convert
    // horizontal drag distance directly into that same value so the
    // transitionsBuilder (which already knows how to render any value of
    // this controller) paints the exact right in-between frame per pixel.
    final dragFraction = (details.globalPosition.dx - _dragStartX!) / width;
    final newValue = (1.0 - dragFraction).clamp(0.0, 1.0);
    widget.animationController.value = newValue;
  }

  // FIX (Library/Albums screen stuck dimmed/off-position after navigating
  // back — "ye jata bhe na hai kabhi kabhi"): HorizontalDragGestureRecognizer
  // can lose an in-progress drag WITHOUT ever calling onEnd — e.g. a
  // vertical scroll or the mini player's own drag (_dragY) claims the
  // pointer via arena resolution mid-gesture. Previously only onEnd reset
  // `_dragging` and settled `animationController` back to 0 or 1. If the
  // gesture arena took the pointer away instead, _onDragEnd simply never
  // ran: animationController.value stayed frozen at whatever partial value
  // the finger last dragged to. Since that SAME controller drives the
  // previous route's secondaryAnimation (the 0.92 dim / -6% parallax in
  // AurumSlidePageRoute and the 0.96 dim in AurumPageRoute above), a
  // dropped drag left the screen behind permanently dimmed and shifted —
  // recoverable only by another route push/pop coincidentally resetting
  // the same controller. onCancel is the recognizer's explicit signal that
  // the gesture was taken away — settle exactly like a below-threshold
  // release (animate back to fully-open) whenever it fires.
  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _lastDragUpdate = null;
    final remaining = 1.0 - widget.animationController.value;
    // Matches AurumPageRoute's medium2 (280ms, "peak fast") speed —
    // was long1 (350ms), which made a cancelled swipe visibly slower to
    // settle than a normal tap-back after the push route's own speed
    // was bumped up.
    final settleMs = (AurumMotion.medium2.inMilliseconds * remaining)
        .clamp(80.0, AurumMotion.medium2.inMilliseconds.toDouble())
        .round();
    widget.animationController.animateTo(1.0,
        duration: Duration(milliseconds: settleMs),
        curve: AurumMotion.standard);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    _lastDragUpdate = null;
    final navigator = Navigator.of(context);
    final velocity = details.velocity.pixelsPerSecond.dx;
    // Pop if the swipe carried past the halfway point OR was a fast enough
    // flick even from a shorter drag — mirrors how forgiving Spotify's own
    // gesture threshold feels rather than requiring a full deliberate drag.
    final shouldPop = widget.animationController.value < 0.6 || velocity > 600;
    // Scales with medium2 (280ms, "peak fast" — matches AurumPageRoute's
    // updated push/pop speed, was long1/350ms) by how much of the drag is
    // actually left to animate, keeping the FEEL (pixels-per-second)
    // consistent with a full close, without making a late release
    // (already 80% of the way closed) crawl through the full duration for
    // the last 20% — the remaining motion still completes at the same
    // visual speed as the rest of the transition, just scaled to however
    // much of it is actually left.
    final remaining = shouldPop
        ? widget.animationController.value
        : (1.0 - widget.animationController.value);
    final settleMs = (AurumMotion.medium2.inMilliseconds * remaining)
        .clamp(80.0, AurumMotion.medium2.inMilliseconds.toDouble())
        .round();
    if (shouldPop) {
      widget.animationController
          .animateBack(0.0,
              duration: Duration(milliseconds: settleMs),
              curve: AurumMotion.standardReverse)
          .whenComplete(() {
        if (navigator.canPop()) navigator.pop();
      });
    } else {
      widget.animationController.animateTo(1.0,
          duration: Duration(milliseconds: settleMs),
          curve: AurumMotion.standard);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        HorizontalDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
          () => HorizontalDragGestureRecognizer(),
          (instance) {
            instance
              ..onStart = _onDragStart
              ..onUpdate = _onDragUpdate
              ..onEnd = _onDragEnd
              ..onCancel = _onDragCancel;
          },
        ),
      },
      behavior: HitTestBehavior.translucent,
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AurumPageRoute — Premium page transition
// • Fade (opacity 0 → 1) + Slide (8% from right → 0) combined
// • 400ms, Curves.easeOutCubic — matches the rest of Aurum's motion language
// • Drop-in replacement for MaterialPageRoute:
//
//     Navigator.push(context, MaterialPageRoute(builder: (_) => Screen()));
//   becomes:
//     Navigator.push(context, AurumPageRoute(builder: (_) => Screen()));
//
//   or even shorter:
//     AurumPageRoute.to(context, const Screen());
//
// • Reverse transition (on pop) automatically mirrors the same curve, so
//   back-navigation feels just as deliberate as forward navigation.
// • Respects Settings → Appearance → "Back Animations": when disabled,
//   collapses to an instant cut (no slide/fade) instead of skipping the
//   route entirely, so behavior stays correct even mid-toggle.
// • Wrapped with _EdgeSwipeBack so a left-edge swipe drives this same
//   transition frame-by-frame with the finger (Spotify-style), instead of
//   only supporting a tap-back or the plain OS back gesture.
// ─────────────────────────────────────────────────────────────────────────────

class AurumPageRoute<T> extends PageRouteBuilder<T> {
  AurumPageRoute({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
    // FIX (permanent gray/white wash on tap for vertical-paging screens):
    // the left-edge swipe-back gesture below runs a
    // HorizontalDragGestureRecognizer that competes in the same gesture
    // arena as any vertical PageView the pushed screen contains. A swipe
    // that isn't perfectly vertical lets this recognizer partially claim
    // the pointer; if it then loses the arena or the gesture otherwise
    // doesn't cleanly resolve, animationController.value can freeze at a
    // stray mid-range fraction instead of settling to 0/1 — that stuck
    // value is what painted as a permanent translucent gray/white scrim.
    // Screens whose primary gesture is itself horizontal or
    // vertical-paging should opt out of this wrapper entirely rather than
    // risk the arena conflict; give them their own explicit close (X)
    // button instead.
    bool enableEdgeSwipeBack = true,
  }) : super(
          settings: settings,
          fullscreenDialog: fullscreenDialog,
          opaque: true,
          // FIX ("back feels stuck/not smooth"): reverseTransitionDuration
          // used to be AurumMotion.medium2 (280ms) while the forward push
          // used long1 (350ms) — two different speeds for the same motion
          // depending on direction. That alone reads as slightly clipped on
          // the way back. It compounded with _EdgeSwipeBack below, whose
          // manual release-animation used a THIRD duration (short2, 150ms)
          // — so depending on whether you tapped back, used the OS back
          // gesture, or used Aurum's own edge-swipe, you'd get three
          // different close speeds. Unified to long1 everywhere so every
          // path back uses the exact same duration/curve as the push it's
          // reversing — back now always mirrors forward 1:1.
          // SPEED ("ekdam fast, peak experience" — was long1/350ms):
          // dropped to medium2 (280ms), the fastest tier that still reads
          // as a deliberate slide rather than a flicker/cut. iOS's own
          // push/pop sits in a similar ~300ms range — this is tuned to
          // feel snappy without being so fast the parallax reads as a
          // glitch. Kept identical forward/back so push and pop still
          // mirror each other 1:1.
          transitionDuration: _animsOn()
              ? AurumMotion.medium2
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? AurumMotion.medium2
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;

            final curved = CurvedAnimation(
              parent: animation,
              curve: AurumMotion.standard,
              reverseCurve: AurumMotion.standardReverse,
            );

            // FIX ("almost every screen randomly gets a permanent gray
            // dim, no swipe/drag involved" — production bug): same class
            // of issue as AurumSlidePageRoute's matching fix just above —
            // secondaryAnimation drives this route's dim/parallax while
            // ANYTHING is pushed on top of it, which for AurumPageRoute
            // means basically every screen in the app (it's the default
            // push route). A fast/overlapping navigation can leave
            // secondaryAnimation stuck at a stale non-zero value instead
            // of settling to 0 on return, which renders as a permanent
            // faint dim/shift with no drag needed to reproduce — the
            // _EdgeSwipeBack fixes above only cover the manually-scrubbed
            // drag controller, not this independent Flutter-driven
            // secondaryAnimation. Same fix: ignore secondaryAnimation's
            // raw value whenever ModalRoute.isCurrent confirms this
            // route is actually the active top of stack.
            final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;

            // PERF: only built when actually needed (something is pushed
            // on top of this route) — skips a CurvedAnimation listener
            // hookup on the overwhelmingly common case (this route IS the
            // top of the stack), which is every ordinary push/pop.
            //
            // iOS-style parallax back: the screen BEHIND the one being
            // popped doesn't sit static while the top one slides away —
            // it drifts in from a partial left offset too, so both
            // screens visibly move together, text and all, instead of
            // one screen sliding over a frozen backdrop.
            final secondaryCurved = isTopRoute
                ? null
                : CurvedAnimation(
                    parent: secondaryAnimation,
                    curve: AurumMotion.standard,
                  );

            final content = ColoredBox(
              color: AurumTheme.bgOf(context),
              // PERF ("lightweight, low-end, no junk feel"): dropped the
              // extra FadeTransition(opacity: AlwaysStoppedAnimation(1.0))
              // layer that used to sit here — an opacity-always-1.0
              // FadeTransition still allocates its own Opacity render
              // object + compositing layer every single animating frame
              // for zero visual difference from not having it at all.
              // Pure overhead on every push/pop. iOS's own push doesn't
              // fade the incoming screen anyway (see note below), so the
              // slide layer alone is both the correct look AND the
              // cheaper one — one less layer for low-end GPUs to
              // composite per frame.
              child: SlideTransition(
                // Genuine full slide-in from off-screen-right (1.0 → 0),
                // the actual iOS push/pop distance — the whole screen,
                // text included, visibly travels across instead of just
                // fading up near its resting position.
                position: Tween<Offset>(
                  begin: const Offset(1.0, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: SlideTransition(
                  // The screen being LEFT BEHIND: parallax-shifts in from
                  // a partial left offset (not fully static) so it
                  // visibly participates in the motion too, iOS-style —
                  // this is the "text ke saath back ho" fix. Settles to
                  // fully-in-place once this becomes the top route again.
                  //
                  // PERF: skips building a Tween/Animation object at all
                  // (not just skipping the visual offset) when this is
                  // the top route — AlwaysStoppedAnimation is effectively
                  // free, whereas a live Tween+CurvedAnimation still costs
                  // a listener + rebuild hookup even when its start and
                  // end values happen to be equal.
                  position: isTopRoute
                      ? const AlwaysStoppedAnimation(Offset.zero)
                      : Tween<Offset>(
                          begin: Offset.zero,
                          end: const Offset(-0.30, 0),
                        ).animate(secondaryCurved!),
                  child: isTopRoute
                      ? child
                      : FadeTransition(
                          opacity: Tween<double>(begin: 1.0, end: 0.85)
                              .animate(secondaryCurved!),
                          child: child,
                        ),
                ),
              ),
            );

            // The route's own AnimationController (ModalRoute.controller)
            // drives `animation` above 1:1 — grabbing it here (rather than
            // the proxy `animation` param, which isn't itself a settable
            // AnimationController) is what lets _EdgeSwipeBack scrub the
            // transition frame-by-frame as the finger drags.
            final routeController = ModalRoute.of(context)?.controller;
            if (routeController == null) return content;
            if (!enableEdgeSwipeBack) return content;
            return _EdgeSwipeBack(
              animationController: routeController,
              child: content,
            );
          },
        );


  // "Enable Animations" (master) AND "Back Animations" must both be on.
  static bool _animsOn() =>
      AurumMotion.enabled && AudioPrefs.backAnimations;

  /// Shortest path: AurumPageRoute.to(context, const SomeScreen());
  static Future<T?> to<T extends Object?>(
    BuildContext context,
    Widget screen, {
    bool fullscreenDialog = false,
    bool enableEdgeSwipeBack = true,
  }) {
    return Navigator.of(context).push<T>(
      AurumPageRoute<T>(
        builder: (_) => screen,
        fullscreenDialog: fullscreenDialog,
        enableEdgeSwipeBack: enableEdgeSwipeBack,
      ),
    );
  }

  /// Replace current route — useful for login → home style transitions
  /// where you don't want the previous screen left on the back stack.
  static Future<T?> replace<T extends Object?, TO extends Object?>(
    BuildContext context,
    Widget screen,
  ) {
    return Navigator.of(context).pushReplacement<T, TO>(
      AurumPageRoute<T>(builder: (_) => screen),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AurumSlidePageRoute — Premium full-slide page transition
// Used specifically for the Library "Collection" cards (Liked Songs,
// Playlists, Albums, Artists, Local Files) so opening them reads as a
// confident, top-level "new section" push — a fuller right-to-left slide
// than AurumPageRoute's subtle 8% nudge, closer to what a paid streaming
// app's library section-open feels like.
//
// Deliberately kept separate from AurumPageRoute (rather than changing it)
// so every other navigation in the app keeps its existing motion — this
// only swaps in where explicitly used.
//
// • Incoming screen: slides in fully from the right edge (100% → 0) with a
//   simultaneous fade-in, so it never looks like it's dragging in "empty"
//   before content appears.
// • Outgoing screen: parallax-shifts slightly left and dims a touch,
//   reinforcing a physical sense of depth (like one card sliding over
//   another) without adding any extra widgets or overdraw — still just two
//   Transforms + a fade, so it stays lightweight on lower-end devices.
// • Same 400ms / easeOutCubic motion language and "Back Animations" toggle
//   respect as AurumPageRoute, so it never feels like a different app when
//   animations are globally disabled.
// ─────────────────────────────────────────────────────────────────────────────

class AurumSlidePageRoute<T> extends PageRouteBuilder<T> {
  AurumSlidePageRoute({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) : super(
          settings: settings,
          fullscreenDialog: fullscreenDialog,
          opaque: true,
          transitionDuration: _animsOn()
              ? AurumMotion.long1
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? AurumMotion.long1
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;

            final curved = CurvedAnimation(
              parent: animation,
              curve: AurumMotion.standard,
              reverseCurve: AurumMotion.standardReverse,
            );
            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: AurumMotion.standard,
            );

            // FIX ("Library/Playlists/Albums screen stuck permanently
            // dimmed/gray-washed, random screens, no drag involved" —
            // production bug): secondaryAnimation here drives the -6%
            // parallax + 0.92 dim applied to THIS route while something
            // is pushed on top of it (e.g. a song tile inside Playlists/
            // Albums/Local Files opening FullPlayerScreen via
            // pushFullPlayer). Unlike AurumPageRoute, nothing here
            // manually scrubs an AnimationController by hand — this is
            // pure Flutter-driven route animation — but a fast/overlapping
            // navigation (double-tap racing pushFullPlayer's own guard
            // reset, or FullPlayerScreen's pop not fully completing its
            // reverse transition before another push/pop lands) can still
            // leave secondaryAnimation holding a stale non-zero value
            // instead of settling back to 0 when this route becomes the
            // active top of the stack again. Trusting that raw value
            // blindly is what let a stuck mid-value silently render as a
            // permanent gray wash with no drag or gesture needed to
            // trigger it. ModalRoute.isCurrent is ground truth for
            // whether this route is actually the one the user is looking
            // at right now — whenever it is, force full brightness/no-
            // parallax regardless of whatever secondaryAnimation's raw
            // value currently claims, so a stale value can never paint.
            final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;

            return ColoredBox(
              color: AurumTheme.bgOf(context),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1.0, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    // Outgoing screen drifts left ~6% and dims — a light
                    // parallax cue that the new screen is arriving "on top",
                    // not just cross-fading in place.
                    position: isTopRoute
                        ? const AlwaysStoppedAnimation(Offset.zero)
                        : Tween<Offset>(
                            begin: Offset.zero,
                            end: const Offset(-0.06, 0),
                          ).animate(secondaryCurved),
                    child: FadeTransition(
                      opacity: isTopRoute
                          ? const AlwaysStoppedAnimation(1.0)
                          : Tween<double>(begin: 1.0, end: 0.92).animate(
                              secondaryCurved,
                            ),
                      child: child,
                    ),
                  ),
                ),
              ),
            );
          },
        );

  static bool _animsOn() =>
      AurumMotion.enabled && AudioPrefs.backAnimations;

  /// AurumSlidePageRoute.to(context, const SomeScreen());
  static Future<T?> to<T extends Object?>(
    BuildContext context,
    Widget screen, {
    bool fullscreenDialog = false,
  }) {
    return Navigator.of(context).push<T>(
      AurumSlidePageRoute<T>(
        builder: (_) => screen,
        fullscreenDialog: fullscreenDialog,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AurumModalRoute — for bottom-sheet-style full screens (paywall, song info)
// that should rise up from the bottom instead of sliding from the right.
// Same 400ms / easeOutCubic motion language, different axis.
// ─────────────────────────────────────────────────────────────────────────────

class AurumModalRoute<T> extends PageRouteBuilder<T> {
  AurumModalRoute({
    required WidgetBuilder builder,
    RouteSettings? settings,
  }) : super(
          settings: settings,
          opaque: true,
          // FIX: this route ignored the "Back Animations" setting
          // entirely — AurumPageRoute and AurumSlidePageRoute both
          // collapse to Duration.zero (instant, no slide/fade) when the
          // setting is off, but this one was hardcoded to always animate
          // at long1. With animations off, most of the app would jump
          // instantly while paywall/song-info screens kept sliding in —
          // a visible inconsistency even to someone who's never seen
          // this file. Same _animsOn() check as the other two routes.
          transitionDuration: _animsOn()
              ? AurumMotion.long1
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? AurumMotion.long1
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;
            final curved = CurvedAnimation(
              parent: animation,
              curve: AurumMotion.standard,
              reverseCurve: AurumMotion.standardReverse,
            );
            return FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            );
          },
        );

  // Same "Enable Animations" (master) AND "Back Animations" gate as
  // AurumPageRoute/AurumSlidePageRoute.
  static bool _animsOn() =>
      AurumMotion.enabled && AudioPrefs.backAnimations;

  static Future<T?> to<T extends Object?>(BuildContext context, Widget screen) {
    return Navigator.of(context).push<T>(
      AurumModalRoute<T>(builder: (_) => screen),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AurumDepthRoute — Echo-Nightly-exact port of Material Design's
// MaterialSharedAxis (Z-axis) transition, used by Echo for every
// content-drilldown push (Home row → Mix/Album/Playlist detail, etc. —
// see MediaFragment.kt's `setupTransition(view)`, which defaults to
// MaterialSharedAxis.Z). Echo's Home↔Search↔Library TAB switches use the
// Y axis (a completely different, subtler transition) — this route is
// specifically for the "I tapped into a piece of content and want to see
// more about it" navigation, which is where AurumPageRoute's full
// right-to-left slide previously felt like a jarring full-context-switch
// (aakward) compared to Echo's much more connected "this same content
// is growing into a detail view" depth feel.
//
// EXACT MATERIAL SHARED-AXIS Z SPEC (matches Echo's MDC values 1:1, not
// an approximation):
//   • Outgoing content: fades out over the first 100ms, scales UP from
//     100% to 110% over the full 300ms.
//   • Incoming content: fades in during the following 200ms (i.e. starts
//     at the 100ms mark, once the outgoing fade finishes), scales UP
//     from 80% to 100% over the full 300ms.
//   • Total duration 300ms (Echo's own `motionDurationMedium1`, resolved
//     via MotionUtils with a 350ms fallback — 300ms is MDC's own
//     documented default for this pattern and what Echo's theme
//     actually resolves to on Material3).
//   • fastOutSlowIn-equivalent easing throughout (Curves.easeOutCubic is
//     Aurum's existing standard curve and reads near-identically).
//
// PERF: same shape as AurumPageRoute — one Tween-driven AnimatedBuilder,
// no per-frame layout queries, respects "Back Animations" the same way,
// collapses to an instant cut when animations are off.
// ─────────────────────────────────────────────────────────────────────────────

class AurumDepthRoute<T> extends PageRouteBuilder<T> {
  AurumDepthRoute({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) : super(
          settings: settings,
          fullscreenDialog: fullscreenDialog,
          // BUG FIX ("cold start pe koi bhi tile pe click karo, poori
          // screen white flash 0.3-4 sec"): this was `opaque: true`.
          // opaque:true tells Flutter/Navigator that nothing behind this
          // route can ever be visible, so it's free to stop actively
          // compositing the previous route's real content underneath
          // during the transition — it can leave that layer un-painted
          // and just show whatever default background exists there
          // instead. That's invisible in the steady state (this route's
          // own incoming content covers everything once painted), but
          // for the FIRST 100ms of every push, incomingFade sits at
          // opacity 0 by design (exact MaterialSharedAxis.Z spec — see
          // the Interval(1/3, 1.0, ...) below), so for that entire
          // window there is genuinely nothing opaque on screen yet. With
          // opaque:true, Flutter has no obligation to keep the outgoing
          // route's real frame live behind that gap — on a cold start,
          // before every screen in the stack has painted at least one
          // real frame of its own themed content, what's left showing
          // through is Flutter's raw engine-level clear color, which is
          // white by default. That's the reported flash — worst on cold
          // start (nothing has painted a dark frame yet to fall back to)
          // and totally absent on a warm re-open (the previous screen's
          // last real frame is still sitting there, opaque:true or not).
          // opaque:false removes the ambiguity entirely: it tells
          // Flutter the previous route MUST keep being actively
          // rendered underneath for the whole transition, exactly the
          // same fix already applied to pushFullPlayer's own
          // PageRouteBuilder in home_screen.dart for this identical
          // class of bug (see that opaque:false comment for the parallel
          // reasoning) — there is then always real, already-themed
          // content behind the fade instead of an engine-default clear
          // color, cold start or not.
          opaque: false,
          transitionDuration: _animsOn()
              ? const Duration(milliseconds: 300)
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? const Duration(milliseconds: 300)
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;

            // PERF: only build the Tween/CurvedAnimation objects this
            // frame's branch actually needs — computing both the
            // incoming AND outgoing set unconditionally (then discarding
            // whichever one isTopRoute didn't pick) allocated two unused
            // Animation objects on every single transition frame for
            // whichever route is currently in the background.
            final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;

            final Widget content;
            if (isTopRoute) {
              // Incoming (this route): fade in from the 100ms mark
              // through 300ms (the back 2/3 of the timeline), scale
              // 0.80→1.0 across the full timeline — exact
              // MaterialSharedAxis.Z "entering" values. Reverse (pop,
              // this route sliding back out) mirrors the same interval
              // so a tap-back looks like the exact time-reverse of the
              // push, not a different curve.
              final incomingFade = CurvedAnimation(
                parent: animation,
                curve: const Interval(1 / 3, 1.0, curve: Curves.easeOutCubic),
                reverseCurve:
                    const Interval(1 / 3, 1.0, curve: Curves.easeInCubic),
              );
              final incomingScale = Tween<double>(begin: 0.80, end: 1.0)
                  .animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                ),
              );
              content = FadeTransition(
                opacity: incomingFade,
                child: ScaleTransition(
                  scale: incomingScale,
                  child: child,
                ),
              );
            } else {
              // Something is pushed on top of this route right now —
              // apply only the outgoing fade+scale (this route already
              // finished its own incoming animation long ago). Fade out
              // over the FIRST 100ms only, scale 1.0→1.10 across the
              // full timeline — exact MaterialSharedAxis.Z "exiting"
              // values, mirroring the isTopRoute guard already used by
              // AurumPageRoute/AurumSlidePageRoute for the same
              // stale-secondaryAnimation safety.
              final outgoingFade = Tween<double>(begin: 1.0, end: 0.0)
                  .animate(
                CurvedAnimation(
                  parent: secondaryAnimation,
                  curve: const Interval(0.0, 1 / 3, curve: Curves.easeInCubic),
                ),
              );
              final outgoingScale = Tween<double>(begin: 1.0, end: 1.10)
                  .animate(
                CurvedAnimation(
                  parent: secondaryAnimation,
                  curve: Curves.easeInCubic,
                ),
              );
              content = FadeTransition(
                opacity: outgoingFade,
                child: ScaleTransition(
                  scale: outgoingScale,
                  child: child,
                ),
              );
            }

            // BUG FIX ("Playlist for You mix pe click karo to black flash
            // aata hai"): this used to wrap both branches in an opaque
            // ColoredBox(color: AurumTheme.bgOf(context)) backdrop.
            // During a push, the incoming route's own fade only starts
            // at the 1/3 mark of the timeline (exact MaterialSharedAxis.Z
            // spec — see the incomingFade Interval above), so for the
            // first 100ms the incoming content sits at opacity 0 — with
            // that opaque backdrop behind it, all that was visible for
            // those 100ms was a flat frame of the theme's background
            // color and nothing else, reading as a "black flash" on any
            // dark theme. Real Shared-Axis-Z transitions rely on the
            // OUTGOING route staying visible underneath the whole time
            // (only its own opacity/scale animate) — never an opaque
            // filler behind both routes. Returning `content` directly
            // (PageRouteBuilder's own transition Stack already composites
            // this route over whatever's beneath it) lets the previous
            // screen's real content show through for that entire handoff
            // window, exactly like Echo's own MDC transition, instead of
            // a blank color filling the gap.
            return content;
          },
        );

  static bool _animsOn() =>
      AurumMotion.enabled && AudioPrefs.backAnimations;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final content = super.buildTransitions(
        context, animation, secondaryAnimation, child);
    if (!_animsOn()) return content;
    final routeController = controller;
    if (routeController == null) return content;
    return _EdgeSwipeBack(
      animationController: routeController,
      child: content,
    );
  }

  /// AurumDepthRoute.to(context, const MixScreen(...));
  static Future<T?> to<T extends Object?>(
    BuildContext context,
    Widget screen, {
    bool fullscreenDialog = false,
  }) {
    return Navigator.of(context).push<T>(
      AurumDepthRoute<T>(
        builder: (_) => screen,
        fullscreenDialog: fullscreenDialog,
      ),
    );
  }
}
