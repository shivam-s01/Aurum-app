import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../services/audio_prefs.dart';
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

class _EdgeSwipeBackState extends State<_EdgeSwipeBack> {
  // Width of the draggable strip along the left edge, matching the narrow
  // "just the edge" feel Spotify uses rather than a whole-screen drag zone.
  static const double _edgeWidth = 24.0;
  double? _dragStartX;
  bool _dragging = false;

  bool get _enabled =>
      AudioPrefs.enableAnimationsNotifier.value && AudioPrefs.backAnimations;

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

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final navigator = Navigator.of(context);
    final velocity = details.velocity.pixelsPerSecond.dx;
    // Pop if the swipe carried past the halfway point OR was a fast enough
    // flick even from a shorter drag — mirrors how forgiving Spotify's own
    // gesture threshold feels rather than requiring a full deliberate drag.
    final shouldPop = widget.animationController.value < 0.6 || velocity > 600;
    if (shouldPop) {
      widget.animationController
          .animateBack(0.0,
              duration: AurumMotion.short2, curve: AurumMotion.standardReverse)
          .whenComplete(() {
        if (navigator.canPop()) navigator.pop();
      });
    } else {
      widget.animationController.animateTo(1.0,
          duration: AurumMotion.short2, curve: AurumMotion.standard);
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
              ..onEnd = _onDragEnd;
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
          transitionDuration: _animsOn()
              ? AurumMotion.long1
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

            // Outgoing screen gets a very subtle fade + scale-down so the
            // transition reads as one continuous motion, not two separate
            // animations stacked on top of each other.
            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: AurumMotion.standard,
            );

            final content = FadeTransition(
              opacity: curved,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.08, 0),
                  end: Offset.zero,
                ).animate(curved),
                child: FadeTransition(
                  opacity: Tween<double>(begin: 1.0, end: 0.96).animate(
                    secondaryCurved,
                  ),
                  child: child,
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
      AudioPrefs.enableAnimationsNotifier.value && AudioPrefs.backAnimations;

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

            return SlideTransition(
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
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(-0.06, 0),
                  ).animate(secondaryCurved),
                  child: FadeTransition(
                    opacity: Tween<double>(begin: 1.0, end: 0.92).animate(
                      secondaryCurved,
                    ),
                    child: child,
                  ),
                ),
              ),
            );
          },
        );

  static bool _animsOn() =>
      AudioPrefs.enableAnimationsNotifier.value && AudioPrefs.backAnimations;

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
          transitionDuration: AurumMotion.long1,
          reverseTransitionDuration: AurumMotion.medium2,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
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

  static Future<T?> to<T extends Object?>(BuildContext context, Widget screen) {
    return Navigator.of(context).push<T>(
      AurumModalRoute<T>(builder: (_) => screen),
    );
  }
}
