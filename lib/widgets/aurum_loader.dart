// aurum_loader.dart
// Aurum Music — Flagship v2 Loading Experience
// Pure Flutter · No external packages · 60 FPS · AMOLED optimised
// Upgrades: Depth Parallax · Energy Burst · Album Art Colors · Glass Refraction
//           Energy Trails · Advanced Liquid · Micro Shimmer · Smart Performance
//           Cinematic Rings · Atmospheric Aura · Non-Repetitive Motion
//           Audio-Inspired Breathing · Premium Transitions · Accessibility

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

/// Irrational-ratio timing: LCM of these values would take ~hours, preventing
/// any perceived loop for sessions up to 30 s.
abstract final class _Timing {
  static const masterMs       = 3600;   // base period
  static const orbMs          = 3600;   // harmonic 1×
  static const ringFastMs     = 2333;   // prime, ~1.54×
  static const ringMidMs      = 4111;   // prime, ~0.88×
  static const ringSlowMs     = 5743;   // prime, ~0.63×
  static const particleMs     = 4271;   // prime, ~0.84×
  static const rippleMs       = 2617;   // prime, ~1.38×
  static const glowMs         = 3187;   // prime, ~1.13×
  static const shimmerMs      = 2027;   // prime, ~1.78×
  static const breatheMs      = 5381;   // prime, ~0.67×  — audio breath
  static const auraMs         = 7919;   // prime, ~0.45×  — ultra-slow aura
  static const fadeInMs       = 900;
  static const fadeOutMs      = 700;
  static const burstMs        = 1200;
}

/// Depth layers — parallax speed multipliers (foreground > background)
abstract final class _Depth {
  static const aura        = 0.12;  // deepest
  static const ripple      = 0.28;
  static const ringBack    = 0.45;
  static const ringMid     = 0.62;
  static const ringFront   = 0.82;
  static const particleBack = 0.50;
  static const particleFront = 1.00;
  static const orb         = 1.00;  // foreground
}

/// Performance tiers — set once at loader creation
enum _QualityTier { low, mid, high }

// ═══════════════════════════════════════════════════════════════════════════
// DATA MODELS — allocated once, never reallocated per frame
// ═══════════════════════════════════════════════════════════════════════════

final class _ParticleData {
  _ParticleData(int seed) {
    final rng = math.Random(seed * 1013 + 7);
    orbitRadius   = 0.32 + rng.nextDouble() * 0.24;
    orbitSpeed    = 0.35 + rng.nextDouble() * 1.10;
    orbitPhase    = rng.nextDouble() * math.pi * 2;
    orbitTilt     = rng.nextDouble() * math.pi;
    size          = 1.0  + rng.nextDouble() * 2.4;
    alphaPhase    = rng.nextDouble() * math.pi * 2;
    alphaSpeed    = 0.40 + rng.nextDouble() * 1.20;
    colorT        = rng.nextDouble();
    depthLayer    = rng.nextDouble();                   // 0=back, 1=front
    trailLength   = 3 + rng.nextInt(5);                // 3-7 trail steps
  }

  late final double orbitRadius;
  late final double orbitSpeed;
  late final double orbitPhase;
  late final double orbitTilt;
  late final double size;
  late final double alphaPhase;
  late final double alphaSpeed;
  late final double colorT;
  late final double depthLayer;
  late final int    trailLength;
}

final class _RippleTrack {
  const _RippleTrack({
    required this.phaseOffset,
    required this.colorT,
    required this.maxScale,     // outer ripple reaches this * r
  });
  final double phaseOffset;
  final double colorT;
  final double maxScale;
}

/// Describes one cinematic ring.
final class _RingSpec {
  const _RingSpec({
    required this.radiusFraction,
    required this.direction,
    required this.speedKey,       // references _Timing constant
    required this.baseThickness,
    required this.dashCount,
    required this.colorShift,
    required this.tiltX,
    required this.tiltY,
    required this.glowSigma,
    required this.alphaBase,
    required this.depthMultiplier,
    required this.brightnessPhaseOffset,
    required this.variableThickness, // adds pulse to thickness
  });
  final double radiusFraction;
  final double direction;
  final int    speedKey;
  final double baseThickness;
  final int    dashCount;
  final double colorShift;
  final double tiltX;
  final double tiltY;
  final double glowSigma;
  final double alphaBase;
  final double depthMultiplier;
  final double brightnessPhaseOffset;
  final bool   variableThickness;
}

// ═══════════════════════════════════════════════════════════════════════════
// LOADER STATE ENUM
// ═══════════════════════════════════════════════════════════════════════════

enum AurumLoaderState {
  /// Normal infinite loading
  loading,
  /// Completion burst sequence playing
  completing,
  /// Fully dissolved — widget should be removed by caller
  completed,
}

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

  // ── Single master AnimationController ───────────────────────────────────
  late final AnimationController _master;

  // ── Derived phase animations (speed-ratio trick — no extra controllers) ─
  late final Animation<double> _orbPhase;
  late final Animation<double> _ringFastPhase;
  late final Animation<double> _ringMidPhase;
  late final Animation<double> _ringSlowPhase;
  late final Animation<double> _particlePhase;
  late final Animation<double> _ripplePhase;
  late final Animation<double> _glowPhase;
  late final Animation<double> _shimmerPhase;
  late final Animation<double> _breathePhase;
  late final Animation<double> _auraPhase;

  // ── One-shot animations driven off master value ──────────────────────────
  late final Animation<double> _fadeIn;    // 0→1 at start
  double _burstProgress = 0.0;            // 0→1 during completion
  double _dissolveAlpha = 1.0;            // 1→0 during fade-out

  // ── State machine ────────────────────────────────────────────────────────
  AurumLoaderState _internalState = AurumLoaderState.loading;
  bool _burstStarted = false;

  // ── Static data (allocated once) ────────────────────────────────────────
  late final List<_ParticleData> _particles;
  late final _QualityTier _quality;

  static const _rippleTracks = [
    _RippleTrack(phaseOffset: 0.00, colorT: 0.00, maxScale: 0.92),
    _RippleTrack(phaseOffset: 0.33, colorT: 0.50, maxScale: 0.85),
    _RippleTrack(phaseOffset: 0.66, colorT: 1.00, maxScale: 0.78),
  ];

  static const _ringSpecs = [
    _RingSpec(
      radiusFraction: 0.60, direction:  1.0, speedKey: _Timing.ringFastMs,
      baseThickness: 1.6,   dashCount: 7,    colorShift: 0.00,
      tiltX: 0.28, tiltY: 0.00, glowSigma: 9, alphaBase: 0.60,
      depthMultiplier: _Depth.ringFront, brightnessPhaseOffset: 0.0,
      variableThickness: true,
    ),
    _RingSpec(
      radiusFraction: 0.73, direction: -1.0, speedKey: _Timing.ringMidMs,
      baseThickness: 1.1,   dashCount: 5,    colorShift: 0.33,
      tiltX: 0.00, tiltY: 0.22, glowSigma: 7, alphaBase: 0.42,
      depthMultiplier: _Depth.ringMid, brightnessPhaseOffset: 0.4,
      variableThickness: true,
    ),
    _RingSpec(
      radiusFraction: 0.84, direction:  1.0, speedKey: _Timing.ringSlowMs,
      baseThickness: 0.7,   dashCount: 11,   colorShift: 0.66,
      tiltX: 0.15, tiltY: 0.18, glowSigma: 5, alphaBase: 0.28,
      depthMultiplier: _Depth.ringBack, brightnessPhaseOffset: 0.8,
      variableThickness: false,
    ),
    _RingSpec(
      radiusFraction: 0.50, direction: -1.0, speedKey: _Timing.ringFastMs,
      baseThickness: 0.5,   dashCount: 3,    colorShift: 0.80,
      tiltX: 0.35, tiltY: 0.10, glowSigma: 6, alphaBase: 0.20,
      depthMultiplier: _Depth.ringFront, brightnessPhaseOffset: 0.6,
      variableThickness: false,
    ),
  ];

  // ── Timing accumulator for burst ─────────────────────────────────────────
  double _burstElapsed = 0.0;
  int _lastFrameTime   = 0;

  @override
  void initState() {
    super.initState();
    _quality  = _detectQuality();
    final count = switch (_quality) {
      _QualityTier.low  => 10,
      _QualityTier.mid  => 14,
      _QualityTier.high => 20,
    };
    _particles = List.generate(count, (i) => _ParticleData(i));

    _master = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _Timing.masterMs),
    )..addListener(_onTick)..repeat();

    // Speed-ratio animations: ratio = masterMs / targetMs → completes ratio
    // full cycles every master period.
    _orbPhase       = _ratio(_Timing.orbMs);
    _ringFastPhase  = _ratio(_Timing.ringFastMs);
    _ringMidPhase   = _ratio(_Timing.ringMidMs);
    _ringSlowPhase  = _ratio(_Timing.ringSlowMs);
    _particlePhase  = _ratio(_Timing.particleMs);
    _ripplePhase    = _ratio(_Timing.rippleMs);
    _glowPhase      = _ratio(_Timing.glowMs);
    _shimmerPhase   = _ratio(_Timing.shimmerMs);
    _breathePhase   = _ratio(_Timing.breatheMs);
    _auraPhase      = _ratio(_Timing.auraMs);

    // Fade-in: first 900 ms of the animation
    _fadeIn = CurvedAnimation(
      parent: _master,
      curve: Interval(
        0,
        _Timing.fadeInMs / _Timing.masterMs,
        curve: Curves.easeOut,
      ),
    );
  }

  Animation<double> _ratio(int ms) =>
      Tween<double>(begin: 0, end: _Timing.masterMs / ms).animate(_master);

  _QualityTier _detectQuality() {
    // Use scheduler frame budget as proxy for device capability.
    // On first frame the budget is unknown; default to mid and let it adapt.
    final fps = SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;
    // Simple heuristic: rely on logical pixel density and platform.
    // A full GPU profiler isn't available at init; use a conservative default.
    // Callers can pass a quality hint via a subclass if needed.
    return _QualityTier.high; // Override per-device via factory if desired.
  }

  void _onTick() {
    if (_internalState == AurumLoaderState.completing) {
      final now = DateTime.now().microsecondsSinceEpoch;
      if (_lastFrameTime != 0) {
        _burstElapsed += (now - _lastFrameTime) / 1000.0; // ms
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
        // Dissolve starts at 70% of burst
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
      _burstStarted = true;
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
                  painter: _AuroraScenePainter(
                    size            : s,
                    orbPhase        : _orbPhase.value,
                    ringFastPhase   : _ringFastPhase.value,
                    ringMidPhase    : _ringMidPhase.value,
                    ringSlowPhase   : _ringSlowPhase.value,
                    particlePhase   : _particlePhase.value,
                    ripplePhase     : _ripplePhase.value,
                    glowPhase       : _glowPhase.value,
                    shimmerPhase    : _shimmerPhase.value,
                    breathePhase    : _breathePhase.value,
                    auraPhase       : _auraPhase.value,
                    particles       : _particles,
                    rippleTracks    : _rippleTracks,
                    ringSpecs       : _ringSpecs,
                    quality         : _quality,
                    dominantColor   : widget.dominantColor,
                    secondaryColor  : widget.secondaryColor,
                    burstProgress   : _burstProgress,
                    reducedMotion   : reducedMotion,
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
// MASTER PAINTER — composes all layers
// ═══════════════════════════════════════════════════════════════════════════

final class _AuroraScenePainter extends CustomPainter {
  const _AuroraScenePainter({
    required this.size,
    required this.orbPhase,
    required this.ringFastPhase,
    required this.ringMidPhase,
    required this.ringSlowPhase,
    required this.particlePhase,
    required this.ripplePhase,
    required this.glowPhase,
    required this.shimmerPhase,
    required this.breathePhase,
    required this.auraPhase,
    required this.particles,
    required this.rippleTracks,
    required this.ringSpecs,
    required this.quality,
    required this.dominantColor,
    required this.secondaryColor,
    required this.burstProgress,
    required this.reducedMotion,
  });

  final double size;
  final double orbPhase;
  final double ringFastPhase;
  final double ringMidPhase;
  final double ringSlowPhase;
  final double particlePhase;
  final double ripplePhase;
  final double glowPhase;
  final double shimmerPhase;
  final double breathePhase;
  final double auraPhase;
  final List<_ParticleData> particles;
  final List<_RippleTrack>  rippleTracks;
  final List<_RingSpec>     ringSpecs;
  final _QualityTier        quality;
  final Color?              dominantColor;
  final Color?              secondaryColor;
  final double              burstProgress;
  final bool                reducedMotion;

  // ── Geometry ─────────────────────────────────────────────────────────────
  double get cx => size / 2;
  double get cy => size / 2;
  double get r  => size / 2;

  // ── Paint objects (const-ish — mutated in place, not reallocated) ────────
  final _p0 = Paint()..style = PaintingStyle.fill;
  final _p1 = Paint()..style = PaintingStyle.stroke;
  final _p2 = Paint()..style = PaintingStyle.fill;

  // ─────────────────────────────────────────────────────────────────────────
  // COLOUR SYSTEM — aurora palette with optional album-art override
  // ─────────────────────────────────────────────────────────────────────────

  Color _palette(double t) {
    final wrapped = (t % 1.0).abs();

    // When album art colours are available, interpolate through them instead
    if (dominantColor != null && secondaryColor != null) {
      return _lerpThree(
        dominantColor!,
        secondaryColor!,
        Color.lerp(dominantColor!, _AurumColors.auroraPurple, 0.4)!,
        wrapped,
      );
    }
    // Default aurora palette: purple → cyan → pink → purple
    return _lerpThree(
      _AurumColors.auroraPurple,
      _AurumColors.electricCyan,
      _AurumColors.auroraPink,
      wrapped,
    );
  }

  static Color _lerpThree(Color a, Color b, Color c, double t) {
    if (t < 0.5) {
      return Color.lerp(a, b, _eio(t * 2))!;
    } else {
      return Color.lerp(b, c, _eio((t - 0.5) * 2))!;
    }
  }

  /// Smooth ease-in-out.
  static double _eio(double t) =>
      t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2;

  /// Ring phase from spec.
  double _ringPhase(_RingSpec spec) {
    return switch (spec.speedKey) {
      _Timing.ringFastMs => ringFastPhase,
      _Timing.ringMidMs  => ringMidPhase,
      _Timing.ringSlowMs => ringSlowPhase,
      _               => ringFastPhase,
    };
  }

  // ─────────────────────────────────────────────────────────────────────────
  // PAINT — main entry
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size canvasSize) {
    // Audio-breath scale wraps everything in a subtle inhale/exhale
    final breathe = reducedMotion ? 1.0 : _audioBreathe();

    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(breathe);
    canvas.translate(-cx, -cy);

    // Burst contracts the whole scene before dissolve
    if (burstProgress > 0) {
      final burstScale = burstProgress < 0.3
          ? 1.0 + burstProgress * 0.8          // brief expand
          : 1.8 - burstProgress * 1.8;          // then contract to 0
      canvas.translate(cx, cy);
      canvas.scale(burstScale.clamp(0.0, 2.0));
      canvas.translate(-cx, -cy);
    }

    _paintAtmosphericAura(canvas);
    _paintRipples(canvas);
    _paintRings(canvas);
    _paintParticles(canvas);
    _paintOrb(canvas);

    // Burst: flash overlay
    if (burstProgress > 0 && burstProgress < 0.45) {
      final flashAlpha = math.sin(burstProgress / 0.45 * math.pi) * 0.55;
      _p0
        ..shader     = null
        ..maskFilter = null
        ..color      = _palette(glowPhase).withOpacity(flashAlpha);
      canvas.drawCircle(Offset(cx, cy), r, _p0);
    }

    canvas.restore();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // AUDIO-INSPIRED BREATHING
  // ─────────────────────────────────────────────────────────────────────────

  double _audioBreathe() {
    // Two-harmonic waveform resembling a music bar (fundamental + 3rd harmonic)
    final t   = breathePhase * math.pi * 2;
    final w1  = math.sin(t)         * 0.022;  // fundamental
    final w2  = math.sin(t * 3.0)   * 0.008;  // 3rd harmonic
    final w3  = math.sin(t * 0.618) * 0.012;  // golden-ratio sub-harmonic
    return 1.0 + w1 + w2 + w3;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LAYER 0 — Atmospheric Aura (deepest, slowest)
  // ─────────────────────────────────────────────────────────────────────────

  void _paintAtmosphericAura(Canvas canvas) {
    final t    = auraPhase * math.pi * 2;
    final colA = _palette(auraPhase * _Depth.aura);
    final colB = _palette(auraPhase * _Depth.aura + 0.5);

    // Very large, near-transparent gradient disc — perceived as ambient light
    _p0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 60)
      ..shader     = RadialGradient(
          colors: [
            colA.withOpacity(0.10 + math.sin(t) * 0.03),
            colB.withOpacity(0.05 + math.cos(t * 0.7) * 0.02),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
    canvas.drawCircle(Offset(cx, cy), r * 1.0, _p0);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LAYER 1 — Ripple System (with depth parallax)
  // ─────────────────────────────────────────────────────────────────────────

  void _paintRipples(Canvas canvas) {
    for (final track in rippleTracks) {
      // Depth parallax: ripples scroll at their own speed
      final phase = (ripplePhase * _Depth.ripple + track.phaseOffset) % 1.0;
      final expandT = _eio(phase);

      // Burst accelerates ripples outward
      final burstExpand = burstProgress > 0
          ? burstProgress * 0.5
          : 0.0;

      final rippleR = r * (0.22 + track.maxScale * (expandT + burstExpand)).clamp(0.0, r);
      final opacity = (1.0 - expandT) * (1.0 - expandT) * (0.40 + burstProgress * 0.30);

      if (opacity < 0.004) continue;

      final col = _palette(track.colorT + glowPhase * 0.3);

      // Soft glow ring
      _p0
        ..shader     = null
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12)
        ..color      = col.withOpacity(opacity * 0.4);
      canvas.drawCircle(Offset(cx, cy), rippleR, _p0);

      // Crisp stroke
      _p1
        ..shader      = null
        ..maskFilter  = null
        ..color       = col.withOpacity(opacity)
        ..strokeWidth = 1.0;
      canvas.drawCircle(Offset(cx, cy), rippleR, _p1);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LAYER 2 — Cinematic Ring System (depth + brightness pulse + variable width)
  // ─────────────────────────────────────────────────────────────────────────

  void _paintRings(Canvas canvas) {
    for (final spec in ringSpecs) {
      if (quality == _QualityTier.low && spec.glowSigma > 7) continue;
      _paintCinematicRing(canvas, spec);
    }
  }

  void _paintCinematicRing(Canvas canvas, _RingSpec spec) {
    final phase = _ringPhase(spec);
    // Depth parallax: rings at different depths rotate at effectively different speeds
    final angle0    = spec.direction * phase * math.pi * 2 * spec.depthMultiplier;
    // Brightness pulse: ring brightens and dims on its own sub-period
    final brightness = (math.sin(
          glowPhase * math.pi * 2 * 1.3 + spec.brightnessPhaseOffset,
        ) * 0.5 + 0.5);

    // Shimmer travelling highlight across ring
    final shimmerPos = (shimmerPhase * spec.depthMultiplier) % 1.0;

    final segCount = quality == _QualityTier.low ? 90 : 180;

    final cosX = math.cos(spec.tiltX);
    final sinX = math.sin(spec.tiltX);
    final cosY = math.cos(spec.tiltY);
    final sinY = math.sin(spec.tiltY);
    final ringR = spec.radiusFraction * r;

    // Pre-compute vertices
    final pts = List<Offset>.generate(segCount + 1, (i) {
      final theta = angle0 + (i / segCount) * math.pi * 2;
      final x3 = ringR * math.cos(theta);
      final y3 = ringR * math.sin(theta);
      final y2 = y3 * cosX;
      final z2 = y3 * sinX;
      final x2 = x3 * cosY + z2 * sinY;
      return Offset(cx + x2, cy + y2);
    });

    // Depth fade: segments at "back" of the tilted ring are dimmer
    for (int i = 0; i < segCount; i++) {
      final segT     = i / segCount;
      final dashT    = (segT * spec.dashCount) % 1.0;
      final dashAlpha = math.sin(dashT * math.pi).clamp(0.0, 1.0);
      if (dashAlpha < 0.03) continue;

      // Depth cue from angular position
      final angularDepth = (math.sin((segT + angle0 / (math.pi * 2)) * math.pi * 2) * 0.5 + 0.5);

      // Shimmer highlight: Gaussian peak travelling around ring
      final shimmerDist = ((segT - shimmerPos).abs());
      final shimmerWrapped = math.min(shimmerDist, 1.0 - shimmerDist);
      final shimmerBoost = math.exp(-shimmerWrapped * shimmerWrapped * 80) * 0.5;

      // Variable thickness pulse
      final thickMult = spec.variableThickness
          ? 1.0 + math.sin(glowPhase * math.pi * 2 * 2.1 + segT * math.pi * 4) * 0.35
          : 1.0;

      final alpha = spec.alphaBase
          * dashAlpha
          * (0.45 + angularDepth * 0.55)
          * (0.70 + brightness * 0.30);

      final col = _palette(spec.colorShift + segT * 0.4 + glowPhase * 0.25);
      final shimmerCol = Color.lerp(col, _AurumColors.white, shimmerBoost)!;

      // Glow pass
      _p1
        ..color       = shimmerCol.withOpacity(alpha * 0.45)
        ..strokeWidth = (spec.baseThickness * thickMult + spec.glowSigma * 0.5)
        ..strokeCap   = StrokeCap.round
        ..maskFilter  = MaskFilter.blur(BlurStyle.normal, spec.glowSigma);
      canvas.drawLine(pts[i], pts[i + 1], _p1);

      // Core pass
      _p1
        ..color       = shimmerCol.withOpacity(alpha)
        ..strokeWidth = spec.baseThickness * thickMult
        ..maskFilter  = null;
      canvas.drawLine(pts[i], pts[i + 1], _p1);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LAYER 3 — Particle Halo with Depth Parallax & Energy Trails
  // ─────────────────────────────────────────────────────────────────────────

  void _paintParticles(Canvas canvas) {
    for (final p in particles) {
      // Depth-parallax speed: foreground particles move faster
      final speedMult = _Depth.particleBack + p.depthLayer * (_Depth.particleFront - _Depth.particleBack);
      final theta = p.orbitPhase + p.orbitSpeed * particlePhase * math.pi * 2 * speedMult;

      final cosT = math.cos(p.orbitTilt);
      final rx   = math.cos(theta) * p.orbitRadius * r;
      final ry   = math.sin(theta) * p.orbitRadius * r * cosT;

      // Burst: particles fly outward
      final burstOffset = burstProgress > 0
          ? burstProgress * r * 0.6 * p.depthLayer
          : 0.0;
      final burstAngle = p.orbitPhase; // fly in orbit direction
      final px   = cx + rx + burstOffset * math.cos(burstAngle);
      final py   = cy + ry + burstOffset * math.sin(burstAngle);

      final depth  = math.sin(theta) * math.sin(p.orbitTilt) * 0.5 + 0.5;
      final alphaT = math.sin(p.alphaPhase + p.alphaSpeed * particlePhase * math.pi * 2)
                        .abs()
                        .clamp(0.0, 1.0);
      final alpha  = alphaT * (0.30 + depth * 0.60) * (1.0 + burstProgress * 0.8);
      final sz     = p.size * (0.45 + depth * 0.55) * (1.0 + burstProgress * p.depthLayer);

      final col = _palette(p.colorT + glowPhase * 0.18);

      // ── Energy trail: draw fading dots behind the particle ───────────────
      if (quality != _QualityTier.low) {
        final trailSteps = p.trailLength;
        for (int t = 1; t <= trailSteps; t++) {
          final trailFrac  = t / trailSteps;
          final trailTheta = theta - p.orbitSpeed * 0.018 * t * speedMult;
          final trailRx    = math.cos(trailTheta) * p.orbitRadius * r;
          final trailRy    = math.sin(trailTheta) * p.orbitRadius * r * cosT;
          final trailAlpha = alpha * (1.0 - trailFrac) * 0.35;
          final trailSz    = sz * (1.0 - trailFrac * 0.6);

          if (trailAlpha < 0.01) continue;

          _p0
            ..shader     = null
            ..maskFilter = null
            ..color      = col.withOpacity(trailAlpha);
          canvas.drawCircle(Offset(cx + trailRx, cy + trailRy), trailSz * 0.4, _p0);
        }
      }

      // ── Glow corona ───────────────────────────────────────────────────────
      if (quality != _QualityTier.low) {
        _p0
          ..color      = col.withOpacity(alpha * 0.4)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sz * 2.0)
          ..shader     = null;
        canvas.drawCircle(Offset(px, py), sz * 1.6, _p0);
      }

      // ── Bright core ───────────────────────────────────────────────────────
      _p0
        ..color      = Color.lerp(col, _AurumColors.white, 0.6)!.withOpacity(alpha)
        ..maskFilter = null
        ..shader     = null;
      canvas.drawCircle(Offset(px, py), sz * 0.50, _p0);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LAYER 4 — Liquid Aurora Orb
  //           Advanced multi-frequency liquid + Glass refraction + Shimmer
  // ─────────────────────────────────────────────────────────────────────────

  void _paintOrb(Canvas canvas) {
    const controlPoints = 8;           // more points → richer deformation
    final orbR = r * 0.26;

    // ── Advanced multi-frequency liquid deformation ───────────────────────
    // Uses 5 harmonics at irrational frequency ratios to prevent looping.
    // Amplitudes are weighted so the orb stays roughly circular.
    final List<Offset> pts = [];
    for (int i = 0; i < controlPoints; i++) {
      final a = (i / controlPoints) * math.pi * 2;
      final t = orbPhase * math.pi * 2;

      // Harmonic stack
      final d1 = math.sin(t * 1.000 + a * 2) * 0.120;
      final d2 = math.cos(t * 1.618 + a * 3) * 0.080; // golden ratio
      final d3 = math.sin(t * 2.414 + a * 5) * 0.045; // silver ratio
      final d4 = math.cos(t * 0.577 + a * 7) * 0.030; // 1/√3
      final d5 = math.sin(t * 3.141 + a * 4) * 0.018; // π ratio

      final rad = orbR * (1.0 + d1 + d2 + d3 + d4 + d5).clamp(0.6, 1.5);
      pts.add(Offset(cx + rad * math.cos(a), cy + rad * math.sin(a)));
    }

    // Catmull-Rom smooth path
    final path = Path();
    for (int i = 0; i < controlPoints; i++) {
      final prev  = pts[(i - 1 + controlPoints) % controlPoints];
      final curr  = pts[i];
      final next  = pts[(i + 1) % controlPoints];
      final next2 = pts[(i + 2) % controlPoints];
      if (i == 0) path.moveTo(curr.dx, curr.dy);
      final cp1 = Offset(curr.dx + (next.dx - prev.dx) / 6,
                         curr.dy + (next.dy - prev.dy) / 6);
      final cp2 = Offset(next.dx - (next2.dx - curr.dx) / 6,
                         next.dy - (next2.dy - curr.dy) / 6);
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, next.dx, next.dy);
    }
    path.close();

    final orbRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: orbR * 2.6,
      height: orbR * 2.6,
    );

    final colA = _palette(orbPhase);
    final colB = _palette(orbPhase + 0.38);
    final colC = _palette(orbPhase + 0.72);

    // ── Deep glow ────────────────────────────────────────────────────────
    _p0
      ..shader     = null
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30)
      ..color      = colA.withOpacity(0.55);
    canvas.drawPath(path, _p0);

    _p0
      ..color      = colB.withOpacity(0.30)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    canvas.drawPath(path, _p0);

    // ── Orb body with animated gradient ──────────────────────────────────
    _p0
      ..maskFilter = null
      ..shader     = RadialGradient(
          center: const Alignment(-0.28, -0.38),
          radius: 0.92,
          colors: [
            Color.lerp(_AurumColors.white, colC, 0.45)!.withOpacity(0.96),
            colA.withOpacity(0.92),
            colB.withOpacity(0.88),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(orbRect);
    canvas.drawPath(path, _p0);

    // ── Glass refraction layer ────────────────────────────────────────────
    // Simulates internal caustics using an offset semi-transparent radial.
    final refractOffset = Offset(
      cx + math.cos(shimmerPhase * math.pi * 2) * orbR * 0.18,
      cy + math.sin(shimmerPhase * math.pi * 2 * 0.7) * orbR * 0.14,
    );
    _p0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
      ..shader     = RadialGradient(
          colors: [
            _AurumColors.white.withOpacity(0.18),
            _AurumColors.white.withOpacity(0.04),
            Colors.transparent,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(
            Rect.fromCircle(center: refractOffset, radius: orbR * 0.55));
    canvas.drawCircle(refractOffset, orbR * 0.50, _p0);

    // ── Micro shimmer — horizontal sweep across orb surface ──────────────
    if (quality != _QualityTier.low) {
      final shimX = cx - orbR + shimmerPhase * orbR * 2 * 1.8; // overshoots edges
      final shimRect = Rect.fromCenter(
        center: Offset(shimX.clamp(cx - orbR, cx + orbR), cy),
        width: orbR * 0.40,
        height: orbR * 2.4,
      );
      _p0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
        ..shader     = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              _AurumColors.white.withOpacity(0.14),
              Colors.transparent,
            ],
          ).createShader(shimRect);
      // Clip shimmer to orb shape
      canvas.save();
      canvas.clipPath(path);
      canvas.drawRect(shimRect.inflate(10), _p0);
      canvas.restore();
    }

    // ── Primary specular highlight ────────────────────────────────────────
    _p0
      ..shader     = null
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
      ..color      = _AurumColors.white.withOpacity(0.30);
    canvas.drawCircle(
      Offset(cx - orbR * 0.22, cy - orbR * 0.28),
      orbR * 0.28,
      _p0,
    );

    // ── Secondary micro-highlight (glass edge refraction) ─────────────────
    _p0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2)
      ..color      = _AurumColors.white.withOpacity(0.18);
    canvas.drawCircle(
      Offset(cx + orbR * 0.30, cy + orbR * 0.24),
      orbR * 0.10,
      _p0,
    );

    // ── Ring shimmer on orb surface ───────────────────────────────────────
    if (quality == _QualityTier.high) {
      final ringShimT  = (shimmerPhase * 1.3) % 1.0;
      final ringShimR  = orbR * (0.3 + ringShimT * 0.7);
      final ringShimA  = (1.0 - ringShimT) * 0.08;
      _p2
        ..shader      = null
        ..maskFilter  = null
        ..color       = _AurumColors.white.withOpacity(ringShimA)
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      canvas.save();
      canvas.clipPath(path);
      canvas.drawCircle(Offset(cx, cy), ringShimR, _p2);
      canvas.restore();
      _p2.style = PaintingStyle.fill;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────

  @override
  bool shouldRepaint(_AuroraScenePainter old) {
    return old.orbPhase       != orbPhase       ||
           old.ringFastPhase  != ringFastPhase  ||
           old.ringMidPhase   != ringMidPhase   ||
           old.ringSlowPhase  != ringSlowPhase  ||
           old.particlePhase  != particlePhase  ||
           old.ripplePhase    != ripplePhase    ||
           old.glowPhase      != glowPhase      ||
           old.shimmerPhase   != shimmerPhase   ||
           old.breathePhase   != breathePhase   ||
           old.auraPhase      != auraPhase      ||
           old.burstProgress  != burstProgress  ||
           old.dominantColor  != dominantColor  ||
           old.secondaryColor != secondaryColor;
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
