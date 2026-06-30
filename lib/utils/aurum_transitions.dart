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
