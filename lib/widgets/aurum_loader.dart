// aurum_loader.dart
// Aurum Music — Infinity Loading Experience
// Pure Flutter · No external packages · 60 FPS · AMOLED Black + Deep Purple

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

// ═══════════════════════════════════════════════════════════════════════════
// DESIGN TOKENS
// ═══════════════════════════════════════════════════════════════════════════

abstract final class _AurumColors {
  static const amoledBlack   = Color(0xFF000000);
  static const deepPurple    = Color(0xFF6B21A8);
  static const deepPurpleMid = Color(0xFF7C3AED);
  static const deepPurpleLit = Color(0xFF9333EA);
  static const purpleGlow    = Color(0xFFA855F7);
  static const purpleWhisper = Color(0xFF3B0764);
}

// ═══════════════════════════════════════════════════════════════════════════
// PUBLIC WIDGET — AurumLoader
// ═══════════════════════════════════════════════════════════════════════════

class AurumLoader extends StatefulWidget {
  const AurumLoader({
    super.key,
    this.size = 200,
  });

  final double size;

  @override
  State<AurumLoader> createState() => _AurumLoaderState();
}

class _AurumLoaderState extends State<AurumLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size * 0.56,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
            painter: _InfinityPainter(t: _ctrl.value),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// INFINITY PAINTER
// ═══════════════════════════════════════════════════════════════════════════

class _InfinityPainter extends CustomPainter {
  const _InfinityPainter({required this.t});

  final double t; // 0.0 → 1.0 looping

  // Lemniscate of Bernoulli parametric equations
  // x = a*cos(θ) / (1 + sin²(θ))
  // y = a*sin(θ)*cos(θ) / (1 + sin²(θ))
  Offset _infinityPoint(double theta, double a) {
    final sinT  = math.sin(theta);
    final cosT  = math.cos(theta);
    final denom = 1 + sinT * sinT;
    return Offset(a * cosT / denom, a * sinT * cosT / denom);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height / 2;
    final a  = size.width  * 0.36; // lemniscate scale

    // ── 1. Build full path (360°) ─────────────────────────────────────────
    const steps = 300;
    final allPts = List<Offset>.generate(steps + 1, (i) {
      final theta = (i / steps) * math.pi * 2;
      final p = _infinityPoint(theta, a);
      return Offset(cx + p.dx, cy + p.dy);
    });

    final fullPath = Path()..moveTo(allPts[0].dx, allPts[0].dy);
    for (int i = 1; i <= steps; i++) {
      fullPath.lineTo(allPts[i].dx, allPts[i].dy);
    }
    fullPath.close();

    // ── 2. Outer glow halo ────────────────────────────────────────────────
    final glowPaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap   = StrokeCap.round
      ..shader      = ui.Gradient.sweep(
          Offset(cx, cy),
          [
            _AurumColors.purpleWhisper.withOpacity(0.0),
            _AurumColors.deepPurple.withOpacity(0.25),
            _AurumColors.purpleGlow.withOpacity(0.18),
            _AurumColors.purpleWhisper.withOpacity(0.0),
          ],
          [0.0, 0.35, 0.65, 1.0],
        )
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 10);

    canvas.drawPath(fullPath, glowPaint);

    // ── 3. Mid glow ───────────────────────────────────────────────────────
    final midGlow = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap   = StrokeCap.round
      ..shader      = ui.Gradient.sweep(
          Offset(cx, cy),
          [
            _AurumColors.deepPurple.withOpacity(0.0),
            _AurumColors.deepPurpleMid.withOpacity(0.55),
            _AurumColors.purpleGlow.withOpacity(0.45),
            _AurumColors.deepPurple.withOpacity(0.0),
          ],
          [0.0, 0.35, 0.65, 1.0],
        )
      ..maskFilter  = const MaskFilter.blur(BlurStyle.normal, 4);

    canvas.drawPath(fullPath, midGlow);

    // ── 4. Base track (faint) ─────────────────────────────────────────────
    final trackPaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap   = StrokeCap.round
      ..color       = _AurumColors.deepPurple.withOpacity(0.18);

    canvas.drawPath(fullPath, trackPaint);

    // ── 5. Travelling orb (particle riding the curve) ─────────────────────
    const orbSteps  = 160;   // tail length (# of points)
    const totalSeg  = steps;
    final headIdx   = (t * totalSeg).round() % totalSeg;

    // Build tail path
    final tailPath = Path();
    bool first = true;
    for (int i = orbSteps; i >= 0; i--) {
      final idx = (headIdx - i + totalSeg) % totalSeg;
      final pt  = allPts[idx];
      final progress = 1.0 - (i / orbSteps); // 0→1 toward head

      if (first) {
        tailPath.moveTo(pt.dx, pt.dy);
        first = false;
      } else {
        tailPath.lineTo(pt.dx, pt.dy);
      }
    }

    // Tail gradient stroke (fade from transparent to bright)
    final tailPaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap   = StrokeCap.round
      ..shader      = ui.Gradient.linear(
          allPts[(headIdx - orbSteps + totalSeg) % totalSeg],
          allPts[headIdx],
          [
            _AurumColors.deepPurple.withOpacity(0.0),
            _AurumColors.deepPurpleMid.withOpacity(0.6),
            _AurumColors.deepPurpleLit.withOpacity(0.9),
            _AurumColors.purpleGlow,
          ],
          [0.0, 0.4, 0.75, 1.0],
        );

    canvas.drawPath(tailPath, tailPaint);

    // ── 6. Orb head ───────────────────────────────────────────────────────
    final head = allPts[headIdx];

    // Orb outer glow
    final orbGlow = Paint()
      ..shader    = ui.Gradient.radial(
          head, 14,
          [
            _AurumColors.purpleGlow.withOpacity(0.55),
            _AurumColors.deepPurpleMid.withOpacity(0.18),
            Colors.transparent,
          ],
          [0.0, 0.55, 1.0],
        )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawCircle(head, 14, orbGlow);

    // Orb core
    final orbCore = Paint()
      ..shader = ui.Gradient.radial(
          head, 5,
          [
            Colors.white.withOpacity(0.95),
            _AurumColors.purpleGlow.withOpacity(0.9),
            _AurumColors.deepPurpleLit,
          ],
          [0.0, 0.4, 1.0],
        );

    canvas.drawCircle(head, 5, orbCore);

    // ── 7. Second orb (offset by 180°) for symmetry ───────────────────────
    final head2Idx = (headIdx + totalSeg ~/ 2) % totalSeg;
    final head2    = allPts[head2Idx];

    final orb2Glow = Paint()
      ..shader    = ui.Gradient.radial(
          head2, 10,
          [
            _AurumColors.deepPurpleLit.withOpacity(0.35),
            Colors.transparent,
          ],
        )
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    canvas.drawCircle(head2, 10, orb2Glow);

    final orb2Core = Paint()
      ..shader = ui.Gradient.radial(
          head2, 3.5,
          [
            Colors.white.withOpacity(0.80),
            _AurumColors.deepPurpleMid,
          ],
        );

    canvas.drawCircle(head2, 3.5, orb2Core);
  }

  @override
  bool shouldRepaint(covariant _InfinityPainter old) => old.t != t;
}

// ═══════════════════════════════════════════════════════════════════════════
// CONVENIENCE WRAPPERS
// ═══════════════════════════════════════════════════════════════════════════

class AurumLoaderSmall extends StatelessWidget {
  const AurumLoaderSmall({super.key});

  @override
  Widget build(BuildContext context) => const AurumLoader(size: 120);
}

class AurumLoaderLarge extends StatelessWidget {
  const AurumLoaderLarge({super.key});

  @override
  Widget build(BuildContext context) => const AurumLoader(size: 280);
}

/// Full-screen AMOLED overlay — pure black background, loader centered.
/// Search screen ke andar bhi isko use karo taaki black flash na aaye.
class AurumLoaderScreen extends StatelessWidget {
  const AurumLoaderScreen({super.key, this.onCompleted});

  final VoidCallback? onCompleted;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _AurumColors.amoledBlack,            // ← hardcoded AMOLED black
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AurumLoader(size: 240),
            const SizedBox(height: 32),
            Text(
              'AURUM',
              style: TextStyle(
                color:           _AurumColors.purpleGlow.withOpacity(0.55),
                fontSize:        11,
                letterSpacing:   6,
                fontWeight:      FontWeight.w300,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// HOW TO USE
// ─────────────────────────────────────────────────────────────────────────
// Splash / initial load:
//   Navigator.push(context, MaterialPageRoute(
//     builder: (_) => const AurumLoaderScreen(),
//   ));
//
// Search page (inline, replaces black flash):
//   if (_isSearching)
//     const AurumLoaderSmall()
//   else
//     YourResultsList()
//
// Any widget spot:
//   const AurumLoader(size: 200)
// ─────────────────────────────────────────────────────────────────────────
