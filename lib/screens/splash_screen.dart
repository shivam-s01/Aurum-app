import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen — premium edition using the REAL launcher icon assets.
// ─────────────────────────────────────────────────────────────────────────────
//
// Why this version is different from the old one: the previous splash hand-
// drew the scallop silhouette and note glyph with CustomPainter Paths. Those
// paths were an approximation and didn't exactly match the real launcher
// icon, so the shape looked "off"/distorted once it started spinning.
//
// This version instead uses two PNGs extracted directly, pixel-for-pixel,
// from the actual ic_launcher_foreground.png:
//   • assets/scallop_ring.png — the 10-lobe scallop silhouette + gradient,
//     with the note-glyph area cut out (transparent hole where the note is)
//   • assets/note_glyph.png   — just the white eighth-note, isolated
//
// Because both layers are literally cropped from the same source image,
// stacking them recreates the exact icon with zero distortion, at any
// rotation or scale.
//
// Timeline (~2.7s total — tuned to feel like a premium/Spotify-class splash,
// not overlong):
//   0.00–0.25s   background fade-in; mark 85%→100% scale, 0→100% opacity
//   0.25–1.95s   scallop ring spins at a smooth, constant rate (one full
//                turn), soft motion-blur trail; note glyph stays rotationally
//                still and glows in (fade + soft bloom), settling to solid
//                white by the end of the window
//   1.95–2.15s   ring eases to a stop (no bounce/overshoot)
//   2.15–2.35s   one tight glass reflection sweep
//   2.15–2.45s   one soft glow pulse
//   2.45–2.70s   cross-fade handoff into the home screen
//
// Single AnimationController drives everything via Interval/Curve — cheap,
// fully GPU-composited (Transform + Opacity only, no shader passes), each
// layer behind its own RepaintBoundary.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _total = Duration(milliseconds: 2700);

  static const double _tEntranceEnd = 0.25 / 2.7;
  static const double _tSpinStart = 0.25 / 2.7;
  static const double _tSpinEnd = 1.95 / 2.7;
  static const double _tDecelEnd = 2.15 / 2.7;
  static const double _tPulseEnd = 2.45 / 2.7;
  static const double _tSweepStart = 2.15 / 2.7;
  static const double _tSweepEnd = 2.35 / 2.7;

  late final AnimationController _ctrl;

  late final Animation<double> _bgOpacity;
  late final Animation<double> _markScale;
  late final Animation<double> _markOpacity;
  late final Animation<double> _bloom;
  late final Animation<double> _ringAngle;
  late final Animation<double> _trailFade;
  late final Animation<double> _noteGlow;
  late final Animation<double> _pulse;
  late final Animation<double> _sweep;
  late final Animation<double> _handoffT;

  bool _showChild = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    _bgOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOut),
    );

    _markScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOutCubic),
      ),
    );

    _markOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOut),
    );

    _bloom = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _tSpinEnd, curve: Curves.easeOut),
    );

    // Ring spins smoothly — one clean rotation across the spin window,
    // eases to a natural stop (no bounce).
    _ringAngle = _DerivedAnimation(_ctrl, _ringAngleFor);

    _trailFade = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(
        _tSpinEnd - 0.04,
        _tSpinEnd,
        curve: Curves.easeIn,
      ),
    );

    // Note glyph: fades + glows in across the spin window, ending fully
    // solid/settled right as the ring finishes decelerating.
    _noteGlow = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tSpinStart, _tDecelEnd, curve: Curves.easeOutCubic),
    );

    _pulse = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tDecelEnd, _tPulseEnd, curve: Curves.easeOut),
    );

    _sweep = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tSweepStart, _tSweepEnd, curve: Curves.easeInOut),
    );

    _handoffT = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tPulseEnd, 1.0, curve: Curves.easeInOut),
    );

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) setState(() => _showChild = true);
      }
    });

    _ctrl.forward();
  }

  // Smooth constant-rate spin with an eased deceleration at the end —
  // no ramp-up flashiness, no overshoot. One full 360° turn.
  double _ringAngleFor(double t) {
    if (t < _tSpinStart) return 0.0;
    if (t >= _tDecelEnd) return 2 * 3.14159265359;
    if (t <= _tSpinEnd) {
      final localT = (t - _tSpinStart) / (_tSpinEnd - _tSpinStart);
      return localT * 2 * 3.14159265359 * 0.86;
    }
    final decelT = (t - _tSpinEnd) / (_tDecelEnd - _tSpinEnd);
    final eased = Curves.easeOutCubic.transform(decelT.clamp(0.0, 1.0));
    final startAngle = 2 * 3.14159265359 * 0.86;
    final endAngle = 2 * 3.14159265359;
    return startAngle + (endAngle - startAngle) * eased;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showChild) return widget.child;

    final bg = AurumTheme.bgOf(context);

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: bg,
          body: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: _bgOpacity.value,
                child: Container(color: bg),
              ),
              Transform.scale(
                scale: _markScale.value,
                child: Opacity(
                  opacity: _markOpacity.value,
                  child: _buildMark(),
                ),
              ),
              if (_sweep.value > 0)
                RepaintBoundary(
                  child: CustomPaint(
                    size: const Size(180, 180),
                    painter: _GlassSweepPainter(progress: _sweep.value),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMark() {
    const double markSize = 132;

    return SizedBox(
      width: markSize,
      height: markSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Soft bloom glow behind everything
          RepaintBoundary(
            child: Opacity(
              opacity: (_bloom.value * 0.5).clamp(0.0, 1.0),
              child: Container(
                width: markSize * 1.5,
                height: markSize * 1.5,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color(0x55C77DFF),
                      Color(0x00C77DFF),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Motion-blur trail copies (faint, rotated slightly behind the
          // leading ring), fades out as the spin ends.
          if (_trailFade.value < 1.0)
            RepaintBoundary(
              child: Opacity(
                opacity: (1.0 - _trailFade.value) * 0.35,
                child: Transform.rotate(
                  angle: _ringAngle.value - 0.35,
                  child: Opacity(
                    opacity: 0.5,
                    child: Image.asset(
                      'assets/images/scallop_ring.png',
                      width: markSize,
                      height: markSize,
                    ),
                  ),
                ),
              ),
            ),
          if (_trailFade.value < 1.0)
            RepaintBoundary(
              child: Opacity(
                opacity: (1.0 - _trailFade.value) * 0.18,
                child: Transform.rotate(
                  angle: _ringAngle.value - 0.6,
                  child: Opacity(
                    opacity: 0.3,
                    child: Image.asset(
                      'assets/images/scallop_ring.png',
                      width: markSize,
                      height: markSize,
                    ),
                  ),
                ),
              ),
            ),

          // Leading scallop ring — the actual spinning silhouette, exact
          // pixel crop from the real launcher icon.
          RepaintBoundary(
            child: Transform.rotate(
              angle: _ringAngle.value,
              child: Image.asset(
                'assets/images/scallop_ring.png',
                width: markSize,
                height: markSize,
              ),
            ),
          ),

          // Note glyph — never rotates, glows/fades in in place, exact
          // pixel crop from the real launcher icon.
          RepaintBoundary(
            child: Opacity(
              opacity: _noteGlow.value.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white
                          .withOpacity(0.5 * (1.0 - _noteGlow.value).clamp(0.0, 1.0)),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Image.asset(
                  'assets/images/note_glyph.png',
                  width: markSize,
                  height: markSize,
                ),
              ),
            ),
          ),

          // Glow pulse after settle
          if (_pulse.value > 0)
            IgnorePointer(
              child: Opacity(
                opacity: (1.0 - _pulse.value) * 0.4 *
                    (_pulse.value > 0 ? 1.0 : 0.0) *
                    (4 * _pulse.value * (1 - _pulse.value)), // soft bump
                child: Container(
                  width: markSize * 1.3,
                  height: markSize * 1.3,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Color(0x66FFFFFF),
                        Color(0x00FFFFFF),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Helper: drives a derived value from the controller without a separate
// AnimationController — recomputed every tick from a mapping function.
class _DerivedAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _DerivedAnimation(this.parent, this._map);
  @override
  final Animation<double> parent;
  final double Function(double) _map;

  @override
  double get value => _map(parent.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// _GlassSweepPainter — one tight Apple-style glass reflection sweep.
// ─────────────────────────────────────────────────────────────────────────────
class _GlassSweepPainter extends CustomPainter {
  _GlassSweepPainter({required this.progress});
  final double progress; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: radius)));

    final sweepX = -radius + progress * (size.width + radius * 2);
    final rect = Rect.fromLTWH(sweepX - radius * 0.4, 0, radius * 0.8, size.height);

    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(0.45),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect);

    canvas.drawRect(rect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GlassSweepPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
