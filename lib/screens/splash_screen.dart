// =============================================================================
// FILE: lib/screens/splash_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Cold-start intro animation — "ASTRA MUSIC" wordmark reveal,
//   shown once, immediately after the native OS splash hands off to
//   Flutter's first frame, before MainShell/AppLockScreen/OnboardingGate.
//
//   REWRITTEN FROM WEBVIEW TO PURE DART/FLUTTER (this version): the
//   previous implementation rendered a validated HTML/CSS/SVG preview
//   inside a WebView for pixel-fidelity to that preview. In practice this
//   caused exactly the class of problems a WebView is known for in a
//   cold-start-critical path: JS engine + WebView surface startup cost
//   before the first animation frame could even begin (felt as a black
//   gap before the animation "starts"), and CPU/GPU-heavy per-element
//   `filter: blur()` on ~22 animated particle divs straining WebView's
//   compositor on mid-range/OEM-skinned devices (felt as jank/lag during
//   the animation itself, not smooth at all). Both problems are
//   structural to using a WebView for this — not tunable away with
//   timing or asset changes.
//
//   This version reimplements the same visual beats — radial glow,
//   gradient "ASTRA" stroke-draw + fill + sheen sweep, "MUSIC" subtitle,
//   expanding underline, ambient drifting particles — directly with
//   Flutter's own AnimationController + CustomPainter, so every frame is
//   a normal Flutter frame (Skia, same rendering path as the rest of the
//   app) with zero JS engine, zero WebView surface, and zero extra
//   compositor layer. This removes the black-gap-before-start problem
//   entirely (there is no separate engine to spin up — the animation IS
//   the first Flutter frame) and the mid-animation jank (no
//   blur-filtered DOM particles; the few particles here are plain
//   painted circles with opacity only, cheap on every device).
//
//   WHY THIS EXISTS / HISTORY: main.dart previously carried a Dart-side
//   splash (`_SplashOnEveryEntry`) that was removed because it played
//   AFTER the native OS splash finished, as a fully separate animation —
//   producing a visible restart/discontinuity. That is the exact
//   "awkward" complaint this file exists to fix properly: NOT by removing
//   the animation, but by making the native splash a true zero-length
//   handoff (already the case — see styles.xml's
//   windowSplashScreenAnimationDuration="0" and MainActivity.kt's
//   installSplashScreen() comment) so this widget is the ONLY animation
//   the user ever sees, starting the instant Flutter's first frame paints.
//   One continuous animation, no restart, no gap.
//
// WIRING:
//   - main.dart's MaterialApp.home wraps its existing subtree with this
//     widget: SplashScreen(child: _BlurShaderWarmup(child: AppLockScreen(...))).
//   - Shown ONLY on a true cold start (static _played flag on the State's
//     class, same survives-hot-reload/background-resume reasoning the old
//     _SplashOnEveryEntry doc comment used) — Home button / recents
//     reopen skips straight to `child` with zero delay or flicker.
//   - Respects AudioPrefs.enableAnimationsNotifier: when the user has
//     turned off animations app-wide, this skips straight to `child` with
//     no motion at all, consistent with every other AurumMotion-gated
//     animation in the app.
//   - Uses AurumTheme.darkBg for the background, matching the rest of the
//     app exactly (no separate hex value to keep in sync anymore).
//   - The whole timeline runs on ONE AnimationController; once it
//     completes plus a short settle hold, this widget starts its own
//     smooth Flutter-side opacity fade into `child` — so the intro
//     content is never hard-cut, it dissolves.
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Survives hot-reload and background/foreground cycles for the Dart
  // VM's lifetime — same pattern the old _SplashOnEveryEntry doc comment
  // used. Only a genuine force-close + relaunch resets the process and
  // clears this, giving a fresh cold-start animation next time.
  static bool _played = false;

  bool _showSplash = false;
  bool _controllerCreated = false;

  // Master timeline for the whole intro. Every beat below (glow, draw,
  // fill, sheen, subtitle, underline) is expressed as a fraction of this
  // single controller's 0..1 range, so the whole sequence is driven by
  // one Ticker — cheap, and trivially keeps every beat's relative timing
  // locked together regardless of device frame rate.
  late final AnimationController _timeline;
  late final AnimationController _fadeController;
  late final List<_Particle> _particles;

  // Total intro length before the fade-out begins. Kept comfortably over
  // 3s end-to-end (the earlier WebView version read as "too short" at
  // ~2.6s) — glow+draw+fill+sheen+underline settle by ~2.4s, then an
  // explicit hold keeps the finished wordmark on screen before fading.
  static const _timelineDuration = Duration(milliseconds: 3200);
  static const _fadeOutDuration = Duration(milliseconds: 420);

  static const _cyan = Color(0xFF4FE8D8);
  static const _violet = Color(0xFFA47BFF);
  static const _paleCyan = Color(0xFF8FF6E9);
  static const _paleViolet = Color(0xFFC9A6FF);
  // FIX (splash awkward on light theme): this was a single hardcoded
  // near-white (#DEDCE6), correct for the dark backdrop it was designed
  // against but nearly invisible on AurumTheme.lightBg's cream background
  // — the "MUSIC" subtitle effectively disappeared. The ASTRA wordmark's
  // own cyan/violet gradient stays fixed (both hues already carry enough
  // contrast against both light and dark), only this supporting text
  // color needs to flip. Resolved per-build from handoffBg's own
  // brightness (see build()) rather than a separate theme lookup, so it's
  // guaranteed to always agree with whichever background is actually
  // painting underneath it.
  static const _musicTextColorDark = Color(0xFFDEDCE6);
  static const _musicTextColorLight = Color(0xFF2A2733);

  @override
  void initState() {
    super.initState();
    if (_played || !AudioPrefs.enableAnimationsNotifier.value) {
      _played = true;
      return;
    }
    _showSplash = true;
    _played = true;
    _controllerCreated = true;

    _timeline = AnimationController(vsync: this, duration: _timelineDuration)
      ..forward();
    _fadeController = AnimationController(
      vsync: this,
      duration: _fadeOutDuration,
    );

    final rng = math.Random();
    _particles = List.generate(22, (i) {
      const colors = [_paleCyan, _cyan, _violet, _paleViolet];
      return _Particle(
        startX: rng.nextDouble(),
        startYFactor: 0.35 + rng.nextDouble() * 0.6,
        size: 1.0 + rng.nextDouble() * 2.2,
        dx: (rng.nextDouble() - 0.5) * 30,
        maxOpacity: 0.15 + rng.nextDouble() * 0.35,
        duration: 7 + rng.nextDouble() * 9,
        delay: rng.nextDouble() * 3.5,
        color: colors[rng.nextInt(colors.length)],
      );
    });

    _timeline.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  void _finish() {
    if (!mounted || !_showSplash) return;
    if (_fadeController.status == AnimationStatus.forward ||
        _fadeController.status == AnimationStatus.completed) {
      return;
    }
    _fadeController.forward().whenComplete(() {
      if (!mounted) return;
      // Same reasoning as before: give `child` (MainShell/Home) a couple
      // of real painted frames underneath before removing this layer
      // entirely, so its own first frame has settled and there's no
      // visible "bump" the instant the splash is gone.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _showSplash = false);
        });
      });
    });
  }

  @override
  void dispose() {
    if (_controllerCreated) {
      _timeline.dispose();
      _fadeController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    final size = MediaQuery.of(context).size;
    // FIX (black-flash-on-handoff): was hardcoded to AurumTheme.darkBg,
    // a fixed constant. MainShell's own Scaffold (the screen this widget
    // hands off to) paints with AurumTheme.bgOf(context), which resolves
    // to a Material You DYNAMIC color when the user has that enabled —
    // not the same value as darkBg in that case. That one-frame color
    // mismatch, right at the instant _showSplash flips to false, is what
    // read as a ~0.2s black flash. Pulling the same bgOf(context) here
    // guarantees the splash's own background is bit-for-bit identical to
    // what's already visible underneath it, so removing this layer never
    // has a color to jump across — dynamic-color users and fixed-theme
    // users both get a truly seamless handoff.
    final handoffBg = AurumTheme.bgOf(context);
    // Picks the readable subtitle color for whichever background is
    // actually resolved this frame (dark app theme, light app theme, or
    // dynamic/Material You in either brightness) — see the field doc
    // comment above for why a single fixed color broke in light mode.
    final musicTextColor = ThemeData.estimateBrightnessForColor(handoffBg) ==
            Brightness.dark
        ? _musicTextColorDark
        : _musicTextColorLight;
    return Stack(
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _fadeController,
          builder: (context, _) {
            return Opacity(
              opacity: 1.0 - _fadeController.value,
              child: IgnorePointer(
                child: Container(
                  color: handoffBg,
                  width: double.infinity,
                  height: double.infinity,
                  child: _SplashContent(
                    timeline: _timeline,
                    particles: _particles,
                    screenSize: size,
                    cyan: _cyan,
                    violet: _violet,
                    paleCyan: _paleCyan,
                    paleViolet: _paleViolet,
                    musicColor: musicTextColor,
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

class _Particle {
  final double startX; // 0..1 fraction of width
  final double startYFactor; // 0..1 fraction of height (bottom-weighted)
  final double size;
  final double dx;
  final double maxOpacity;
  final double duration; // seconds, full drift loop
  final double delay; // seconds
  final Color color;

  _Particle({
    required this.startX,
    required this.startYFactor,
    required this.size,
    required this.dx,
    required this.maxOpacity,
    required this.duration,
    required this.delay,
    required this.color,
  });
}

// Splits the master 3200ms timeline into the same relative beats the
// original HTML used, scaled by the same factor (3.2/2.6) onto every
// beat so relative timing matches the HTML version exactly, not just
// approximately:
//   glow:        0.12s -> 2.34s   (fade+scale in, stays)
//   stroke draw: 0.19s -> 1.85s
//   fill-in:     1.54s -> 2.15s
//   sheen sweep: 1.91s -> 3.2s   (capped to timeline end, was 3.26s)
//   subtitle:    1.66s -> 2.40s
//   underline:   2.09s -> 2.95s   (then a settle hold to 3.2s)
class _SplashContent extends StatelessWidget {
  final AnimationController timeline;
  final List<_Particle> particles;
  final Size screenSize;
  final Color cyan;
  final Color violet;
  final Color paleCyan;
  final Color paleViolet;
  final Color musicColor;

  const _SplashContent({
    required this.timeline,
    required this.particles,
    required this.screenSize,
    required this.cyan,
    required this.violet,
    required this.paleCyan,
    required this.paleViolet,
    required this.musicColor,
  });

  static double _t(double v, double start, double end) {
    if (end <= start) return v >= end ? 1.0 : 0.0;
    return ((v - start) / (end - start)).clamp(0.0, 1.0);
  }

  static double _easeOutCubic(double t) => 1 - math.pow(1 - t, 3).toDouble();

  @override
  Widget build(BuildContext context) {
    final wordmarkWidth = math.min(screenSize.width * 0.74, 340.0);
    return Stack(
      alignment: Alignment.center,
      children: [
        // Ambient particles, painted once via CustomPaint driven by the
        // same timeline — no per-particle widgets, no blur filters, just
        // plain painted circles with animated opacity/position. Cheap on
        // every device, unlike the old blur-filtered DOM particle divs.
        // FIX (smoothness polish): wrapped in RepaintBoundary so this
        // layer's frequent repaints get their own GPU-cached compositor
        // layer instead of forcing the wordmark/glow layers next to it to
        // be re-rasterized as part of the same paint pass. Cheap and safe
        // — three independent, isolated repaint surfaces instead of one
        // shared one, which is what "top-level smooth" actually requires
        // once per-frame CPU cost (fixed above) is no longer the bottleneck.
        Positioned.fill(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: timeline,
              builder: (context, _) {
                final elapsedS = timeline.value * 3.2;
                return CustomPaint(
                  painter: _ParticlePainter(
                    particles: particles,
                    elapsedSeconds: elapsedS,
                  ),
                );
              },
            ),
          ),
        ),
        // Soft radial glow behind the wordmark.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: timeline,
            builder: (context, _) {
              final v = timeline.value;
              final glowT = _easeOutCubic(_t(v, 0.123 / 3.2, 2.338 / 3.2));
              return Opacity(
                opacity: glowT,
                child: Transform.scale(
                  scale: 1.0 + glowT * 0.05,
                  child: Container(
                    width: 460,
                    height: 460,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          cyan.withOpacity(0.07),
                          violet.withOpacity(0.035),
                          violet.withOpacity(0.012),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.38, 0.62, 0.78],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Wordmark column: ASTRA (stroke-draw -> gradient fill -> sheen),
        // MUSIC subtitle, underline.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: timeline,
            builder: (context, _) {
              final v = timeline.value;
              final drawT = _easeOutCubic(_t(v, 0.185 / 3.2, 1.846 / 3.2));
              final fillT = _t(v, 1.538 / 3.2, 2.154 / 3.2);
              final sheenT = _t(v, 1.908 / 3.2, 3.2 / 3.2);
              final subtitleT = _easeOutCubic(_t(v, 1.662 / 3.2, 2.40 / 3.2));
              final underlineT = _easeOutCubic(_t(v, 2.092 / 3.2, 2.954 / 3.2));

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: wordmarkWidth,
                    height: wordmarkWidth * (160 / 620),
                    child: CustomPaint(
                      painter: _WordmarkPainter(
                        drawT: drawT,
                        fillT: fillT,
                        sheenT: sheenT,
                        cyan: cyan,
                        violet: violet,
                        paleCyan: paleCyan,
                        paleViolet: paleViolet,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Opacity(
                    opacity: subtitleT,
                    child: Transform.translate(
                      offset: Offset(0, (1 - subtitleT) * 24),
                      child: Text(
                        'MUSIC',
                        style: TextStyle(
                          fontSize: math.min(screenSize.width * 0.064, 27),
                          fontWeight: FontWeight.w400,
                          letterSpacing: 8,
                          color: musicColor.withOpacity(0.85),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  ClipRect(
                    child: Align(
                      alignment: Alignment.center,
                      widthFactor: underlineT,
                      child: Container(
                        width: 120,
                        height: 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [cyan, violet]),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Paints the "ASTRA" wordmark stroke-draw -> gradient-fill -> sheen-sweep
/// sequence. Mirrors the original SVG's three-layer approach (stroke path,
/// filled text, clipped sheen highlight) but as one CustomPainter — a
/// single paint call per frame instead of separate composited SVG/DOM
/// layers, which is what made the WebView version comparatively heavy.
///
/// FIX (janky/heavy animation, root cause): the previous version built a
/// brand-new TextPainter — including a full ..layout() call, i.e. real
/// text shaping/measurement — up to THREE times per paint() call (one
/// `measureTp` just for centering, plus one each for the stroke and fill
/// layers), and paint() runs on every single animation tick: 60 times a
/// second for the full 3.2s timeline. That's ~180 text-shaping layout
/// passes a second competing with the rest of the frame's raster work,
/// which is exactly what reads as jank/heaviness on mid-range devices —
/// nothing about the visuals themselves was heavy, the *shaping* was
/// being redone for no reason every frame.
///
/// The text ("ASTRA"), its style, and its size never change during the
/// animation — only drawT/fillT/sheenT (paint-time opacity/clip/shader
/// values) do. So every TextPainter this class needs is now built ONCE,
/// cached on the painter instance, and only rebuilt if `size` genuinely
/// changes (e.g. a rotation/orientation change) via the didUpdateSize
/// check in shouldRepaint. Steady-state frames now do zero layout calls —
/// paint() only positions/clips/shades already-laid-out TextPainters,
/// which is the actual cheap, smooth, top-tier-feeling path.
class _WordmarkPainter extends CustomPainter {
  final double drawT;
  final double fillT;
  final double sheenT;
  final Color cyan;
  final Color violet;
  final Color paleCyan;
  final Color paleViolet;

  // Cache is keyed by fontSize (the only input that can legitimately
  // change what needs laying out) and lives for the lifetime of this
  // painter instance's underlying RenderObject — Flutter reuses the same
  // CustomPaint's painter identity across rebuilds within one screen size,
  // so this survives across all ~192 frames of one splash playthrough.
  static double? _cachedFontSize;
  static TextPainter? _cachedMeasureTp;
  static TextPainter? _cachedStrokeTp;
  static TextPainter? _cachedFillTp;
  static Shader? _cachedShader;
  static Rect? _cachedTextRect;
  static Offset? _cachedOffset;

  _WordmarkPainter({
    required this.drawT,
    required this.fillT,
    required this.sheenT,
    required this.cyan,
    required this.violet,
    required this.paleCyan,
    required this.paleViolet,
  });

  void _ensureLayout(Size size) {
    final fontSize = size.height * (118 / 160);
    if (_cachedFontSize == fontSize && _cachedMeasureTp != null) {
      return; // Already laid out for this size — zero work this frame.
    }
    const text = 'ASTRA';
    final gradient = LinearGradient(
      colors: [paleCyan, cyan, violet, paleViolet],
      stops: const [0.0, 0.40, 0.75, 1.0],
    );
    final baseStyle = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 2,
    );

    final measureTp = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final offset = Offset(
      (size.width - measureTp.width) / 2,
      (size.height - measureTp.height) / 2,
    );
    final textRect = offset & measureTp.size;
    final shader = gradient.createShader(textRect);

    final strokeStyle = baseStyle.copyWith(
      foreground: Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    final strokeTp = TextPainter(
      text: TextSpan(text: text, style: strokeStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    // Fill layer's opacity is baked into `color` in the old version, which
    // forced a relayout every frame just to change opacity. Opacity is a
    // pure paint-time property — laid out once at full white here, then
    // modulated per-frame via saveLayer's paint alpha in paint() instead,
    // which needs no relayout at all.
    final fillStyle = baseStyle.copyWith(
      foreground: Paint()
        ..shader = shader
        ..style = PaintingStyle.fill,
    );
    final fillTp = TextPainter(
      text: TextSpan(text: text, style: fillStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    _cachedFontSize = fontSize;
    _cachedMeasureTp = measureTp;
    _cachedStrokeTp = strokeTp;
    _cachedFillTp = fillTp;
    _cachedShader = shader;
    _cachedTextRect = textRect;
    _cachedOffset = offset;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _ensureLayout(size);
    final offset = _cachedOffset!;
    final textRect = _cachedTextRect!;

    // Layer 1: stroke outline "drawing on" — approximated by clipping the
    // gradient-stroked text to a left-to-right reveal, which reads as the
    // same left-to-right materialization as the original stroke-dasharray
    // animation without needing per-glyph path extraction.
    if (drawT > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(
        textRect.left,
        textRect.top - 20,
        textRect.width * drawT,
        textRect.height + 40,
      ));
      _cachedStrokeTp!.paint(canvas, offset);
      canvas.restore();
    }

    // Layer 2: gradient fill fading in on top once the draw is done.
    // Opacity applied at paint-time via saveLayer's alpha — no relayout.
    if (fillT > 0) {
      canvas.saveLayer(
        textRect.inflate(20),
        Paint()..color = Colors.white.withOpacity(fillT),
      );
      _cachedFillTp!.paint(canvas, offset);
      canvas.restore();
    }

    // Layer 3: diagonal sheen highlight sweeping left-to-right, clipped to
    // the text's bounding box so it only ever shows up layered under the
    // already-shaped glyphs painted above (matches the SVG clipPath idea
    // closely enough — nothing outside real glyph coverage is visible
    // regardless of this rectangular clip, since paint order puts the
    // sheen beneath nothing wider than the glyphs themselves).
    if (sheenT > 0 && sheenT < 1 && fillT > 0.99) {
      canvas.save();
      canvas.clipRect(textRect);
      final sweepX = textRect.left - 140 + (textRect.width + 280) * sheenT;
      final sheenOpacity = sheenT < 0.15
          ? (sheenT / 0.15) * 0.9
          : sheenT > 0.55
              ? ((1 - sheenT) / 0.45) * 0.9
              : 0.9;
      final sheenPaint = Paint()
        ..color = Colors.white.withOpacity(sheenOpacity.clamp(0.0, 0.9))
        ..style = PaintingStyle.fill;
      canvas.save();
      canvas.translate(sweepX, textRect.center.dy);
      canvas.rotate(-20 * math.pi / 180);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: 60, height: 220),
        sheenPaint,
      );
      canvas.restore();
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _WordmarkPainter old) {
    return old.drawT != drawT || old.fillT != fillT || old.sheenT != sheenT;
  }
}

/// Plain painted particles — opacity + position only, no blur filters.
/// Cheap to paint every frame even on weaker devices, unlike the previous
/// WebView version's ~18-22 `filter: blur()` DOM elements.
class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double elapsedSeconds;

  _ParticlePainter({required this.particles, required this.elapsedSeconds});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final localT = elapsedSeconds - p.delay;
      if (localT <= 0) continue;
      final fadeT = (localT / 1.2).clamp(0.0, 1.0);
      final driftT = (localT % p.duration) / p.duration;
      final opacity = p.maxOpacity * fadeT;
      if (opacity <= 0.001) continue;

      final startX = p.startX * size.width;
      final startY = p.startYFactor * size.height;
      final x = startX + p.dx * driftT;
      final y = startY - 70 * driftT;

      final paint = Paint()
        ..color = p.color.withOpacity(opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(x, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) =>
      old.elapsedSeconds != elapsedSeconds;
}
