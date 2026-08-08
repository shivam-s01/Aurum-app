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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (!_enabled) return;
    if (details.globalPosition.dx > _edgeWidth) return;
    if (!Navigator.of(context).canPop()) return;
    _dragStartX = details.globalPosition.dx;
    _dragging = true;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final width = MediaQuery.of(context).size.width;
    if (width <= 0) return;
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
    final remaining = 1.0 - widget.animationController.value;
    final settleMs = (AurumMotion.long1.inMilliseconds * remaining)
        .clamp(80.0, AurumMotion.long1.inMilliseconds.toDouble())
        .round();
    widget.animationController.animateTo(1.0,
        duration: Duration(milliseconds: settleMs),
        curve: AurumMotion.standard);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final navigator = Navigator.of(context);
    final velocity = details.velocity.pixelsPerSecond.dx;
    // Pop if the swipe carried past the halfway point OR was a fast enough
    // flick even from a shorter drag — mirrors how forgiving Spotify's own
    // gesture threshold feels rather than requiring a full deliberate drag.
    final shouldPop = widget.animationController.value < 0.6 || velocity > 600;
    // FIX ("back feels stuck/not smooth"): this release-settle used to
    // always run at a fixed AurumMotion.short2 (150ms) — a different,
    // faster duration than the 350ms every other close path in the app
    // (tap-back, OS back gesture) uses. That mismatch is what made the
    // swipe-back specifically feel like it "catches" or snaps compared to
    // a normal back — not slow, just visibly a different speed/rhythm.
    // Scaling long1 (350ms, the same duration used everywhere else) by
    // how much of the drag is actually left to animate keeps the FEEL
    // (pixels-per-second) consistent with a full close, without making a
    // late release (already 80% of the way closed) crawl through a full
    // 350ms for the last 20% — the remaining motion still completes at
    // the same visual speed as the rest of the transition, just scaled to
    // however much of it is actually left.
    final remaining = shouldPop
        ? widget.animationController.value
        : (1.0 - widget.animationController.value);
    final settleMs = (AurumMotion.long1.inMilliseconds * remaining)
        .clamp(80.0, AurumMotion.long1.inMilliseconds.toDouble())
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

            // Outgoing screen gets a very subtle fade + scale-down so the
            // transition reads as one continuous motion, not two separate
            // animations stacked on top of each other.
            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: AurumMotion.standard,
            );

            // FIX ("almost every screen randomly gets a permanent gray
            // dim, no swipe/drag involved" — production bug): same class
            // of issue as AurumSlidePageRoute's matching fix just above —
            // secondaryAnimation drives this route's 0.96-opacity dim
            // while ANYTHING is pushed on top of it, which for
            // AurumPageRoute means basically every screen in the app
            // (it's the default push route). A fast/overlapping
            // navigation can leave secondaryAnimation stuck at a stale
            // non-zero value instead of settling to 0 on return, which
            // renders as a permanent faint dim with no drag needed to
            // reproduce — the _EdgeSwipeBack fixes above only cover the
            // manually-scrubbed drag controller, not this independent
            // Flutter-driven secondaryAnimation. Same fix: ignore
            // secondaryAnimation's raw value whenever ModalRoute.isCurrent
            // confirms this route is actually the active top of stack.
            final isTopRoute = ModalRoute.of(context)?.isCurrent ?? true;

            final content = ColoredBox(
              color: AurumTheme.bgOf(context),
              child: FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(curved),
                  child: FadeTransition(
                    opacity: isTopRoute
                        ? const AlwaysStoppedAnimation(1.0)
                        : Tween<double>(begin: 1.0, end: 0.96).animate(
                            secondaryCurved,
                          ),
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
  }) {
    return Navigator.of(context).push<T>(
      AurumPageRoute<T>(
        builder: (_) => screen,
        fullscreenDialog: fullscreenDialog,
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
