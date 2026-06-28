import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const Duration splash = Duration(milliseconds: 650);

  static const Curve enter  = Curves.easeOutCubic;
  static const Curve exit   = Curves.easeInCubic;
  static const Curve smooth = Curves.easeInOutCubic;

  // ── Bespoke splash curves ──────────────────────────────────────────────────

  /// Signature-stroke curve: gentle start, mid-stroke confidence, soft apex
  /// slow-down, then quick confident exit — like ink settling in calligraphy.
  static const Curve signatureStroke = _SignatureStrokeCurve();

  /// Crossbar strike: nearly instant entry, linear body, micro-decel at rest.
  static const Curve crossbarStrike  = _CrossbarStrikeCurve();

  /// Organic settle: very slight overshoot (≈ 2%), then a viscous release.
  /// Feels like weight finding its natural resting point.
  static const Curve organicSettle   = _OrganicSettleCurve();

  /// Letter materialise: blurred ghost → sharp presence, subtle deceleration.
  static const Curve letterIn        = _LetterInCurve();
}

// ── Custom Curve implementations ─────────────────────────────────────────────

/// 4-segment piecewise cubic approximating a natural writing arc.
///   0.0–0.18  slow ink-load
///   0.18–0.52 acceleration through the stroke body
///   0.52–0.74 deceleration near the apex
///   0.74–1.00 confident finishing arc
class _SignatureStrokeCurve extends Curve {
  const _SignatureStrokeCurve();
  @override
  double transformInternal(double t) {
    if (t < 0.18) {
      // gentle ink-load: cubic ease-in
      final s = t / 0.18;
      return 0.04 * s * s * s;
    } else if (t < 0.52) {
      // body acceleration: smooth cubic
      final s = (t - 0.18) / 0.34;
      return 0.04 + 0.46 * (3 * s * s - 2 * s * s * s);
    } else if (t < 0.74) {
      // apex slow-down: ease-out quad
      final s = (t - 0.52) / 0.22;
      return 0.50 + 0.22 * (1 - (1 - s) * (1 - s));
    } else {
      // finishing arc: ease-out cubic
      final s = (t - 0.74) / 0.26;
      final c = 1 - (1 - s);
      return 0.72 + 0.28 * (c * c * (3 - 2 * c));
    }
  }
}

/// Crossbar: short anticipation dip (1%), then crisp ease-out-expo delivery.
class _CrossbarStrikeCurve extends Curve {
  const _CrossbarStrikeCurve();
  @override
  double transformInternal(double t) {
    if (t < 0.06) {
      // micro anticipation: very slight pull-back
      return -0.008 * math.sin(t / 0.06 * math.pi);
    }
    // ease-out expo: fast entry, asymptote to 1
    final s = (t - 0.06) / 0.94;
    return 1.0 - math.pow(2, -10 * s).toDouble();
  }
}

/// Organic settle with ~1.8% overshoot and viscous return.
class _OrganicSettleCurve extends Curve {
  const _OrganicSettleCurve();
  static const double _overshoot = 0.018;
  @override
  double transformInternal(double t) {
    // quintic ease-in to peak + tiny overshoot
    if (t < 0.62) {
      final s = t / 0.62;
      final q = s * s * s * s * s;
      return q * (1 + _overshoot);
    }
    // viscous release back to 1.0
    final s = (t - 0.62) / 0.38;
    return (1 + _overshoot) - _overshoot * (3 * s * s - 2 * s * s * s);
  }
}

/// Letter materialise: fast opacity rise with imperceptible ease-out.
class _LetterInCurve extends Curve {
  const _LetterInCurve();
  @override
  double transformInternal(double t) {
    // Modified ease-out-quart: snappy but not robotic
    final inv = 1 - t;
    return 1 - inv * inv * inv * inv * (1 + 0.12 * t);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen
// ─────────────────────────────────────────────────────────────────────────────
//
// Luxury brand-launch splash — flagship edition.
//
// The "A" mark draws itself like a hand signing a signature: both legs
// with natural speed variation (slow load → fast body → decel at apex →
// confident finish), then after a deliberate pause the crossbar strikes
// across with a micro anticipation dip. The instant it locks in, a light
// haptic fires so the moment is felt not just seen.
//
// Post-completion: a three-layer cinematic bloom (soft / core / specular)
// replaces the single-pass flash. While "AURUM" materialises letter by
// letter (each with a subtle blur-in and tiny organic timing variation),
// the mark keeps a layered ambient breathing glow — two sine waves at
// different frequencies driving intensity, radius and opacity so the
// breathing is never mechanically sinusoidal. A microscopic specular
// highlight drifts almost imperceptibly across the gold strokes.
//
// The exit has the splash recede (scale up + fade), the app rise to meet
// the viewer (scale down from 1.04), and a very subtle vignette dissolve
// so the boundary between scenes is felt, not seen.
//
// Architecture: single AnimationController, all Animation<double> derived
// via Interval + custom curves. CustomPainter reuses Paint objects and
// caches gradient rects. RepaintBoundary isolates the mark and wordmark
// from each other and from the background.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const String _word = 'AURUM';

  // ── Timing map (ms from t=0) ───────────────────────────────────────────────
  //   0       legs stroke begins (left foot → apex → right foot)
  //   800     legs complete  ← slightly longer for richer signature curve
  //   900     crossbar begins (100ms pause = hand breath before bar)
  //   1110    crossbar complete → settle starts, haptic fires
  //   1460    logo settled → cinematic bloom begins
  //   1680    bloom fades → ambient breathing active, first letter starts
  //   1680+   letters stagger in, 140ms apart, 420ms each, all organic
  //   +170    full-word glow pulse (subtle, single pass)
  //   +340    pulse end
  //   +120    word zoom breath 1.035× peak
  //   +250    zoom settle → hold
  //   +300    hold complete → EXIT begins
  //   +500    exit complete
  static const Duration _legsDraw      = Duration(milliseconds: 800);
  static const Duration _barPause      = Duration(milliseconds: 100);
  static const Duration _barDraw       = Duration(milliseconds: 210);
  static const Duration _settleStart   = Duration(milliseconds: 1110);
  static const Duration _settleEnd     = Duration(milliseconds: 1460);
  static const Duration _bloomEnd      = Duration(milliseconds: 1680);
  static const Duration _letterStart   = Duration(milliseconds: 1680);
  static const Duration _letterStagger = Duration(milliseconds: 100);
  static const Duration _letterIn      = Duration(milliseconds: 280);

  late final Duration _barStart    = _legsDraw + _barPause;
  late final Duration _barEnd      = _barStart + _barDraw;

  late final Duration _lettersDone = _letterStart + Duration(
    milliseconds: _letterStagger.inMilliseconds * (_word.length - 1) +
        _letterIn.inMilliseconds,
  );
  late final Duration _pulseStart  = _lettersDone  + const Duration(milliseconds: 170);
  late final Duration _pulseEnd    = _pulseStart   + const Duration(milliseconds: 340);
  late final Duration _zoomStart   = _pulseEnd     + const Duration(milliseconds: 120);
  late final Duration _zoomPeak    = _zoomStart    + const Duration(milliseconds: 250);
  late final Duration _zoomSettle  = _zoomPeak     + const Duration(milliseconds: 240);
  late final Duration _holdEnd     = _zoomSettle   + const Duration(milliseconds: 80);
  late final Duration _exitEnd     = _holdEnd      + const Duration(milliseconds: 280);

  late final Duration _total = _exitEnd;

  // ── Single controller ──────────────────────────────────────────────────────
  late AnimationController _ctrl;

  // Mark
  late Animation<double> _legsProgress;   // 0→1 both legs
  late Animation<double> _barProgress;    // 0→1 crossbar
  late Animation<double> _logoFade;       // 0→1
  late Animation<double> _logoScale;      // 0.62→1.0
  late Animation<double> _logoRotation;   // settle micro-rotation

  // Post-completion effects
  late Animation<double> _bloom;          // 0→1→0 cinematic bloom envelope
  late Animation<double> _energyRipple;   // 0→1→0 metallic energy through bar

  // Wordmark
  late Animation<double> _wordZoom;       // 1.0→1.035→1.0

  // Exit
  late Animation<double> _exitFade;       // 1→0
  late Animation<double> _exitScale;      // 1.0→1.055
  late Animation<double> _childScale;     // 1.04→1.0

  bool   _showChild    = false;
  bool   _exiting      = false;
  bool   _hapticFired  = false;

  /// Normalise a Duration to [0,1] in the total timeline.
  double _f(Duration d) =>
      (d.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);
    _buildAnimations();
    _ctrl.forward().then((_) {
      if (mounted) setState(() => _showChild = true);
    });
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _exiting = true);
      }
    });
    _ctrl.addListener(_maybeFireHaptic);
  }

  void _buildAnimations() {
    // ── Legs: signature-stroke curve gives natural speed variation ─────────
    _legsProgress = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _f(_legsDraw), curve: AurumMotion.signatureStroke),
    );

    // ── Crossbar: micro anticipation dip, then crisp delivery ─────────────
    _barProgress = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_barStart), _f(_barEnd), curve: AurumMotion.crossbarStrike),
    );

    // ── Logo entrance: fade-in completes before stroke is visible ─────────
    _logoFade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _f(const Duration(milliseconds: 120)),
          curve: Curves.easeOut),
    ));

    // ── Scale: organic settle with micro overshoot ─────────────────────────
    _logoScale = Tween(begin: 0.62, end: 1.0).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _f(_settleEnd), curve: AurumMotion.organicSettle),
    ));

    // ── Rotation: weighted settle — overshoots ~3.5°, eases back ──────────
    _logoRotation = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -0.061)      // ~−3.5°
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -0.061, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: 45,
      ),
    ]).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_settleStart), _f(_settleEnd), curve: Curves.linear),
    ));

    // ── Bloom envelope: three-layer rendering handled in painter ──────────
    // Outer soft bloom rises slowly, core bloom sharper, specular fastest.
    // The envelope here is just one 0→1→0 value; painter uses it with
    // three different exponents to achieve the layered feel without extra
    // Animation objects.
    _bloom = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOutQuart)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 70,
      ),
    ]).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_settleEnd), _f(_bloomEnd), curve: Curves.linear),
    ));

    // ── Energy ripple: metallic pulse travelling through the mark ─────────
    // Starts right when the crossbar completes, fades within ~280ms.
    // In the painter this drives a very subtle gradient shift — not a glow.
    final rippleEnd = _barEnd + const Duration(milliseconds: 280);
    _energyRipple = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 75,
      ),
    ]).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_barEnd), _f(rippleEnd), curve: Curves.linear),
    ));

    // ── Word zoom breath ───────────────────────────────────────────────────
    _wordZoom = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.035)
            .chain(CurveTween(curve: Curves.easeOutSine)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.035, end: 1.0)
            .chain(CurveTween(curve: Curves.easeInOutSine)),
        weight: 1,
      ),
    ]).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_zoomStart), _f(_zoomSettle), curve: Curves.linear),
    ));

    // ── Exit: splash recedes, app rises ───────────────────────────────────
    _exitFade = Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_holdEnd), 1.0, curve: Curves.easeInOutQuart),
    ));
    _exitScale = Tween(begin: 1.0, end: 1.055).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_holdEnd), 1.0, curve: Curves.easeInCubic),
    ));
    _childScale = Tween(begin: 1.04, end: 1.0).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(_f(_holdEnd), 1.0, curve: Curves.easeOutCubic),
    ));
  }

  // ── Haptic: fires once when the mark "locks" (crossbar settle begins) ────
  void _maybeFireHaptic() {
    if (_hapticFired) return;
    if (_ctrl.value >= _f(_settleStart)) {
      _hapticFired = true;
      HapticFeedback.lightImpact();
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_maybeFireHaptic);
    _ctrl.dispose();
    super.dispose();
  }

  // ── Word pulse glow (triangle wave, 0→1→0) ────────────────────────────────
  double _wordPulseGlow(double t) {
    final start = _f(_pulseStart), end = _f(_pulseEnd);
    if (t < start || t > end) return 0.0;
    final local = (t - start) / (end - start);
    // Smooth the triangle with a sine so it doesn't click at the peak.
    return math.sin(local * math.pi);
  }

  // ── Layered ambient breath ─────────────────────────────────────────────────
  // Three overlapping sine waves at prime-ratio frequencies so the
  // composite breathing pattern never exactly repeats within the splash
  // window. Individually each is barely perceptible; combined they read
  // as a living, organic glow rather than mechanical pulsing.
  //
  // Returns _AurumBreath with independent intensity, radius, and opacity
  // offsets so the painter can use them separately.
  _AurumBreath _computeBreath(double elapsedMs) {
    // Wave 1: slow primary breath (2200 ms cycle)
    final p1 = (elapsedMs % 2200.0) / 2200.0;
    final w1 = (math.sin(p1 * 2 * math.pi) + 1) / 2;

    // Wave 2: slightly faster secondary (1600 ms, 37% amplitude)
    final p2 = (elapsedMs % 1600.0) / 1600.0;
    final w2 = (math.sin(p2 * 2 * math.pi) + 1) / 2;

    // Wave 3: fast shimmer (900 ms, 15% amplitude — drives specular drift)
    final p3 = (elapsedMs % 900.0) / 900.0;
    final w3 = (math.sin(p3 * 2 * math.pi) + 1) / 2;

    // Composite values, each normalised to 0..1
    final intensity = (w1 * 0.60 + w2 * 0.30 + w3 * 0.10).clamp(0.0, 1.0);
    final radiusVar = (w1 * 0.55 + w2 * 0.45).clamp(0.0, 1.0);
    final opacityVar = (w1 * 0.70 + w3 * 0.30).clamp(0.0, 1.0);

    // Specular drift: slow horizontal sweep via wave1 + wave3 phase mix
    final specularT = ((w1 * 0.65 + w3 * 0.35)).clamp(0.0, 1.0);

    return _AurumBreath(intensity, radiusVar, opacityVar, specularT);
  }

  // ── Vignette strength: rises gently from 0 at entry to 0.18 at steady ─────
  double _vignetteStrength(double t) {
    // Reaches full vignette by the time the logo has settled.
    return (t / _f(_settleEnd)).clamp(0.0, 1.0) * 0.18;
  }

  @override
  Widget build(BuildContext context) {
    // Once the animation is done and the child is ready, swap cleanly.
    if (_showChild && _exiting) return widget.child;

    // ── Theme resolution ────────────────────────────────────────────────────
    final themeProvider  = context.watch<ThemeProvider>();
    final platformIsDark = Theme.of(context).brightness == Brightness.dark;
    final isAmoled       = themeProvider.isAmoled;
    final isDark         = themeProvider.mode == AurumThemeMode.system
        ? platformIsDark
        : themeProvider.mode != AurumThemeMode.light;

    final gold     = isDark ? AurumTheme.goldLight : AurumTheme.goldDark;
    final goldSoft = isDark
        ? AurumTheme.goldLight.withOpacity(0.90)
        : AurumTheme.gold;

    // AMOLED: pure #000 — no gradient, saves battery and boosts perceived
    // depth of the gold strokes dramatically.
    final bgGradient = isAmoled
        ? const LinearGradient(colors: [Color(0xFF000000), Color(0xFF000000)])
        : isDark
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AurumTheme.darkBg, AurumTheme.darkBgElevated, AurumTheme.darkBg],
              )
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AurumTheme.lightBg, AurumTheme.lightBgElevated, AurumTheme.lightBg],
              );

    return Stack(
      children: [
        // ── Incoming child — rises from behind ────────────────────────────
        if (_showChild)
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Transform.scale(
              scale: _exiting ? _childScale.value : 1.04,
              child: widget.child,
            ),
          ),

        // ── Splash scene ──────────────────────────────────────────────────
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            final opacity = _exiting ? _exitFade.value : 1.0;
            if (opacity <= 0.005) return const SizedBox.shrink();

            final scale      = _exiting ? _exitScale.value : 1.0;
            final t          = _ctrl.value;
            final elapsedMs  = t * _total.inMilliseconds;

            // Ambient breath: active between bloom-end and exit.
            final breathActive = t >= _f(_bloomEnd) && t < _f(_holdEnd);
            final breath       = breathActive
                ? _computeBreath(elapsedMs)
                : _AurumBreath.zero;

            final vignette = _vignetteStrength(t);

            return Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: scale,
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Container(
                    decoration: BoxDecoration(gradient: bgGradient),
                    child: Stack(
                      children: [
                        // ── Ambient radial glow — tied to breath ─────────
                        if (breathActive)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: _AmbientField(
                                breath: breath,
                                gold: gold,
                              ),
                            ),
                          ),

                        // ── Vignette — extremely subtle depth ─────────────
                        if (vignette > 0.001)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: RadialGradient(
                                    center: Alignment.center,
                                    radius: 1.2,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black.withOpacity(vignette),
                                    ],
                                    stops: const [0.55, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ),

                        // ── Logo + wordmark (centre column) ──────────────
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              RepaintBoundary(
                                child: Transform.rotate(
                                  angle: _logoRotation.value,
                                  child: Transform.scale(
                                    scale: _logoScale.value,
                                    child: Opacity(
                                      opacity: _logoFade.value,
                                      child: _AurumMark(
                                        legsProgress:  _legsProgress.value,
                                        barProgress:   _barProgress.value,
                                        bloom:         _bloom.value,
                                        energyRipple:  _energyRipple.value,
                                        breath:        breath,
                                        gold:          gold,
                                        goldSoft:      goldSoft,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 28),
                              RepaintBoundary(
                                child: Transform.scale(
                                  scale: _wordZoom.value,
                                  child: _AurumWordmark(
                                    elapsedMs:      elapsedMs,
                                    letterStartMs:  _letterStart.inMilliseconds,
                                    letterStaggerMs: _letterStagger.inMilliseconds,
                                    letterInMs:     _letterIn.inMilliseconds,
                                    pulseGlow:      _wordPulseGlow(t),
                                    gold:           gold,
                                    goldSoft:       goldSoft,
                                    word:           _word,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AurumBreath — composite breathing state passed from state to painters.
// Avoids recomputing the same trig in multiple places per frame.
// ─────────────────────────────────────────────────────────────────────────────
class _AurumBreath {
  final double intensity;   // primary drive  0..1
  final double radiusVar;   // radius offset  0..1
  final double opacityVar;  // opacity offset 0..1
  final double specularT;   // specular drift 0..1

  const _AurumBreath(
      this.intensity, this.radiusVar, this.opacityVar, this.specularT);

  static const zero = _AurumBreath(0, 0, 0, 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// _AmbientField — the soft radial pool of light behind the mark.
// ─────────────────────────────────────────────────────────────────────────────
// Drawn as a StatelessWidget so it gets its own RepaintBoundary context
// without any rebuild cost beyond the CustomPaint repaint trigger.
class _AmbientField extends StatelessWidget {
  final _AurumBreath breath;
  final Color gold;

  const _AmbientField({required this.breath, required this.gold});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _AmbientFieldPainter(breath: breath, gold: gold));
  }
}

class _AmbientFieldPainter extends CustomPainter {
  final _AurumBreath breath;
  final Color gold;

  // Reuse paint objects across repaints to avoid allocations.
  final Paint _p = Paint();

  _AmbientFieldPainter({required this.breath, required this.gold});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width  / 2;
    final cy = size.height * 0.42; // slightly above centre — mark sits here

    // Outer diffuse halo: large radius, very low opacity, breathes slowly.
    final outerR  = size.width * (0.38 + 0.06 * breath.radiusVar);
    final outerOp = 0.04 + 0.04 * breath.opacityVar;
    _p
      ..color = gold.withOpacity(outerOp)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 38 + 8 * breath.radiusVar);
    canvas.drawCircle(Offset(cx, cy), outerR, _p);

    // Inner halo: tighter radius, moderate opacity, tied to intensity.
    final innerR  = size.width * (0.20 + 0.04 * breath.intensity);
    final innerOp = 0.06 + 0.07 * breath.intensity;
    _p
      ..color = gold.withOpacity(innerOp)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 18 + 4 * breath.intensity);
    canvas.drawCircle(Offset(cx, cy), innerR, _p);
  }

  @override
  bool shouldRepaint(covariant _AmbientFieldPainter old) =>
      old.breath.intensity != breath.intensity ||
      old.breath.radiusVar != breath.radiusVar ||
      old.breath.opacityVar != breath.opacityVar;
}

// ─────────────────────────────────────────────────────────────────────────────
// _AurumMark — the "A" CustomPaint widget
// ─────────────────────────────────────────────────────────────────────────────
class _AurumMark extends StatelessWidget {
  final double        legsProgress;   // 0..1
  final double        barProgress;    // 0..1
  final double        bloom;          // 0→1→0 cinematic bloom envelope
  final double        energyRipple;   // 0→1→0 metallic ripple post-bar
  final _AurumBreath  breath;
  final Color         gold;
  final Color         goldSoft;

  const _AurumMark({
    required this.legsProgress,
    required this.barProgress,
    required this.bloom,
    required this.energyRipple,
    required this.breath,
    required this.gold,
    required this.goldSoft,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: CustomPaint(
        painter: _AurumMarkPainter(
          legsProgress: legsProgress,
          barProgress:  barProgress,
          bloom:        bloom,
          energyRipple: energyRipple,
          breath:       breath,
          gold:         gold,
          goldSoft:     goldSoft,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AurumMarkPainter
// ─────────────────────────────────────────────────────────────────────────────
class _AurumMarkPainter extends CustomPainter {
  final double       legsProgress;
  final double       barProgress;
  final double       bloom;
  final double       energyRipple;
  final _AurumBreath breath;
  final Color        gold;
  final Color        goldSoft;

  // ── Cached Paint objects (allocated once) ─────────────────────────────────
  final Paint _haloPaint    = Paint();
  final Paint _glowPaint    = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _strokePaint  = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint _bloomPaint   = Paint();
  final Paint _ripplePaint  = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  _AurumMarkPainter({
    required this.legsProgress,
    required this.barProgress,
    required this.bloom,
    required this.energyRipple,
    required this.breath,
    required this.gold,
    required this.goldSoft,
  });

  // ── Geometry ──────────────────────────────────────────────────────────────

  /// Both legs as one continuous stroke: left foot → apex → right foot.
  /// The stroke-order mirrors the natural human signature motion.
  Path _buildLegs(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.08, h * 0.94)
      ..lineTo(w * 0.50, h * 0.06)
      ..lineTo(w * 0.92, h * 0.94);
  }

  /// Crossbar, separate stroke for timed entry.
  Path _buildBar(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.27, h * 0.62)
      ..lineTo(w * 0.73, h * 0.62);
  }

  /// Extract the leading [progress] fraction of a Path by arc-length.
  Path _partialPath(Path full, double progress) {
    if (progress <= 0) return Path();
    final metrics    = full.computeMetrics().toList();
    final totalLen   = metrics.fold<double>(0, (s, m) => s + m.length);
    final targetLen  = totalLen * progress;
    final out        = Path();
    double consumed  = 0;
    for (final m in metrics) {
      if (consumed >= targetLen) break;
      final take = math.min(m.length, targetLen - consumed);
      out.addPath(m.extractPath(0, take), Offset.zero);
      consumed += m.length;
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final legs      = _partialPath(_buildLegs(size), legsProgress);
    final bar       = _partialPath(_buildBar(size),  barProgress);
    final drawn     = Path()..addPath(legs, Offset.zero)..addPath(bar, Offset.zero);

    final sw        = size.width * 0.085;            // stroke width
    final center    = Offset(size.width / 2, size.height / 2);
    final bounds    = Rect.fromLTWH(0, 0, size.width, size.height);

    // ── 1. Ambient halo from mark painter (inner tight halo on the stroke) ─
    if (breath.intensity > 0.001) {
      final haloR  = size.width * (0.30 + 0.03 * breath.radiusVar);
      final haloOp = 0.16 + 0.10 * breath.intensity;
      _haloPaint
        ..color = gold.withOpacity(haloOp)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 16 + 6 * breath.intensity);
      canvas.drawCircle(center, haloR, _haloPaint);
    }

    // ── 2. Soft diffuse glow under the stroke (jewelry-case light) ─────────
    if (legsProgress > 0.005 || barProgress > 0.005) {
      _glowPaint
        ..color = gold.withOpacity(0.26)
        ..strokeWidth = sw * 2.6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawPath(drawn, _glowPaint);
    }

    // ── 3. Crisp gold stroke — linear gradient top→bottom (top lighter) ────
    // The gradient is recreated only when the size changes; for 120×120 this
    // is once. On repaint the Shader is reused if bounds are identical.
    _strokePaint
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [goldSoft, gold],
      ).createShader(bounds)
      ..strokeWidth = sw;
    canvas.drawPath(drawn, _strokePaint);

    // ── 4. Specular highlight drift (almost imperceptible) ─────────────────
    // A tiny bright band that moves from the apex downward along the stroke
    // as the breathing specularT advances — like a light catching polished
    // gold as it slowly shifts in space. Kept below 0.12 opacity so it
    // registers as a material quality, not a visible effect.
    if (legsProgress >= 1.0 && breath.specularT > 0.001) {
      final specY  = size.height * (0.06 + 0.30 * breath.specularT); // apex→bar
      final specOp = 0.07 + 0.05 * breath.intensity;
      _haloPaint
        ..color = goldSoft.withOpacity(specOp)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawCircle(Offset(size.width * 0.50, specY), sw * 1.2, _haloPaint);
    }

    // ── 5. Metallic energy ripple (post-crossbar, pre-bloom) ───────────────
    // Not a glow explosion — a very faint luminosity wave that travels
    // from left to right along the bar, like charge conducting through metal.
    // Below 0.15 max opacity; if you blink you'll miss it.
    if (energyRipple > 0.001) {
      final barL   = Offset(size.width * 0.27, size.height * 0.62);
      final barR   = Offset(size.width * 0.73, size.height * 0.62);
      // Ripple midpoint travels left→right as energyRipple 0→1
      final ripX   = barL.dx + (barR.dx - barL.dx) * energyRipple;
      final ripOp  = 0.12 * math.sin(energyRipple * math.pi); // arc up and back
      _haloPaint
        ..color = goldSoft.withOpacity(ripOp)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(Offset(ripX, barL.dy), sw * 0.9, _haloPaint);
    }

    // ── 6. Cinematic bloom — three passes, feathered ───────────────────────
    // Each pass uses a different exponent of the bloom envelope so they
    // peak at different intensities: soft outer peaks last, core peaks
    // first, specular (white) is briefest and brightest.
    if (bloom > 0.001) {
      final b = bloom;

      // Soft outer bloom: large radius, warm gold, low opacity
      _bloomPaint
        ..color = gold.withOpacity(0.28 * b * b)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 36 * b + 8);
      canvas.drawCircle(center, size.width * 0.40, _bloomPaint);

      // Core bloom: mid radius, stronger gold
      _bloomPaint
        ..color = gold.withOpacity(0.42 * math.pow(b, 1.5).toDouble())
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 18 * b + 4);
      canvas.drawCircle(center, size.width * 0.26, _bloomPaint);

      // Specular bloom: tiny, near-white, fast-decaying — the "moment of
      // light catching polished metal" — peaks sharply then vanishes.
      final specB = math.pow(b, 0.45).toDouble(); // peaks earlier
      _bloomPaint
        ..color = Colors.white.withOpacity(0.22 * specB)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * b + 2);
      canvas.drawCircle(center, size.width * 0.14, _bloomPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AurumMarkPainter old) =>
      old.legsProgress != legsProgress ||
      old.barProgress  != barProgress  ||
      old.bloom        != bloom        ||
      old.energyRipple != energyRipple ||
      old.breath.intensity  != breath.intensity  ||
      old.breath.specularT  != breath.specularT  ||
      old.breath.radiusVar  != breath.radiusVar;
}

// ─────────────────────────────────────────────────────────────────────────────
// _AurumWordmark — "AURUM" letter by letter
// ─────────────────────────────────────────────────────────────────────────────
//
// Each letter:
//   • Begins with a subtle Gaussian blur (ImageFilter.blur is expensive;
//     we approximate the effect by using a very faint shadow with wide
//     blurRadius on entry and tight blurRadius at rest — no ImageFilter
//     needed, same visual read at zero allocation cost).
//   • Rises only 8px (tighter than the original 12, feels more premium).
//   • Has a tiny timing offset unique to its index so no two letters are
//     mechanically identical (prime-based jitter: 0ms, 7ms, 3ms, 11ms, 5ms).
//   • Has a slightly different easing character: odd-index letters ease out
//     fractionally slower — too subtle to consciously notice but enough to
//     prevent the row feeling like a single looping CSS animation.
//
// The full-word glow pulse drives the shadow blurRadius (not opacity) so
// it reads as the word briefly becoming more luminous, not just brighter.
class _AurumWordmark extends StatelessWidget {
  final double elapsedMs;
  final int    letterStartMs;
  final int    letterStaggerMs;
  final int    letterInMs;
  final double pulseGlow;     // 0→1→0
  final Color  gold;
  final Color  goldSoft;
  final String word;

  // Per-letter ms jitter (keeps each letter subtly non-identical).
  static const List<int> _jitterMs = [0, 7, 3, 11, 5];

  // Per-letter easing: odd indices settle fractionally slower.
  static List<Curve> _letterCurves = [
    AurumMotion.letterIn,                            // A
    _SlightlySlowerCurve(AurumMotion.letterIn),      // U
    AurumMotion.letterIn,                            // R
    _SlightlySlowerCurve(AurumMotion.letterIn),      // U
    AurumMotion.letterIn,                            // M
  ];

  const _AurumWordmark({
    required this.elapsedMs,
    required this.letterStartMs,
    required this.letterStaggerMs,
    required this.letterInMs,
    required this.pulseGlow,
    required this.gold,
    required this.goldSoft,
    required this.word,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(word.length, (i) {
        final jitter  = i < _jitterMs.length ? _jitterMs[i] : 0;
        final start   = letterStartMs + i * letterStaggerMs + jitter;
        final raw     = ((elapsedMs - start) / letterInMs).clamp(0.0, 1.0);
        final curve   = i < _letterCurves.length ? _letterCurves[i] : AurumMotion.letterIn;
        final eased   = raw > 0 ? curve.transform(raw) : 0.0;

        // Blur approximation: shadow blurRadius goes from wide (unsharp) to
        // tight (crisp) as the letter materialises.  Max 10px → 2px.
        final entryBlur  = 10.0 * (1 - eased);
        final pulseExtra = 6.0 * pulseGlow;

        return Opacity(
          opacity: raw,
          child: Transform.translate(
            offset: Offset(0, (1 - eased) * 8),
            child: ShaderMask(
              shaderCallback: (rect) => LinearGradient(
                colors: [goldSoft, gold],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ).createShader(rect),
              child: Text(
                word[i],
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3.2,
                  color: Colors.white,
                  shadows: [
                    // Entry defocus shadow — wide on entry, tight at rest.
                    Shadow(
                      color: gold.withOpacity(0.28),
                      blurRadius: entryBlur + 2,
                    ),
                    // Ambient glow — always present at low level.
                    Shadow(
                      color: gold.withOpacity(0.38),
                      blurRadius: 3 + pulseExtra,
                    ),
                    // Pulse corona — rises and falls with the pulse envelope.
                    if (pulseGlow > 0.01)
                      Shadow(
                        color: gold.withOpacity(0.22 * pulseGlow),
                        blurRadius: 14 * pulseGlow,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ── Helper curve: wraps another curve and slightly stretches its tail ────────
class _SlightlySlowerCurve extends Curve {
  final Curve _base;
  const _SlightlySlowerCurve(this._base);

  @override
  double transformInternal(double t) {
    // Compress t by 6% so the letter takes fractionally longer to settle.
    final compressed = (t * 0.94).clamp(0.0, 1.0);
    return _base.transform(compressed);
  }
}
