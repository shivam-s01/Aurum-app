import 'package:flutter/material.dart';
import '../services/audio_prefs.dart';

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
              ? const Duration(milliseconds: 400)
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? const Duration(milliseconds: 320)
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;

            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            // Outgoing screen gets a very subtle fade + scale-down so the
            // transition reads as one continuous motion, not two separate
            // animations stacked on top of each other.
            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.easeOutCubic,
            );

            return FadeTransition(
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
              ? const Duration(milliseconds: 400)
              : Duration.zero,
          reverseTransitionDuration: _animsOn()
              ? const Duration(milliseconds: 340)
              : Duration.zero,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            if (!_animsOn()) return child;

            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            final secondaryCurved = CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.easeOutCubic,
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
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
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
