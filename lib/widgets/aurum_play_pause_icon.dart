import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AurumPlayPauseIcon — pixel-for-pixel port of Echo Nightly's play↔pause
// animated-vector icon (ic_play_to_pause_48dp_anim.xml /
// ic_pause_to_play_48dp_anim.xml), NOT a crossfade between two static
// Material icons. Android's <objectAnimator propertyName="pathData">
// works by interpolating each control point of one path directly into
// the corresponding control point of another path, frame by frame — the
// two source paths are hand-authored so every M/L/Q command lines up
// 1:1 between the triangle and the two bars. That's exactly what this
// widget does in Dart: `_playPoints` and `_pausePoints` below are that
// same command-aligned point data (extracted straight from the two
// transition XMLs, normalized to a 0..1 unit square from the original
// 960x960 viewport), lerped per-frame and rebuilt into a real Path via
// CustomPainter. The triangle visibly bends/reshapes into the two bars
// (and back) mid-flight — the actual "live" morph, not an icon swap.
//
// Also reproduces the two secondary motions from the same XML:
//   • group rotation: 0° → 90° over the full 300ms (fast_out_slow_in)
//   • scale pop: 1.0 → 1.25 (first 150ms) → 1.0 (last 150ms)
// combined here into one 300ms AnimationController driving all three
// (path lerp progress, rotation, scale) off a single fast_out_slow_in
// curve, matching Echo's own duration and easing exactly.
//
// PERF: controller only exists and ticks for this widget's lifetime, but
// costs nothing while idle — AnimationController with no active
// forward()/reverse() in flight doesn't tick. The Path is rebuilt from
// 28 lerped points every animating frame (cheap: plain double lerp, no
// allocations beyond one Path/List), and CustomPaint's shouldRepaint
// only returns true while `t` is actually mid-transition — once settled
// at 0 or 1 it stops repainting entirely, same idle cost as a plain Icon.
// ─────────────────────────────────────────────────────────────────────────────
class AurumPlayPauseIcon extends StatefulWidget {
  final bool isPlaying;
  final Color color;
  final double size;
  // Echo's XML duration (300ms) — exposed so callers matching a specific
  // button context (e.g. a smaller mini-player button that wants a
  // snappier feel) can override it without forking the whole widget.
  final Duration duration;

  const AurumPlayPauseIcon({
    super.key,
    required this.isPlaying,
    required this.color,
    this.size = 36,
    this.duration = const Duration(milliseconds: 300),
  });

  @override
  State<AurumPlayPauseIcon> createState() => _AurumPlayPauseIconState();
}

class _AurumPlayPauseIconState extends State<AurumPlayPauseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      // Starts already "settled" at whichever state we're opening in —
      // no morph plays on first build, only on subsequent toggles.
      value: widget.isPlaying ? 1.0 : 0.0,
    );
    _curve = CurvedAnimation(parent: _ctrl, curve: Curves.fastOutSlowIn);
  }

  @override
  void didUpdateWidget(AurumPlayPauseIcon old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying != old.isPlaying) {
      if (widget.isPlaying) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
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
      animation: _curve,
      builder: (context, _) {
        final t = _curve.value; // 0 = play (triangle), 1 = pause (bars)
        // Scale pop: 1→1.25 over the first half of the transition, back
        // to 1→1.0 over the second half — same two-leg shape as Echo's
        // pair of 150ms objectAnimators, just re-expressed against this
        // single 0..1 driver so both morph directions reuse one curve.
        final half = (t * 2).clamp(0.0, 2.0);
        final scale = half <= 1.0
            ? 1.0 + 0.25 * half
            : 1.0 + 0.25 * (2.0 - half);
        final rotationTurns = t * 0.25; // 0° → 90°
        return Transform.rotate(
          angle: rotationTurns * 3.14159265358979 * 2,
          child: Transform.scale(
            scale: scale,
            child: CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _PlayPausePainter(t: t, color: widget.color),
            ),
          ),
        );
      },
    );
  }
}

class _PlayPausePainter extends CustomPainter {
  final double t;
  final Color color;
  const _PlayPausePainter({required this.t, required this.color});

  // Command sequence shared by both source shapes (extracted directly
  // from Echo's transition XML — every M/L/Q lines up 1:1 between the
  // triangle and the two-bar pause icon).
  static const List<String> _cmdSeq = [
    'M', 'L', 'Q', 'Q', 'L', 'Q', 'Q', 'L', 'Q', 'Q', 'Q', 'Q', 'Q', 'Q',
    'M', 'L', 'Q', 'Q', 'L', 'Q', 'Q', 'L', 'Q', 'Q', 'Q', 'Q', 'Q', 'Q',
  ];

  // Play (triangle) shape, normalized 0..1 (from 960x960 viewport).
  static const List<Offset> _playPoints = [
    Offset(0.381250, 0.758333),
    Offset(0.750000, 0.522917),
    Offset(0.757292, 0.517708),
    Offset(0.760938, 0.511458),
    Offset(0.764583, 0.505208),
    Offset(0.764583, 0.496875),
    Offset(0.620833, 0.496131),
    Offset(0.548958, 0.495759),
    Offset(0.477083, 0.495386),
    Offset(0.405208, 0.495015),
    Offset(0.333333, 0.494643),
    Offset(0.333333, 0.731250),
    Offset(0.333333, 0.731250),
    Offset(0.333333, 0.731250),
    Offset(0.333333, 0.745833),
    Offset(0.342708, 0.754167),
    Offset(0.352083, 0.762500),
    Offset(0.364583, 0.762500),
    Offset(0.368750, 0.762500),
    Offset(0.372917, 0.761458),
    Offset(0.375000, 0.760938),
    Offset(0.377083, 0.760156),
    Offset(0.379167, 0.759375),
    Offset(0.381250, 0.758333),
    Offset(0.333333, 0.494643),
    Offset(0.764583, 0.496875),
    Offset(0.764583, 0.488542),
    Offset(0.760938, 0.482292),
    Offset(0.757292, 0.476042),
    Offset(0.750000, 0.470833),
    Offset(0.657813, 0.411979),
    Offset(0.611719, 0.382552),
    Offset(0.565625, 0.353125),
    Offset(0.519531, 0.323698),
    Offset(0.473438, 0.294271),
    Offset(0.381250, 0.235417),
    Offset(0.377083, 0.233333),
    Offset(0.372917, 0.232292),
    Offset(0.368750, 0.231250),
    Offset(0.364583, 0.231250),
    Offset(0.352083, 0.231250),
    Offset(0.342708, 0.239583),
    Offset(0.333333, 0.247917),
    Offset(0.333333, 0.262500),
    Offset(0.333333, 0.320535),
    Offset(0.333333, 0.378572),
    Offset(0.333333, 0.436607),
    Offset(0.333333, 0.494643),
  ];

  // Pause (two bars) shape, normalized 0..1 (from 960x960 viewport).
  static const List<Offset> _pausePoints = [
    Offset(0.270833, 0.760417),
    Offset(0.729167, 0.760417),
    Offset(0.754938, 0.760427),
    Offset(0.773302, 0.742062),
    Offset(0.791667, 0.723698),
    Offset(0.791667, 0.697917),
    Offset(0.791667, 0.640625),
    Offset(0.791677, 0.614854),
    Offset(0.773312, 0.596490),
    Offset(0.754948, 0.578125),
    Offset(0.729167, 0.578125),
    Offset(0.270833, 0.578125),
    Offset(0.245062, 0.578115),
    Offset(0.226698, 0.596479),
    Offset(0.208333, 0.614844),
    Offset(0.208333, 0.640625),
    Offset(0.208333, 0.640625),
    Offset(0.208333, 0.640625),
    Offset(0.208333, 0.669271),
    Offset(0.208333, 0.697917),
    Offset(0.208323, 0.723688),
    Offset(0.226688, 0.742052),
    Offset(0.245052, 0.760417),
    Offset(0.270833, 0.760417),
    Offset(0.270833, 0.421875),
    Offset(0.729167, 0.421875),
    Offset(0.754938, 0.421885),
    Offset(0.773302, 0.403521),
    Offset(0.791667, 0.385156),
    Offset(0.791667, 0.359375),
    Offset(0.791667, 0.302083),
    Offset(0.791677, 0.276313),
    Offset(0.773312, 0.257948),
    Offset(0.754948, 0.239583),
    Offset(0.729167, 0.239583),
    Offset(0.270833, 0.239583),
    Offset(0.245062, 0.239573),
    Offset(0.226698, 0.257937),
    Offset(0.208333, 0.276302),
    Offset(0.208333, 0.302083),
    Offset(0.208333, 0.302083),
    Offset(0.208333, 0.302083),
    Offset(0.208333, 0.330729),
    Offset(0.208333, 0.359375),
    Offset(0.208323, 0.385146),
    Offset(0.226688, 0.403510),
    Offset(0.245052, 0.421875),
    Offset(0.270833, 0.421875),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final path = Path();
    int i = 0;
    Offset lerpAt(int idx) => Offset.lerp(_playPoints[idx], _pausePoints[idx], t)!;

    // Two sub-contours in this data (each shape is drawn as two M...Z
    // pieces — the pause icon's two bars, and the play triangle's own
    // matching two-piece decomposition so every point lines up 1:1
    // across the morph). Close the previous contour whenever a new 'M'
    // starts, and close the final one after the loop — mirrors the
    // SVG's own "M...Z M...Z" structure exactly.
    bool hasOpenContour = false;
    for (final cmd in _cmdSeq) {
      switch (cmd) {
        case 'M':
          if (hasOpenContour) path.close();
          final p = lerpAt(i);
          path.moveTo(p.dx * size.width, p.dy * size.height);
          hasOpenContour = true;
          i += 1;
          break;
        case 'L':
          final p = lerpAt(i);
          path.lineTo(p.dx * size.width, p.dy * size.height);
          i += 1;
          break;
        case 'Q':
          final c = lerpAt(i);
          final e = lerpAt(i + 1);
          path.quadraticBezierTo(
            c.dx * size.width, c.dy * size.height,
            e.dx * size.width, e.dy * size.height,
          );
          i += 2;
          break;
      }
    }
    if (hasOpenContour) path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PlayPausePainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}
