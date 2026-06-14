// aurum_loader.dart
// Aurum Music — Blob Loading Experience
// Pure Flutter · No external packages · 60 FPS · AMOLED optimised

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// ═══════════════════════════════════════════════════════════════════════════
// DESIGN TOKENS
// ═══════════════════════════════════════════════════════════════════════════

abstract final class _AurumColors {
  static const auroraPurple = Color(0xFF8B5CF6);
  static const electricCyan = Color(0xFF22D3EE);
  static const auroraPink   = Color(0xFFEC4899);
  static const deepBlack    = Color(0xFF000000);
  static const white        = Color(0xFFFFFFFF);
}

abstract final class _Timing {
  static const masterMs  = 3600;
  static const fadeInMs  = 900;
  static const fadeOutMs = 700;
  static const burstMs   = 1200;
}

// ═══════════════════════════════════════════════════════════════════════════
// LOADER STATE
// ═══════════════════════════════════════════════════════════════════════════

enum AurumLoaderState { loading, completing, completed }

// ═══════════════════════════════════════════════════════════════════════════
// PUBLIC WIDGET — AurumLoader
// ═══════════════════════════════════════════════════════════════════════════

class AurumLoader extends StatefulWidget {
  const AurumLoader({
    super.key,
    this.size             = 200,
    this.dominantColor,
    this.secondaryColor,
    this.state            = AurumLoaderState.loading,
    this.onCompleted,
  });

  /// Bounding box (square).
  final double size;

  /// Optional album-art dominant colour — overrides aurora palette when set.
  final Color? dominantColor;

  /// Optional album-art secondary colour.
  final Color? secondaryColor;

  /// Drive the completion burst from outside.
  final AurumLoaderState state;

  /// Called after the dissolution animation finishes.
  final VoidCallback? onCompleted;

  @override
  State<AurumLoader> createState() => _AurumLoaderState();
}

class _AurumLoaderState extends State<AurumLoader>
    with SingleTickerProviderStateMixin {

  late final AnimationController _master;

  late final Animation<double> _fadeIn;
  double _burstProgress = 0.0;
  double _dissolveAlpha = 1.0;

  AurumLoaderState _internalState = AurumLoaderState.loading;
  bool _burstStarted = false;

  double _burstElapsed = 0.0;
  int _lastFrameTime   = 0;

  @override
  void initState() {
    super.initState();

    _master = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _Timing.masterMs),
    )..addListener(_onTick)..repeat();

    _fadeIn = CurvedAnimation(
      parent: _master,
      curve: Interval(
        0,
        _Timing.fadeInMs / _Timing.masterMs,
        curve: Curves.easeOut,
      ),
    );
  }

  void _onTick() {
    if (_internalState == AurumLoaderState.completing) {
      final now = DateTime.now().microsecondsSinceEpoch;
      if (_lastFrameTime != 0) {
        _burstElapsed += (now - _lastFrameTime) / 1000.0;
      }
      _lastFrameTime = now;

      final newBurst = (_burstElapsed / _Timing.burstMs).clamp(0.0, 1.0);
      if (newBurst >= 1.0 && _dissolveAlpha > 0.0) {
        _dissolveAlpha = 0.0;
        setState(() {
          _internalState = AurumLoaderState.completed;
        });
        widget.onCompleted?.call();
      } else {
        _burstProgress = newBurst;
        if (newBurst > 0.70) {
          _dissolveAlpha = 1.0 - ((newBurst - 0.70) / 0.30).clamp(0.0, 1.0);
        }
      }
    }
  }

  @override
  void didUpdateWidget(AurumLoader old) {
    super.didUpdateWidget(old);
    if (widget.state == AurumLoaderState.completing && !_burstStarted) {
      _burstStarted  = true;
      _lastFrameTime = 0;
      _burstElapsed  = 0;
      setState(() => _internalState = AurumLoaderState.completing);
    }
  }

  @override
  void dispose() {
    _master.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_internalState == AurumLoaderState.completed) {
      return const SizedBox.shrink();
    }

    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final s = widget.size;
    final dark = Theme.of(context).brightness == Brightness.dark;

    // Pick color: dominantColor → aurora purple fallback
    final color = widget.dominantColor ?? _AurumColors.auroraPurple;

    return RepaintBoundary(
      child: Opacity(
        opacity: _dissolveAlpha,
        child: SizedBox(
          width: s,
          height: s,
          child: AnimatedBuilder(
            animation: _master,
            builder: (_, __) {
              final fadeAlpha = reducedMotion ? 1.0 : _fadeIn.value;
              return Opacity(
                opacity: fadeAlpha.clamp(0.0, 1.0),
                child: CustomPaint(
                  painter: _BlobPainter(
                    t:      _master.value,
                    color:  color,
                    dark:   dark,
                    glow:   true,
                    breathe: true,
                    seed:   42,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// BLOB PAINTER
// ═══════════════════════════════════════════════════════════════════════════

class _BlobPainter extends CustomPainter {
  const _BlobPainter({
    required this.t,
    required this.color,
    required this.dark,
    this.glow    = true,
    this.breathe = true,
    this.seed    = 0,
  });

  final double t;
  final Color  color;
  final bool   dark;
  final bool   glow;
  final bool   breathe;
  final int    seed;

  @override
  void paint(Canvas canvas, Size size) {
    final time = t * math.pi * 2;
    final c = Offset(size.width / 2, size.height / 2);
    // Breathing scale
    final scale = breathe
        ? 1.0 + math.sin(time * 0.7) * 0.04 + math.cos(time * 1.1) * 0.02
        : 1.0;
    final r = (size.shortestSide / 2) * 0.55 * scale;
    final n = 48; // mesh resolution
    final pts = List<Offset>.filled(n, Offset.zero);

    // =========================================================
    // 1. GLOW HALO
    // =========================================================
    if (glow) {
      final outer = Paint()
        ..shader = ui.Gradient.radial(
          c,
          r * 2.2,
          [
            color.withOpacity(dark ? 0.22 : 0.10),
            Colors.transparent,
          ],
        );

      canvas.drawCircle(c, r * 2.0, outer);

      final mid = Paint()
        ..shader = ui.Gradient.radial(
          c,
          r * 1.6,
          [
            color.withOpacity(dark ? 0.12 : 0.06),
            Colors.transparent,
          ],
        );

      canvas.drawCircle(c, r * 1.4, mid);
    }

    // =========================================================
    // 2. ORGANIC MESH SHAPE
    // =========================================================
    for (int i = 0; i < n; i++) {
      final a = (i / n) * math.pi * 2;

      final w =
          math.sin(a * 3 + time * 2) * 0.08 +
          math.cos(a * 5 - time * 3) * 0.05 +
          math.sin(a * 2 + time * 1.4) * 0.04;

      final rr = r * (1 + w);

      pts[i] = Offset(
        c.dx + math.cos(a) * rr,
        c.dy + math.sin(a) * rr,
      );
    }

    final path = Path()..moveTo(pts[0].dx, pts[0].dy);

    for (int i = 0; i < n; i++) {
      final p0 = pts[(i - 1) % n];
      final p1 = pts[i];
      final p2 = pts[(i + 1) % n];
      final p3 = pts[(i + 2) % n];

      final cp1 = Offset(
        p1.dx + (p2.dx - p0.dx) * 0.18,
        p1.dy + (p2.dy - p0.dy) * 0.18,
      );

      final cp2 = Offset(
        p2.dx - (p3.dx - p1.dx) * 0.18,
        p2.dy - (p3.dy - p1.dy) * 0.18,
      );

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }

    path.close();

    // =========================================================
    // 3. PURE GPU RADIAL GRADIENT (NO SHADER FILTERS)
    // =========================================================
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        c,
        r * 1.4,
        [
          Color.lerp(Colors.white, color, 0.2)!.withOpacity(0.95),
          color.withOpacity(0.92),
          Colors.black.withOpacity(dark ? 0.22 : 0.05),
        ],
        const [0, 0.55, 1],
      );

    canvas.drawPath(path, paint);

    // =========================================================
    // 4. LIGHT SHEEN (GPU linear gradient only)
    // =========================================================
    canvas.save();
    canvas.clipPath(path);

    final sheen = Paint()
      ..shader = ui.Gradient.linear(
        Offset(c.dx - r, c.dy - r),
        Offset(c.dx + r, c.dy + r),
        [
          Colors.white.withOpacity(0.18),
          Colors.white.withOpacity(0.05),
          Colors.transparent,
        ],
      );

    canvas.drawRect(
      Rect.fromCircle(center: c, radius: r * 1.6),
      sheen,
    );

    canvas.restore();

    // =========================================================
    // 5. SMALL HIGHLIGHT (NO EXTRA BLUR, PURE PAINT)
    // =========================================================
    final highlight = Paint()
      ..color = Colors.white.withOpacity(dark ? 0.08 : 0.12);

    canvas.drawCircle(
      Offset(c.dx - r * 0.18, c.dy - r * 0.22),
      r * 0.18,
      highlight,
    );
  }

  @override
  bool shouldRepaint(covariant _BlobPainter o) {
    return o.t != t ||
        o.color != color ||
        o.dark != dark ||
        o.glow != glow ||
        o.breathe != breathe ||
        o.seed != seed;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CONVENIENCE WRAPPERS — public API
// ═══════════════════════════════════════════════════════════════════════════

class AurumLoaderSmall extends StatelessWidget {
  const AurumLoaderSmall({
    super.key,
    this.dominantColor,
    this.secondaryColor,
  });

  final Color? dominantColor;
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) => AurumLoader(
        size: 80,
        dominantColor: dominantColor,
        secondaryColor: secondaryColor,
      );
}

class AurumLoaderLarge extends StatelessWidget {
  const AurumLoaderLarge({
    super.key,
    this.dominantColor,
    this.secondaryColor,
  });

  final Color? dominantColor;
  final Color? secondaryColor;

  @override
  Widget build(BuildContext context) => AurumLoader(
        size: 260,
        dominantColor: dominantColor,
        secondaryColor: secondaryColor,
      );
}

/// Full-screen AMOLED loading overlay with cinematic fade-in.
class AurumLoaderScreen extends StatefulWidget {
  const AurumLoaderScreen({
    super.key,
    this.dominantColor,
    this.secondaryColor,
    this.onCompleted,
  });

  final Color? dominantColor;
  final Color? secondaryColor;
  final VoidCallback? onCompleted;

  @override
  State<AurumLoaderScreen> createState() => _AurumLoaderScreenState();
}

class _AurumLoaderScreenState extends State<AurumLoaderScreen>
    with SingleTickerProviderStateMixin {

  late final AnimationController _bgFade;
  late final Animation<double>   _bgOpacity;
  AurumLoaderState _loaderState = AurumLoaderState.loading;

  @override
  void initState() {
    super.initState();
    _bgFade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _Timing.fadeInMs),
    )..forward();
    _bgOpacity = CurvedAnimation(parent: _bgFade, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _bgFade.dispose();
    super.dispose();
  }

  /// Call this to trigger the completion burst from outside.
  void complete() => setState(() => _loaderState = AurumLoaderState.completing);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bgOpacity,
      builder: (_, child) => Opacity(
        opacity: _bgOpacity.value,
        child: child,
      ),
      child: ColoredBox(
        color: _AurumColors.deepBlack,
        child: Center(
          child: AurumLoader(
            size           : 220,
            dominantColor  : widget.dominantColor,
            secondaryColor : widget.secondaryColor,
            state          : _loaderState,
            onCompleted    : widget.onCompleted,
          ),
        ),
      ),
    );
  }
}
