import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AurumMotion — shared timing / easing constants for the whole app.
// ─────────────────────────────────────────────────────────────────────────────
class AurumMotion {
  static const Duration fast   = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 300);
  static const Duration slow   = Duration(milliseconds: 500);

  static const Curve enter  = Curves.easeOutCubic;
  static const Curve exit   = Curves.easeInCubic;
  static const Curve smooth = Curves.easeInOutCubic;
}

// ─────────────────────────────────────────────────────────────────────────────
// _CriticallyDampedSpring
// ─────────────────────────────────────────────────────────────────────────────
// Ultra-subtle, critically-damped spring — reaches rest with zero visible
// overshoot/bounce, but carries a touch more "weight" than a plain cubic
// ease-out. Closed form: f(t) = 1 - (1 + kt) * e^(-kt).
class _CriticallyDampedSpring extends Curve {
  const _CriticallyDampedSpring([this.k = 6.9]);
  final double k;
  @override
  double transformInternal(double t) {
    final decay = (1 + k * t) * math.exp(-k * t);
    return 1 - decay;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen — flagship edition (minimal, premium, ~2.2s).
// ─────────────────────────────────────────────────────────────────────────────
//
// Design intent: a small, confident piece of choreography — not a single
// motion, but a few coordinated moves layered together, the way a
// hand-animated icon (à la Material "animated vector") feels: alive without
// being busy. Two independent layers:
//
//   • the glow ring: a soft halo behind the mark that slowly rotates the
//     entire time, completely independently of the mark on top — the same
//     trick Echo's icon uses (ring spins on its own layer while the glyph
//     on top does something else entirely)
//   • the mark itself: scales in from small or was fully invisible, arrives
//     with a gentle overshoot, then performs one small settle "wobble"
//     (a quick tilt one way, back, a smaller tilt the other way, back —
//     like it's finding its balance) and a subtle breathing pulse, before
//     coming to a dead stop at exactly its launcher-icon size and rotation
//
// Sequence:
//
//   0ms                  mark: 0 opacity, 70% scale, 2px blur, centred
//                        glow ring: 0 opacity, rotation 0°
//   0–450ms              mark scales 70%→100% with a gentle overshoot
//                        spring (easeOutBack) — arrives with real presence,
//                        settles without snapping
//   0–380ms               opacity 0→1, blur 2px→0 (ease-out)
//   450–650ms             wobble part 1: mark tilts to -6°
//   650–900ms             wobble part 2: tilts back through 0° to +3°
//   900–1100ms            wobble settles: +3° eases back to 0° — mark is
//                        now perfectly still, at exact original proportions
//   1100–1300ms           one gentle breathing pulse: 100%→103%→100%,
//                        a single soft "life" beat, not a loop
//   0–2200ms              the glow ring behind the mark rotates slowly and
//                        continuously the entire time (independent layer,
//                        never stops until handoff) — the ambient motion
//                        that keeps the frame feeling alive without ever
//                        drawing focus from the mark itself
//   1300–1650ms            a single soft gradient highlight sweeps across
//                        the face of the mark once it's fully still, like
//                        light catching brushed metal — never repeats
//   1650–1900ms            brief confident hold on the settled mark
//   1900–2200ms            seamless shared-element style handoff: splash
//                        cross-fades directly into the home screen's first
//                        frame (no wipe, no zoom-out flash)
//
// Total: ~2.2s.
//
// Perf: a single AnimationController drives every value via CurvedAnimation
// / Interval — no nested controllers, no per-frame allocations. The glow
// ring and mark each sit behind their own RepaintBoundary so repaints never
// cascade into the rest of the tree. ImageFiltered blur is only active
// while blur > 0 (first ~200ms) — once it reaches 0 the ImageFiltered node
// is skipped entirely. All motion is plain 2D Transform (translate / scale
// / rotate) — cheap, GPU-composited, no shader work except the one-shot
// sweep. The controller runs on the engine's vsync (SchedulerBinding), so
// it automatically tracks 90/120Hz panels and falls back to 60Hz
// gracefully — no manual FPS logic needed.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // ── Timeline (tuned to land at ~2200ms total) ──────────────────────────
  static const Duration _scaleIn    = Duration(milliseconds: 450);
  static const Duration _wobble1End = Duration(milliseconds: 650);
  static const Duration _wobble2End = Duration(milliseconds: 900);
  static const Duration _wobble3End = Duration(milliseconds: 1100);
  static const Duration _pulseEnd   = Duration(milliseconds: 1300);
  static const Duration _sweepStart = Duration(milliseconds: 1300);
  static const Duration _sweepDur   = Duration(milliseconds: 350);
  static const Duration _hold       = Duration(milliseconds: 250);
  static const Duration _handoff    = Duration(milliseconds: 300);

  late final Duration _sweepEnd = _sweepStart + _sweepDur;
  late final Duration _holdEnd  = _pulseEnd + _hold;
  late final Duration _total    = _holdEnd + _handoff;

  late final AnimationController _ctrl;

  late final Animation<double> _markScale;  // entrance scale-in w/ overshoot
  late final Animation<double> _markTilt;   // the settle wobble, in degrees
  late final Animation<double> _markPulse;  // the one breathing beat
  late final Animation<double> _opacity;
  late final Animation<double> _blur;
  late final Animation<double> _ringRotation; // continuous, independent
  late final Animation<double> _ringGlow;     // 0 → 1 ring opacity envelope
  late final Animation<double> _sweep;
  late final Animation<double> _handoffT;

  bool _showChild = false;

  double _f(Duration d) => (d.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    _markScale = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.70, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: _scaleIn.inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: (_total.inMilliseconds - _scaleIn.inMilliseconds).toDouble(),
      ),
    ]).animate(_ctrl);

    // The settle wobble: 0° → -6° → +3° → 0°, each leg eased, reading as
    // the mark finding its balance rather than spinning.
    _markTilt = TweenSequence([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: _scaleIn.inMilliseconds.toDouble()),
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -6.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: (_wobble1End - _scaleIn).inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween(begin: -6.0, end: 3.0).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: (_wobble2End - _wobble1End).inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween(begin: 3.0, end: 0.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: (_wobble3End - _wobble2End).inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween(0.0),
        weight: (_total.inMilliseconds - _wobble3End.inMilliseconds).toDouble(),
      ),
    ]).animate(_ctrl);

    // One gentle breathing pulse after the wobble settles — a single beat
    // of life, never repeating.
    _markPulse = TweenSequence([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: _wobble3End.inMilliseconds.toDouble()),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.03).chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: ((_pulseEnd - _wobble3End).inMilliseconds / 2).toDouble(),
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.03, end: 1.0).chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: ((_pulseEnd - _wobble3End).inMilliseconds / 2).toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: (_total.inMilliseconds - _pulseEnd.inMilliseconds).toDouble(),
      ),
    ]).animate(_ctrl);

    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(const Duration(milliseconds: 380)), curve: Curves.easeOut),
      ),
    );

    _blur = Tween(begin: 2.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(const Duration(milliseconds: 340)), curve: Curves.easeOut),
      ),
    );

    // The ring behind the mark rotates continuously and independently —
    // its own layer, its own motion, never synced to the mark's wobble.
    _ringRotation = Tween(begin: 0.0, end: 2 * math.pi * 0.65).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.linear),
    );

    _ringGlow = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: _scaleIn.inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: (_total.inMilliseconds - _scaleIn.inMilliseconds).toDouble(),
      ),
    ]).animate(_ctrl);

    _sweep = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_sweepStart), _f(_sweepEnd), curve: Curves.easeInOutCubic),
    );

    _handoffT = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_holdEnd), 1.0, curve: Curves.easeInOutCubic),
    );

    _ctrl.forward();
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _showChild = true);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showChild) return widget.child;

    final themeProvider  = context.watch<ThemeProvider>();
    final platformIsDark = Theme.of(context).brightness == Brightness.dark;
    final isDark         = themeProvider.mode == AurumThemeMode.system
        ? platformIsDark
        : themeProvider.mode != AurumThemeMode.light;

    // Pure AMOLED black in dark mode (per spec), clean warm white in light.
    final bg = isDark ? AurumTheme.amoledBg : AurumTheme.lightBg;

    final gold = isDark ? AurumTheme.goldLight : AurumTheme.gold;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            // ── Background ─────────────────────────────────────────────
            ColoredBox(color: bg),

            // ── Splash content, cross-fades out during handoff ─────────
            Opacity(
              opacity: 1.0 - _handoffT.value,
              child: Center(
                child: RepaintBoundary(
                  child: _ChoreographedLogo(
                    markScale:    _markScale.value,
                    markTiltDeg:  _markTilt.value,
                    markPulse:    _markPulse.value,
                    opacity:      _opacity.value,
                    blur:         _blur.value,
                    ringRotation: _ringRotation.value,
                    ringGlow:     _ringGlow.value,
                    sweep:        _sweep.value,
                    gold:         gold,
                  ),
                ),
              ),
            ),

            // ── Incoming app, cross-fades in during handoff ─────────────
            if (_handoffT.value > 0.0)
              Opacity(
                opacity: _handoffT.value,
                child: widget.child,
              ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ChoreographedLogo — two independent layers:
//   1. a soft glow ring behind the mark that rotates continuously on its
//      own, entirely independent of the mark's motion
//   2. the mark itself: scales in with overshoot, performs one settle
//      wobble, then one gentle breathing pulse, then a single light sweep
// ─────────────────────────────────────────────────────────────────────────────
class _ChoreographedLogo extends StatelessWidget {
  final double markScale;
  final double markTiltDeg;
  final double markPulse;
  final double opacity;
  final double blur;
  final double ringRotation; // radians, continuous
  final double ringGlow;     // 0 → 1 envelope
  final double sweep;
  final Color  gold;

  const _ChoreographedLogo({
    required this.markScale,
    required this.markTiltDeg,
    required this.markPulse,
    required this.opacity,
    required this.blur,
    required this.ringRotation,
    required this.ringGlow,
    required this.sweep,
    required this.gold,
  });

  @override
  Widget build(BuildContext context) {
    const double logoSize = 116;
    final glowOpacity = (0.10 + 0.05 * ringGlow).clamp(0.0, 0.15);

    Widget mark = SizedBox(
      width: logoSize,
      height: logoSize,
      child: Image.asset(
        'assets/images/aurum_logo.png',
        fit: BoxFit.contain,
      ),
    );

    // Single premium highlight sweep — only built while active.
    if (sweep > 0.0 && sweep < 1.0) {
      mark = ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          const band = 0.35;
          final center = -band + (1 + 2 * band) * sweep;
          final s0 = (center - band).clamp(0.0, 1.0);
          final s1 = center.clamp(s0 + 0.001, 1.0);
          final s2 = (center + band).clamp(s1 + 0.001, 1.0);
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.white.withOpacity(0.0),
              Colors.white.withOpacity(0.55),
              Colors.white.withOpacity(0.0),
            ],
            stops: [s0, s1, s2],
          ).createShader(rect);
        },
        child: mark,
      );
    }

    // Layer 1: the glow ring — its own rotation, its own RepaintBoundary,
    // completely decoupled from the mark's transforms above it.
    final ring = RepaintBoundary(
      child: Transform.rotate(
        angle: ringRotation,
        child: CustomPaint(
          size: const Size(logoSize * 2.1, logoSize * 2.1),
          painter: _RingGlowPainter(color: gold, opacity: glowOpacity),
        ),
      ),
    );

    // Layer 2: the mark — scale (entrance + pulse combined), then tilt.
    Widget markLayer = Transform.rotate(
      angle: markTiltDeg * (math.pi / 180.0),
      child: Transform.scale(
        scale: markScale * markPulse,
        child: mark,
      ),
    );

    if (blur > 0.01) {
      markLayer = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: markLayer,
      );
    }

    return Opacity(
      opacity: opacity,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ring,
          markLayer,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _RingGlowPainter — a soft radial halo. Painted rather than a Container
// decoration so it can live cheaply inside its own rotating Transform
// without needing a BoxDecoration rebuild.
// ─────────────────────────────────────────────────────────────────────────────
class _RingGlowPainter extends CustomPainter {
  final Color  color;
  final double opacity;

  _RingGlowPainter({required this.color, required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.001) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          color.withOpacity(opacity),
          color.withOpacity(0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RingGlowPainter old) =>
      old.color != color || old.opacity != opacity;
}
