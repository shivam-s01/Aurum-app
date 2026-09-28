// ─────────────────────────────────────────────────────────────────────────────
// RouteDragDismiss — swipe-down-to-dismiss that is driven by the ROUTE'S OWN
// animation controller (the exact mechanism CupertinoPageRoute uses for its
// interactive back-swipe), instead of a second, separate translate layered
// on top of the route.
//
// Why this exists (root cause of "thumbnail alag neeche ja raha hai" and the
// janky swipe-down):
//   • The full player / queue are pushed with a PageRouteBuilder whose
//     transitionsBuilder is a SlideTransition (0,1)→(0,0).
//   • The old dismiss moved the screen with its OWN Transform.translate, and
//     when the drag ended it called Navigator.pop() — which then ran the
//     route's 380ms SlideTransition reverse AS WELL. Two independent motions
//     stacked (own translate + route slide), so content visibly "jumped",
//     lagged, or slid twice, and different pieces (thumbnail vs. the rest)
//     appeared to move separately.
//   • Here there is exactly ONE motion: the route's controller. The finger
//     sets controller.value directly (1.0 = fully open → 0.0 = gone), the
//     route's own SlideTransition renders it, and releasing simply lets the
//     SAME controller finish (forward = spring back, reverse = dismiss).
//     No second transform, no extra layer, no double animation, no jump.
//
// Uses only Flutter's public, stable API:
//   Navigator.didStartUserGesture / didStopUserGesture, ModalRoute.controller.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';

class RouteDragDismiss {
  RouteDragDismiss(this.context);

  final BuildContext context;

  NavigatorState? _nav;
  AnimationController? _ctrl;
  bool _active = false;
  bool _lockHeld = false; // Navigator user-gesture lock (start/stop paired)
  AnimationStatusListener? _pending;

  /// True while the finger (or the release animation) still owns the route.
  bool get isActive => _active;

  // Distance (px) that maps to controller 1.0 → 0.0: full screen height, so
  // the screen follows the finger exactly 1:1 like the SlideTransition.
  double get _extent => MediaQuery.of(context).size.height;

  double get dragPx => _ctrl == null ? 0.0 : (1.0 - _ctrl!.value) * _extent;

  bool start() {
    if (_active) {
      // Finger came back down during the spring-back: take over from the
      // current position (controller.value setter stops the animation).
      _dropPending();
      return true;
    }
    final route = ModalRoute.of(context);
    // `controller` is @protected on TransitionRoute; reading it here is the
    // same thing CupertinoPageRoute's back-swipe does internally, and is
    // the only way to drive the route's own animation with the finger.
    // ignore: invalid_use_of_protected_member
    final ctrl = route?.controller;
    final nav = Navigator.maybeOf(context);
    if (route == null ||
        ctrl == null ||
        nav == null ||
        !route.isCurrent ||
        ctrl.status == AnimationStatus.reverse ||
        ctrl.status == AnimationStatus.dismissed) {
      return false;
    }
    _nav = nav;
    _ctrl = ctrl;
    _active = true;
    _lockHeld = true;
    nav.didStartUserGesture();
    return true;
  }

  void update(double deltaDown) {
    final c = _ctrl;
    if (!_active || c == null) return;
    c.value = (c.value - deltaDown / _extent).clamp(0.0, 1.0);
  }

  void end({
    required double velocityPxPerSec,
    required double dismissDistance,
    required double dismissVelocity,
  }) {
    final c = _ctrl;
    final nav = _nav;
    if (!_active || c == null || nav == null) return;
    _dropPending();

    final draggedPx = dragPx;
    final dismiss = draggedPx > dismissDistance ||
        (draggedPx > 24.0 && velocityPxPerSec > dismissVelocity);

    // The lock is kept until the controller has fully settled, so the route
    // stays LINEAR (see routeDragCurve) for the whole release motion and
    // nothing jumps at the moment the finger lifts — same as Cupertino's
    // interactive back-swipe.
    void onStatus(AnimationStatus s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        c.removeStatusListener(onStatus);
        if (identical(_pending, onStatus)) _pending = null;
        _stopLock();
        if (!dismiss) _finish();
      }
    }

    if (dismiss) {
      // Navigator runs the route's reverse from the CURRENT value.
      _pending = onStatus;
      c.addStatusListener(onStatus);
      _finish(keepLock: true);
      nav.pop();
    } else {
      final flingV = -velocityPxPerSec / _extent; // + = toward open
      if (c.isCompleted) {
        _stopLock();
        _finish();
        return;
      }
      _pending = onStatus;
      c.addStatusListener(onStatus);
      if (flingV > 0.05) {
        c.fling(velocity: flingV);
      } else {
        c.animateTo(1.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic);
      }
    }
  }

  /// Route/State going away mid-gesture: never leave the lock held.
  void cancel() {
    _dropPending();
    final c = _ctrl;
    if (_active && c != null && !c.isCompleted &&
        c.status != AnimationStatus.reverse) {
      try {
        c.animateTo(1.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic);
      } catch (_) {}
    }
    _stopLock();
    _finish();
  }

  void _dropPending() {
    final l = _pending;
    if (l != null) {
      _ctrl?.removeStatusListener(l);
      _pending = null;
    }
  }

  void _stopLock() {
    if (!_lockHeld) return;
    _lockHeld = false;
    _nav?.didStopUserGesture();
  }

  void _finish({bool keepLock = false}) {
    _active = false;
    if (!keepLock) {
      _nav = null;
      _ctrl = null;
    }
  }
}

/// Drop-in replacement for `CurvedAnimation(curve: X)` in a route's
/// transitionsBuilder that makes the SAME animation:
///   • follow the finger 1:1 (linear) while a user gesture owns the route,
///   • use the normal [curve] for the regular open / close.
///
/// A plain easeOutCubic warps controller.value → position, so a finger-
/// driven slide would run ahead of / behind the finger (the "not stuck to
/// my finger" feel). This is the same trick CupertinoPageRoute uses for its
/// back-swipe (linear while the gesture is active, curved otherwise).
Animation<double> routeDragCurve(
  BuildContext context,
  Animation<double> parent, {
  Curve curve = Curves.easeOutCubic,
}) {
  final nav = Navigator.maybeOf(context);
  return CurvedAnimation(
    parent: parent,
    curve: _LinearWhileGesture(nav, curve),
  );
}

class _LinearWhileGesture extends Curve {
  const _LinearWhileGesture(this._nav, this._curve);
  final NavigatorState? _nav;
  final Curve _curve;

  @override
  double transformInternal(double t) =>
      (_nav?.userGestureInProgress ?? false) ? t : _curve.transform(t);
}
