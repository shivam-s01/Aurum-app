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

// ─────────────────────────────────────────────────────────────────────────────
// PullDownDismiss — the FINGER side of RouteDragDismiss.
//
// ROOT CAUSE of "swipe down pe thumbnail alag neeche ja raha hai, full player
// nahi" (Spotify full player + Up Next / Queue):
//   The old code used a GestureDetector(onVerticalDrag…) ABOVE the
//   SingleChildScrollView / CustomScrollView. In Flutter's gesture arena the
//   DEEPEST vertical recognizer wins, i.e. the scroll view's own — so the
//   parent's drag callbacks never fired. The scroll view (BouncingScrollPhysics)
//   just over-scrolled at offset 0 and pushed its content (artwork) down while
//   the header stayed put. That is exactly the "thumbnail alone moves" bug.
//
// FIX: (1) a raw Listener — pointer events do NOT enter the gesture arena, so
//   nobody can steal them; (2) top-clamped scroll physics so the list can
//   never over-scroll/stretch at the top; (3) while the route is being pulled
//   the list is locked, so the finger moves ONE thing only: the whole route
//   (RouteDragDismiss → the route's own controller → SlideTransition).
// ─────────────────────────────────────────────────────────────────────────────

/// Clamping physics (no top/bottom bounce, so the content can never move on
/// its own when pulled down) that can be locked while a route-pull is active.
class PullDismissScrollPhysics extends ClampingScrollPhysics {
  const PullDismissScrollPhysics({required this.isLocked, super.parent});

  final bool Function() isLocked;

  @override
  PullDismissScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      PullDismissScrollPhysics(
          isLocked: isLocked, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      isLocked() ? 0.0 : super.applyPhysicsToUserOffset(position, offset);
}

class PullDownDismissController {
  PullDownDismissController() {
    physics = PullDismissScrollPhysics(
      isLocked: () => active,
      parent: const AlwaysScrollableScrollPhysics(),
    );
  }

  /// True while the finger owns the route (list is locked meanwhile).
  bool active = false;

  /// Give this to the screen's scroll view: `physics: _pull.physics`.
  late final ScrollPhysics physics;
}

class PullDownDismiss extends StatefulWidget {
  const PullDownDismiss({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.child,
    this.dismissDistance = 120.0,
    this.dismissVelocity = 900.0,
  });

  final PullDownDismissController controller;
  final ScrollController scrollController;
  final Widget child;
  final double dismissDistance;
  final double dismissVelocity;

  /// A child (e.g. a drag-to-reorder handle) can call this from its own
  /// Listener.onPointerDown — it fires BEFORE this widget's Listener — to say
  /// "this pointer is mine, never treat it as a route pull".
  static int ignorePointer = -1;

  @override
  State<PullDownDismiss> createState() => _PullDownDismissState();
}

class _PullDownDismissState extends State<PullDownDismiss> {
  late final RouteDragDismiss _dismiss;
  VelocityTracker? _tracker;
  int _pointer = -1;
  bool _ignored = false;
  bool _dead = false;
  double _ax = 0; // accumulated horizontal travel
  double _ay = 0; // accumulated downward travel (while at top)

  static const double _slop = 8.0;

  @override
  void initState() {
    super.initState();
    _dismiss = RouteDragDismiss(context);
  }

  @override
  void dispose() {
    _dismiss.cancel();
    widget.controller.active = false;
    super.dispose();
  }

  bool get _atTop {
    final sc = widget.scrollController;
    return !sc.hasClients ||
        sc.position.pixels <= sc.position.minScrollExtent + 0.5;
  }

  void _reset() {
    _pointer = -1;
    _tracker = null;
    _ignored = false;
    _dead = false;
    _ax = 0;
    _ay = 0;
  }

  void _down(PointerDownEvent e) {
    if (_pointer != -1) return; // single-finger only
    _reset();
    _pointer = e.pointer;
    _ignored = PullDownDismiss.ignorePointer == e.pointer;
    _tracker = VelocityTracker.withKind(e.kind)
      ..addPosition(e.timeStamp, e.position);
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer || _ignored) return;
    _tracker?.addPosition(e.timeStamp, e.position);
    final dy = e.delta.dy;

    if (_dismiss.isActive) {
      // Also covers grabbing the screen again during the spring-back.
      widget.controller.active = true;
      _dismiss.update(dy);
      return;
    }
    if (_dead) return;

    _ax += e.delta.dx.abs();
    if (!_atTop || dy < 0) {
      // Normal list scrolling (or an upward move): nothing to dismiss.
      _ay = 0;
      return;
    }
    _ay += dy;
    if (_ax > 18 && _ax > _ay) {
      _dead = true; // mostly horizontal (seekbar etc.)
      return;
    }
    if (_ay >= _slop && _ay > _ax * 1.5) {
      if (!_dismiss.start()) {
        _dead = true;
        return;
      }
      widget.controller.active = true;
      _dismiss.update(_ay);
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    if (_dismiss.isActive) {
      final v = _tracker?.getVelocity().pixelsPerSecond.dy ?? 0.0;
      _dismiss.end(
        velocityPxPerSec: v,
        dismissDistance: widget.dismissDistance,
        dismissVelocity: widget.dismissVelocity,
      );
    }
    widget.controller.active = false;
    _reset();
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    if (_dismiss.isActive) _dismiss.cancel();
    widget.controller.active = false;
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      // No stretch / glow overscroll effect either — that effect also
      // visually drags the artwork on its own.
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(overscroll: false),
        child: widget.child,
      ),
    );
  }
}
