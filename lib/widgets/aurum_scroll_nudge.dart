import 'package:flutter/material.dart';

/// AurumScrollNudge — Echo Nightly's scroll-reveal effect, ported.
///
/// Echo's ScrollAnimListAdapter/AnimationUtils.applyTranslationYAnimation
/// does this: ONE scroll listener on the whole list feeds the current
/// scroll delta (dy) to every visible item; each item nudges a few px
/// opposite the scroll direction and fades slightly, so tiles feel like
/// they're gently "catching up" into place as they enter the screen,
/// instead of just appearing. It's subtle (a handful of px), not a big
/// slide-in — that subtlety is exactly what reads as "smooth" rather than
/// "busy".
///
/// Why this stays lightweight/fast:
///   - ONE ScrollController listener drives a single ValueNotifier<double>,
///     shared by every card via AurumScrollDeltaScope — not one listener
///     per tile (which is what would actually cost something on a shelf
///     with a dozen cards).
///   - Each card only rebuilds the couple of pixels it needs to move —
///     a ValueListenableBuilder wrapping a cheap Transform.translate +
///     Opacity, no AnimationController, no ticker, nothing running when
///     the list is at rest.
///   - Values are clamped small (±6px, opacity 0.85–1.0 floor) so there's
///     never a jank-looking overshoot, matching Echo's own restrained
///     `RELATIVE_TO_SELF * 1.5f` amount.
class AurumScrollDeltaScope extends InheritedNotifier<ValueNotifier<double>> {
  const AurumScrollDeltaScope({
    super.key,
    required ValueNotifier<double> notifier,
    required super.child,
  }) : super(notifier: notifier);

  static ValueNotifier<double>? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AurumScrollDeltaScope>()
        ?.notifier;
  }
}

/// Attach this to the same ScrollController driving the list. Call
/// [attach] once (e.g. in initState) and [dispose] once (in dispose) —
/// cheap, no allocation on every scroll frame.
class AurumScrollDelta {
  final ValueNotifier<double> notifier = ValueNotifier<double>(0);
  ScrollController? _controller;
  double _lastPixels = 0;

  void attach(ScrollController controller) {
    _controller = controller;
    _lastPixels = controller.hasClients ? controller.position.pixels : 0;
    controller.addListener(_onScroll);
  }

  void _onScroll() {
    final c = _controller;
    if (c == null || !c.hasClients) return;
    final pixels = c.position.pixels;
    notifier.value = pixels - _lastPixels;
    _lastPixels = pixels;
  }

  void dispose() {
    _controller?.removeListener(_onScroll);
    notifier.dispose();
  }
}

/// Wrap an individual tile/card with this to get the Echo-style nudge.
/// Reads the shared delta from [AurumScrollDeltaScope] — falls back to a
/// static, unanimated child if no scope is present above it (never a
/// crash, just no effect).
class AurumScrollNudge extends StatelessWidget {
  final Widget child;
  const AurumScrollNudge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final notifier = AurumScrollDeltaScope.of(context);
    if (notifier == null) return child;
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: notifier,
        builder: (_, dy, cachedChild) {
          // Same "amount.sign" restraint as Echo — direction only, small
          // fixed magnitude, never proportional to raw fling speed (that
          // would make a fast fling look like items are being flung too,
          // which reads as chaotic rather than smooth).
          final dir = dy.sign;
          final offset = dir * 4.0; // px — Echo's own effect is similarly subtle
          final opacity = dy == 0 ? 1.0 : 0.92;
          return Transform.translate(
            offset: Offset(0, offset),
            child: Opacity(opacity: opacity, child: cachedChild),
          );
        },
        child: child,
      ),
    );
  }
}
