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
// SplashScreen — flagship edition (minimal, premium, ~1.8s).
// ─────────────────────────────────────────────────────────────────────────────
//
// Design intent: calm, confident, luxurious — with one signature move: the
// mark rests dead-centre the entire time (no drop, no jump, no bounce) and
// slowly, smoothly spins flat in its own plane — like a soap bubble turning
// in still air — decelerating the whole way until it drifts to a stop
// exactly upright. No 3D flip, no squeeze, no distortion: it's a plain
// rotation, so the mark's shape and size stay constant at every frame.
// Sequence:
//
//   0ms                  logo begins: 0 opacity, 2px blur, centred, rotated
//                        -50° (about to start its slow turn)
//   0–1150ms             smooth flat rotation from -50° to 0°, decelerating
//                        continuously (fast-ish start, glacially slow
//                        finish) so it drifts to rest rather than snapping —
//                        the bubble-settle feel
//   0–420ms               opacity 0→1, blur 2px→0 (ease-out) — resolves into
//                        focus early, while still turning
//   0–1150ms              ultra-soft radial glow (8–12% opacity) breathes in
//                        alongside the turn and settles with it
//   950–1300ms            a single soft gradient highlight sweeps across the
//                        face of the mark once it's essentially still, like
//                        light catching brushed metal — never repeats
//   1150–1500ms           brief confident hold on the settled mark
//   1500–1800ms           seamless shared-element style handoff: splash
//                        cross-fades directly into the home screen's first
//                        frame (no wipe, no zoom-out flash)
//
// Total: ~1.8s.
//
// Perf: a single AnimationController drives every value via CurvedAnimation
// / Interval — no nested controllers, no per-frame allocations. The glow and
// logo each sit behind their own RepaintBoundary so repaints never cascade
// into the rest of the tree. ImageFiltered blur is only active while
// blur > 0 (first ~200ms) — once it reaches 0 the ImageFiltered node is
// skipped entirely. The spin is a single Transform.rotate (2D, no
// perspective matrix) — cheap, GPU-composited, no shader work. The
// controller runs on the engine's vsync (SchedulerBinding), so it
// automatically tracks 90/120Hz panels and falls back to 60Hz gracefully —
// no manual FPS logic needed.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // ── Timeline (tuned to land at ~1800ms total) ──────────────────────────
  static const Duration _spin       = Duration(milliseconds: 1150);
  static const Duration _sweepStart = Duration(milliseconds: 950);
  static const Duration _sweepDur   = Duration(milliseconds: 350);
  static const Duration _hold       = Duration(milliseconds: 350);
  static const Duration _handoff    = Duration(milliseconds: 300);

  late final Duration _sweepEnd = _sweepStart + _sweepDur;
  late final Duration _holdEnd  = _spin + _hold;
  late final Duration _total    = _holdEnd + _handoff;

  late final AnimationController _ctrl;

  late final Animation<double> _spinT;   // 0 → 1, drives the flat rotation
  late final Animation<double> _opacity; // 0 → 1
  late final Animation<double> _blur;    // 2.0 → 0.0
  late final Animation<double> _glow;    // 0 → 1 (radial glow envelope)
  late final Animation<double> _sweep;   // 0 → 1, single pass across logo
  late final Animation<double> _handoffT; // 0 → 1, cross-fade into child

  bool _showChild = false;

  double _f(Duration d) => (d.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    // Continuously decelerating — brisk at first, then drifts to a dead
    // stop like a bubble losing momentum in still air. No overshoot, no
    // snap-back: it simply runs out of energy exactly at 0°.
    _spinT = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _f(_spin), curve: Curves.easeOutExpo),
    );

    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(const Duration(milliseconds: 420)), curve: Curves.easeOut),
      ),
    );

    _blur = Tween(begin: 2.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(const Duration(milliseconds: 380)), curve: Curves.easeOut),
      ),
    );

    // Glow breathes in alongside the spin and settles with it — never
    // overshoots past its 8–12% ceiling, no pulsing.
    _glow = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: _spin.inMilliseconds.toDouble(),
      ),
      TweenSequenceItem(
        tween: ConstantTween(1.0),
        weight: (_total.inMilliseconds - _spin.inMilliseconds).toDouble(),
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
                  child: _GlowLogo(
                    spin:    _spinT.value,
                    opacity: _opacity.value,
                    blur:    _blur.value,
                    glow:    _glow.value,
                    sweep:   _sweep.value,
                    gold:    gold,
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
// _GlowLogo — logo image + soft radial glow + slow flat 2D spin (bubble
// settle) + single gradient sweep once fully still.
// ─────────────────────────────────────────────────────────────────────────────
class _GlowLogo extends StatelessWidget {
  final double spin;    // 0 → 1, drives the flat rotation
  final double opacity;
  final double blur;
  final double glow;
  final double sweep;
  final Color  gold;

  // Starts turned -50° and drifts to 0° — a gentle, single, decelerating
  // turn rather than multiple full spins. Reads as calm, not playful.
  static const double _startDeg = -50.0;

  const _GlowLogo({
    required this.spin,
    required this.opacity,
    required this.blur,
    required this.glow,
    required this.sweep,
    required this.gold,
  });

  @override
  Widget build(BuildContext context) {
    const double logoSize = 116;
    final glowOpacity = 0.08 + 0.04 * glow; // 8% → 12%, settles, never pulses

    // Flat, in-plane rotation only — no perspective, no squeeze. The mark's
    // width/height never change, it simply turns like a bubble drifting to
    // rest.
    final angle = (_startDeg * (1.0 - spin)) * (math.pi / 180.0);

    Widget mark = SizedBox(
      width: logoSize,
      height: logoSize,
      child: Image.asset(
        'assets/images/aurum_logo.png',
        fit: BoxFit.contain,
      ),
    );

    // Single premium highlight sweep — only built while active, and only
    // once the mark has essentially come to rest.
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

    Widget content = Stack(
      alignment: Alignment.center,
      children: [
        // Ultra-soft radial glow behind the logo.
        IgnorePointer(
          child: Container(
            width: logoSize * 2.1,
            height: logoSize * 2.1,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  gold.withOpacity(glowOpacity),
                  gold.withOpacity(0.0),
                ],
                stops: const [0.0, 1.0],
              ),
            ),
          ),
        ),
        mark,
      ],
    );

    // Blur only costs anything while it's actually non-zero.
    if (blur > 0.01) {
      content = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      );
    }

    return Opacity(
      opacity: opacity,
      child: Transform.rotate(angle: angle, child: content),
    );
  }
}
