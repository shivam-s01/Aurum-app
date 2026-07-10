// aurum_morph_loader.dart
// Aurum Music — M3 Expressive "Shape-Morphing" Loading Indicator
// Replicates the Google Play Store style circular loader: a single solid
// blob that continuously morphs between rounded-polygon shapes
// (circle -> squircle -> cookie/flower -> triangle -> circle...) while
// slowly rotating. Drop-in icon-sized spinner.
//
// Usage:
//   const AurumMorphLoader()              // 40px, default Google blue
//   const AurumMorphLoader(size: 28)
//   const AurumMorphLoader(color: Colors.amber)
//
// To use everywhere AurumM3Spinner was used, you can either:
//   - replace AurumM3Spinner(...) call sites with AurumMorphLoader(size: ...)
//   - or leave AurumM3Spinner alone and just use AurumMorphLoader directly
//     wherever you want this exact morph-blob look.

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';

/// Fallback color — only used if no ThemeProvider is reachable in the
/// widget tree (should basically never happen in normal app usage).
const Color kAurumMorphBlue = Color(0xFFA855F7); // Aurum purple (fallback only)

class AurumMorphLoader extends StatefulWidget {
  const AurumMorphLoader({
    super.key,
    this.size = 40.0,
    this.color,
    this.morphDuration = const Duration(milliseconds: 650),
    this.rotateDuration = const Duration(milliseconds: 4000),
  });

  /// Bounding box size (square) the blob is drawn in.
  final double size;

  /// Solid fill color of the blob. If null (the common case — nearly
  /// every call site in the app omits this), the loader reads the user's
  /// live accent color from ThemeProvider — the SAME color the nav bar
  /// and Settings → Appearance accent picker use. This is the fix for
  /// "loading spinner is a fixed purple/pink that doesn't match my chosen
  /// theme/accent color": previously this always fell back to a hardcoded
  /// constant (kAurumMorphBlue) no matter what accent the user picked in
  /// Settings, so every loading blob across the app (Home, Search, Liked,
  /// full player buffering, artist/album loading, etc.) stayed a fixed
  /// purple regardless of the premium accent color actually selected.
  final Color? color;

  /// How long one shape-to-shape morph takes.
  final Duration morphDuration;

  /// How long one full 360° rotation takes.
  final Duration rotateDuration;

  @override
  State<AurumMorphLoader> createState() => _AurumMorphLoaderState();
}

class _AurumMorphLoaderState extends State<AurumMorphLoader>
    with TickerProviderStateMixin {
  late final AnimationController _morphCtrl;
  late final AnimationController _rotateCtrl;

  // Keyframe shapes the blob cycles through, matching the M3 Expressive
  // "MaterialShapes" loading-indicator sequence: circle -> 4-sided cookie
  // (squircle-ish) -> sunny/flower (8-point) -> triangle (3-sided rounded)
  // -> back to circle.
  late final List<_PolygonSpec> _shapes;
  int _shapeIndex = 0;

  @override
  void initState() {
    super.initState();

    _shapes = [
      _PolygonSpec.circle(),
      _PolygonSpec(sides: 4, corner: 0.30, amplitude: 0.10), // squircle/cookie4
      _PolygonSpec(sides: 8, corner: 0.45, amplitude: 0.22), // flower / sunny
      _PolygonSpec(sides: 3, corner: 0.55, amplitude: 0.20), // rounded triangle
      _PolygonSpec(sides: 6, corner: 0.40, amplitude: 0.14), // cookie6
    ];

    _morphCtrl = AnimationController(vsync: this, duration: widget.morphDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          setState(() => _shapeIndex = (_shapeIndex + 1) % _shapes.length);
          _morphCtrl
            ..reset()
            ..forward();
        }
      })
      ..forward();

    _rotateCtrl = AnimationController(vsync: this, duration: widget.rotateDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _morphCtrl.dispose();
    _rotateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final from = _shapes[_shapeIndex];
    final to = _shapes[(_shapeIndex + 1) % _shapes.length];

    // Resolve the paint color once per build: explicit widget.color wins
    // if given (e.g. a caller intentionally wants a fixed color for some
    // specific UI moment); otherwise read the live user accent color —
    // same source the nav bar and Settings → Appearance picker use — so
    // this spinner always matches whatever accent the user has chosen,
    // instead of a fixed purple/pink.
    final resolvedColor = widget.color ??
        (context.select<ThemeProvider, Color>((tp) => tp.accentColor));

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: Listenable.merge([_morphCtrl, _rotateCtrl]),
          builder: (_, __) {
            final morphT = Curves.easeInOutCubic.transform(_morphCtrl.value);
            final rotation = _rotateCtrl.value * 2 * math.pi;
            return CustomPaint(
              painter: _MorphPainter(
                from: from,
                to: to,
                t: morphT,
                rotation: rotation,
                color: resolvedColor,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Describes one keyframe shape as a radial function: a base circle whose
/// radius is perturbed by `amplitude` using a `sides`-fold cosine ripple,
/// with `corner` controlling how soft/sharp the resulting lobes feel
/// (approximated via the cosine power).
class _PolygonSpec {
  const _PolygonSpec({
    required this.sides,
    required this.corner,
    required this.amplitude,
  });

  factory _PolygonSpec.circle() =>
      const _PolygonSpec(sides: 0, corner: 1.0, amplitude: 0.0);

  final int sides;       // ripple frequency (0 = perfect circle)
  final double corner;   // 0..1 roundedness softening applied to the ripple
  final double amplitude; // 0..~0.3 how far the lobes push out/in

  /// Returns the normalized radius (0..1ish) at angle [theta].
  double radiusAt(double theta) {
    if (sides == 0) return 1.0;
    final ripple = math.cos(sides * theta);
    // Soften the ripple curve based on `corner` so higher corner = smoother
    // transitions between lobes (closer to a circle) and lower corner =
    // sharper, more pronounced petal/point shape.
    final softened = ripple.sign *
        math.pow(ripple.abs(), 1.0 + (1.0 - corner) * 1.5);
    return 1.0 + amplitude * softened;
  }
}

class _MorphPainter extends CustomPainter {
  const _MorphPainter({
    required this.from,
    required this.to,
    required this.t,
    required this.rotation,
    required this.color,
  });

  final _PolygonSpec from;
  final _PolygonSpec to;
  final double t;
  final double rotation;
  final Color color;

  static const int _segments = 96;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = math.min(size.width, size.height) / 2 * 0.86;

    final path = Path();
    for (int i = 0; i <= _segments; i++) {
      final theta = (i / _segments) * 2 * math.pi;

      final rFrom = from.radiusAt(theta);
      final rTo = to.radiusAt(theta);
      final r = _lerp(rFrom, rTo, t) * maxRadius;

      final angle = theta + rotation;
      final dx = center.dx + r * math.cos(angle);
      final dy = center.dy + r * math.sin(angle);

      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    path.close();

    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(covariant _MorphPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.rotation != rotation ||
      oldDelegate.color != color ||
      oldDelegate.from != from ||
      oldDelegate.to != to;
}
// rebuild trigger
