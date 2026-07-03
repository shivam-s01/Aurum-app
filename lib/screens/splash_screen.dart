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
// SplashScreen — flagship luxury edition. Exactly 3.0s.
// ─────────────────────────────────────────────────────────────────────────────
//
// The logo itself is never redesigned — same scalloped silhouette, same
// gradient, same note glyph. Only its motion is choreographed. To let the
// outer shape spin while the note glyph stays rotationally still and draws
// itself in, the mark is split into two independently-driven layers:
//
//   • the outer flower silhouette — painted (same 10-lobe scallop + gradient
//     as the launcher icon), spins at high speed with a motion-blur trail
//   • the note glyph — painted as vector strokes (head → stem → flag),
//     revealed progressively in sync with the spin, never rotating itself
//
// Timeline (exact, per spec):
//   0.00–0.30s   background fade-in; mark 85%→100% scale, 0→100% opacity;
//                bloom begins
//   0.30–2.25s   outer ring spins at a perfectly constant 1500°/s — no
//                ramp, no fluctuation, motor-locked rate for the whole
//                window; cinematic 7-copy motion-blur trail, each copy
//                fainter, smaller, and colour-shifted toward blue; note
//                strokes draw in (head, then stem, then flag) with a soft
//                white energy glow while drawing, synced across this window
//   2.25–2.50s   ring eases smoothly to a stop over 250ms (no bounce, no
//                overshoot) — a touch of natural inertia rather than a
//                dead cut; note glyph settles from glowing to crisp solid
//                white
//   2.50–2.68s   one tight, Apple-style glass reflection sweep (180ms)
//   2.50–2.80s   one glow pulse
//   2.80–3.00s   cross-fade handoff into the home screen
//
// Perf: a single AnimationController drives everything via Interval/Curve —
// no secondary controllers. The spinning ring is painted directly (no
// image asset) so the motion-blur trail can be drawn as a handful of
// rotated, opacity-faded copies behind the leading shape — cheap and fully
// GPU-composited, no shader passes. The note strokes are simple stroked
// Paths, revealed progressively rather than re-tessellating a complex
// path each frame. Both layers sit behind their own RepaintBoundary. The
// controller runs on the engine's vsync, so it automatically tracks
// 90/120Hz panels and falls back to 60Hz gracefully.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _total = Duration(milliseconds: 3000);

  static const double _tEntranceEnd = 0.30 / 3.0;
  static const double _tSpinStart   = 0.30 / 3.0;
  static const double _tSpinEnd     = 2.50 / 3.0;
  static const double _tDecelEnd    = 2.50 / 3.0;
  static const double _tPulseEnd    = 2.80 / 3.0;
  static const double _tSweepStart  = 2.50 / 3.0;
  static const double _tSweepEnd    = 2.68 / 3.0; // exactly 180ms after decel ends

  late final AnimationController _ctrl;

  late final Animation<double> _bgOpacity;
  late final Animation<double> _markScale;
  late final Animation<double> _markOpacity;
  late final Animation<double> _bloom;
  late final Animation<double> _ringAngle;    // radians, custom piecewise
  late final Animation<double> _trailFade;    // 1→0 over the last 100ms of spin
  late final Animation<double> _strokeReveal; // 0→1 across the spin window
  late final Animation<double> _pulse;
  late final Animation<double> _sweep;
  late final Animation<double> _handoffT;

  bool _showChild = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    _bgOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOut)),
    );

    _markScale = Tween(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOutCubic)),
    );

    _markOpacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Interval(0.0, _tEntranceEnd, curve: Curves.easeOut)),
    );

    _bloom = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: _tEntranceEnd,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 1.0 - _tEntranceEnd),
    ]).animate(_ctrl);

    // Ring rotation needs a genuine ramp-up → stable-fast → smooth-decel-
    // to-exact-stop profile that no single Curves.* constant expresses, so
    // it's computed directly from the controller's raw t each tick.
    _ringAngle = _DerivedAnimation(_ctrl, _ringAngleFor);
    _trailFade = _DerivedAnimation(_ctrl, _trailFadeFor);

    _strokeReveal = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tSpinStart, _tSpinEnd, curve: Curves.easeInOut),
    );

    _pulse = TweenSequence([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: _tDecelEnd),
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: (_tPulseEnd - _tDecelEnd) / 2,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: (_tPulseEnd - _tDecelEnd) / 2,
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 1.0 - _tPulseEnd),
    ]).animate(_ctrl);

    _sweep = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tSweepStart, _tSweepEnd, curve: Curves.easeInOut),
    );

    _handoffT = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_tPulseEnd, 1.0, curve: Curves.easeInOutCubic),
    );

    _ctrl.forward();
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _showChild = true);
      }
    });
  }

  // Builds the ring-rotation profile:
  //   • before 0.30s: stationary
  //   • 0.30s→2.25s: perfectly constant angular velocity — no ramp-up,
  //     zero fluctuation, a single fixed rate the whole way through, like
  //     a motor spinning at a locked RPM.
  //   • 2.25s→2.50s: a short 250ms ease-out glide down to zero velocity.
  //     A dead instant stop reads mechanically abrupt; premium motion
  //     (Apple/Nothing/Pixel-style) almost always carries a touch of
  //     inertia into the landing. This window is short and tight enough
  //     to stay crisp rather than feeling loose or bouncy — it's a glide,
  //     not a coast.
  //   • after 2.50s: held at the final angle
  static const double _targetDegPerSec = 1500.0; // fixed, constant rate
  static const double _spinEndSeconds  = 2.25;
  static const double _decelEndSeconds = 2.50;   // 250ms ease-out to stop

  double _ringAngleFor(double t) {
    final seconds = t * 3.0;
    if (seconds <= 0.30) return 0.0;

    final targetRadPerSec = _targetDegPerSec * math.pi / 180.0;

    if (seconds <= _spinEndSeconds) {
      return targetRadPerSec * (seconds - 0.30);
    }

    final angleAtSpinEnd = targetRadPerSec * (_spinEndSeconds - 0.30);
    final decelDuration = _decelEndSeconds - _spinEndSeconds; // 0.25s

    if (seconds <= _decelEndSeconds) {
      final localT = ((seconds - _spinEndSeconds) / decelDuration).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(localT);
      return angleAtSpinEnd + targetRadPerSec * decelDuration * eased;
    }

    final decelAngle = targetRadPerSec * decelDuration;
    return angleAtSpinEnd + decelAngle;
  }

  // Motion-blur trail intensity: full strength (1.0) while the ring is at
  // constant speed, then fades to 0 over the final 100ms before the stop
  // (2.40s→2.50s). A trail that's still at full opacity the instant the
  // ring stops reads as a rendering glitch; fading it out in step with the
  // deceleration makes the landing feel physically grounded — the streak
  // shortens as the motion actually slows.
  static const double _trailFadeStart = 2.40; // 100ms before decel ends

  double _trailFadeFor(double t) {
    final seconds = t * 3.0;
    if (seconds <= _trailFadeStart) return 1.0;
    if (seconds >= _decelEndSeconds) return 0.0;
    final localT = (seconds - _trailFadeStart) / (_decelEndSeconds - _trailFadeStart);
    return 1.0 - Curves.easeIn.transform(localT.clamp(0.0, 1.0));
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

    // Spec calls for a clean off-white background; dark mode keeps the
    // app's AMOLED black so the theme system stays consistent elsewhere.
    final bg   = isDark ? AurumTheme.amoledBg : const Color(0xFFFAF8F3);
    final gold = isDark ? AurumTheme.goldLight : AurumTheme.gold;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Opacity(opacity: _bgOpacity.value, child: ColoredBox(color: bg)),
            Opacity(
              opacity: 1.0 - _handoffT.value,
              child: Center(
                child: RepaintBoundary(
                  child: _LuxuryMark(
                    scale:        _markScale.value,
                    opacity:      _markOpacity.value,
                    bloom:        _bloom.value,
                    ringAngle:    _ringAngle.value,
                    trailFade:    _trailFade.value,
                    strokeReveal: _strokeReveal.value,
                    pulse:        _pulse.value,
                    sweep:        _sweep.value,
                    gold:         gold,
                  ),
                ),
              ),
            ),
            if (_handoffT.value > 0.0)
              Opacity(opacity: _handoffT.value, child: widget.child),
          ],
        );
      },
    );
  }
}

// A tiny Animation<double> that recomputes from the parent controller's raw
// value via an arbitrary function, for motion profiles a Tween/Curve can't
// express directly (piecewise ramp → stable → decel-to-stop). Implemented
// directly against Animation<double>'s public contract (no framework-
// internal parent mixin) so its behaviour is fully self-contained and easy
// to verify: it just forwards listener registration to the controller and
// recomputes `value` on every read.
class _DerivedAnimation extends Animation<double> {
  _DerivedAnimation(this._parent, this._f);
  final Animation<double> _parent;
  final double Function(double t) _f;

  @override
  double get value => _f(_parent.value);

  @override
  void addListener(VoidCallback listener) => _parent.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _parent.removeListener(listener);

  @override
  void addStatusListener(AnimationStatusListener listener) =>
      _parent.addStatusListener(listener);

  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      _parent.removeStatusListener(listener);

  @override
  AnimationStatus get status => _parent.status;
}

// ─────────────────────────────────────────────────────────────────────────────
// _LuxuryMark — 18% larger than the launcher footprint per spec. Two
// independent layers: the spinning outer ring (with motion-blur trail) and
// the note glyph (drawn in as strokes, never rotating).
// ─────────────────────────────────────────────────────────────────────────────
class _LuxuryMark extends StatelessWidget {
  final double scale;
  final double opacity;
  final double bloom;
  final double ringAngle;
  final double trailFade;
  final double strokeReveal;
  final double pulse;
  final double sweep;
  final Color  gold;

  // Launcher footprint is 108; sized up further for more center presence.
  static const double _baseSize = 108;
  static const double markSize  = _baseSize * 1.18 * 1.12 * 1.065;

  const _LuxuryMark({
    required this.scale,
    required this.opacity,
    required this.bloom,
    required this.ringAngle,
    required this.trailFade,
    required this.strokeReveal,
    required this.pulse,
    required this.sweep,
    required this.gold,
  });

  @override
  Widget build(BuildContext context) {
    // Restrained, soft bloom — luxury apps keep glow low and diffuse
    // rather than bright, so peak opacity is capped well below the old
    // bright-glow range.
    final glowOpacity = (0.05 + 0.025 * bloom + 0.045 * pulse).clamp(0.0, 0.12);

    final stack = SizedBox(
      width: markSize * 2.0,
      height: markSize * 2.0,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Restrained soft bloom, breathing once more on the final pulse.
          // Wider spread with an earlier fade-out stop reads as a diffuse
          // haze rather than a bright disc — the luxury-app "soft bloom"
          // look instead of a hard glow.
          IgnorePointer(
            child: Container(
              width: markSize * 2.4,
              height: markSize * 2.4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    gold.withOpacity(glowOpacity),
                    gold.withOpacity(glowOpacity * 0.35),
                    gold.withOpacity(0.0),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          // Outer spinning ring, with a motion-blur trail while in motion.
          RepaintBoundary(
            child: CustomPaint(
              size: const Size(markSize, markSize),
              painter: _SpinningRingPainter(angle: ringAngle, trailFade: trailFade),
            ),
          ),
          // Note glyph — strokes reveal progressively, never rotates.
          RepaintBoundary(
            child: CustomPaint(
              size: const Size(markSize, markSize),
              painter: _NoteStrokePainter(reveal: strokeReveal),
            ),
          ),
          // One glass reflection sweep during the final settle.
          if (sweep > 0.0 && sweep < 1.0)
            IgnorePointer(
              child: CustomPaint(
                size: Size(markSize, markSize),
                painter: _GlassSweepPainter(t: sweep),
              ),
            ),
        ],
      ),
    );

    return Opacity(
      opacity: opacity,
      child: Transform.scale(scale: scale * (1.0 + 0.02 * pulse), child: stack),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _SpinningRingPainter — the outer flower silhouette (same 10-lobe scallop
// + gradient as the launcher icon), spinning, with faded rotated copies
// behind the leading shape to read as a cinematic motion-blur trail
// without needing an actual blur shader.
// ─────────────────────────────────────────────────────────────────────────────
class _SpinningRingPainter extends CustomPainter {
  final double angle;
  final double trailFade; // 1→0 in the final 100ms before the stop
  _SpinningRingPainter({required this.angle, required this.trailFade});

  // 6–8 trailing copies (7 used), each progressively fainter, smaller, and
  // more "stretched" toward the blue end of the gradient — reads as a
  // genuine cinematic motion-blur streak rather than a flat repeat.
  static const _trailSteps = 7;
  static const _trailSpacing = 0.052; // radians between trail copies

  static const _gradientColors = [
    Color(0xFFE896C8),
    Color(0xFF9B7AF0),
    Color(0xFF4F8CFF),
  ];
  static const _gradientStops = [0.0, 0.5, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final path = _scallopedPath(size);
    final center = Offset(size.width / 2, size.height / 2);

    // Faded, shrunk, gradient-shifted trail copies — oldest/faintest and
    // smallest first, each one nudged toward the blue/violet end of the
    // palette so the streak itself reads as "stretched" colour.
    for (int i = _trailSteps; i >= 1; i--) {
      final age = i / (_trailSteps + 1); // 0 (newest) → ~1 (oldest)
      final trailAngle = angle - i * _trailSpacing;
      final trailAlpha = (0.16 * (1.0 - age) * trailFade).clamp(0.0, 0.16);
      if (trailAlpha <= 0.004) continue;
      final trailScale = 1.0 - 0.05 * age; // shrinks slightly with age

      final shiftedShader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(_gradientColors[0], _gradientColors[2], age * 0.6)!,
          Color.lerp(_gradientColors[1], _gradientColors[2], age * 0.6)!,
          _gradientColors[2],
        ],
        stops: _gradientStops,
      ).createShader(Offset.zero & size);

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(trailAngle);
      canvas.scale(trailScale);
      canvas.translate(-center.dx, -center.dy);
      canvas.drawPath(
        path,
        Paint()
          ..shader = shiftedShader
          ..color = Colors.white.withOpacity(trailAlpha),
      );
      canvas.restore();
    }

    // Leading, fully-opaque, full-colour shape.
    final leadShader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _gradientColors,
      stops: _gradientStops,
    ).createShader(Offset.zero & size);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawPath(path, Paint()..shader = leadShader);
    canvas.restore();
  }

  Path _scallopedPath(Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2;
    final innerR = outerR * 0.82;
    const lobes = 10;
    final path = Path();
    for (int i = 0; i <= lobes * 2; i++) {
      final a = (i / (lobes * 2)) * 2 * math.pi;
      final r = i.isEven ? outerR : innerR;
      final pt = Offset(center.dx + r * math.cos(a), center.dy + r * math.sin(a));
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_SpinningRingPainter old) =>
      old.angle != angle || old.trailFade != trailFade;
}

// ─────────────────────────────────────────────────────────────────────────────
// _NoteStrokePainter — the eighth-note glyph, revealed as three strokes in
// sequence (head → stem → flag), never rotating. `reveal` sweeps 0→1 across
// the whole spin window; each stroke owns a sub-range of it.
// ─────────────────────────────────────────────────────────────────────────────
class _NoteStrokePainter extends CustomPainter {
  final double reveal;
  _NoteStrokePainter({required this.reveal});

  static const double _headEnd = 0.35;
  static const double _stemEnd = 0.70;
  static const double _flagEnd = 1.0;

  double _phase(double start, double end) =>
      ((reveal - start) / (end - start)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0.001) return;
    final w = size.width, h = size.height;
    final isComplete = reveal >= 0.999;

    // While actively drawing: a soft white "energy" glow behind each
    // stroke, as if it's being generated by the spin. Once complete: a
    // tight, near-zero blur so the glyph reads as crisp solid white.
    final glowSigma = isComplete ? 0.4 : 3.2;
    final glowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, glowSigma);
    final glowStroke = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, glowSigma);

    final fillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 0.4);

    // Head: circle, bottom-left of the glyph — draws as a growing arc.
    final headPhase = _phase(0.0, _headEnd);
    if (headPhase > 0) {
      final headCenter = Offset(w * 0.42, h * 0.68);
      final headR = w * 0.15;
      canvas.drawArc(
        Rect.fromCircle(center: headCenter, radius: headR),
        -math.pi / 2,
        2 * math.pi * headPhase,
        false,
        glowStroke..strokeWidth = headR * 1.5,
      );
      if (headPhase >= 1.0) {
        canvas.drawCircle(headCenter, headR, isComplete ? fillPaint : glowPaint);
      }
    }

    // Stem: rises from the head toward the flag.
    final stemPhase = _phase(_headEnd, _stemEnd);
    if (stemPhase > 0) {
      final stemBottom = Offset(w * 0.55, h * 0.66);
      final stemTop    = Offset(w * 0.58, h * 0.22);
      final current = Offset.lerp(stemBottom, stemTop, stemPhase)!;
      canvas.drawLine(
        stemBottom,
        current,
        (isComplete ? fillPaint : glowStroke)
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.075
          ..strokeCap = StrokeCap.round,
      );
    }

    // Flag: triangular pennant off the top of the stem.
    final flagPhase = _phase(_stemEnd, _flagEnd);
    if (flagPhase > 0) {
      final stemTop = Offset(w * 0.58, h * 0.22);
      final flagOut = Offset(w * 0.80, h * 0.32);
      final flagIn  = Offset(w * 0.58, h * 0.42);
      final curOut  = Offset.lerp(stemTop, flagOut, flagPhase)!;
      final curIn   = Offset.lerp(stemTop, flagIn, flagPhase)!;
      final path = Path()
        ..moveTo(stemTop.dx, stemTop.dy)
        ..lineTo(curOut.dx, curOut.dy)
        ..lineTo(curIn.dx, curIn.dy)
        ..close();
      canvas.drawPath(path, isComplete ? fillPaint : glowPaint);
    }
  }

  @override
  bool shouldRepaint(_NoteStrokePainter old) => old.reveal != reveal;
}

// ─────────────────────────────────────────────────────────────────────────────
// _GlassSweepPainter — a single soft diagonal light band crossing the mark
// once, in a tight 180ms window, like light catching glass. Apple-style
// subtle: low opacity, tight band, no lingering.
// ─────────────────────────────────────────────────────────────────────────────
class _GlassSweepPainter extends CustomPainter {
  final double t; // 0 → 1, one pass
  _GlassSweepPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final band = size.width * 0.32;
    final start = -band + (size.width + 2 * band) * t;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(0.0),
          Colors.white.withOpacity(0.22),
          Colors.white.withOpacity(0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(start - band / 2, 0, band, size.height));
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_GlassSweepPainter old) => old.t != t;
}
