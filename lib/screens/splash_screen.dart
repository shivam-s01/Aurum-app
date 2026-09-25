// =============================================================================
// FILE: lib/screens/splash_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Cold-start intro animation — an animated "ASTRA MUSIC"
//   wordmark shown once, immediately after the native OS splash hands off
//   to Flutter's first frame, before MainShell/AppLockScreen/OnboardingGate.
//
//   WHY THIS EXISTS / HISTORY: main.dart previously carried a Dart-side
//   splash (`_SplashOnEveryEntry`) that was removed because it played
//   AFTER the native OS splash finished, as a fully separate ~2400ms
//   animation — producing a visible restart/discontinuity ("native splash
//   finishes, then a second different animation starts from scratch").
//   That is the exact "awkward" complaint this file exists to fix
//   properly: NOT by removing the animation, but by making the native
//   splash a true zero-length handoff (already the case — see
//   styles.xml's windowSplashScreenAnimationDuration="0" and
//   MainActivity.kt's installSplashScreen() comment) so this widget is
//   the ONLY animation the user ever sees, starting the instant Flutter's
//   first frame paints. One continuous animation, no restart, no gap.
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
//   - Uses AurumTheme.darkBg as its background specifically (not
//     bgOf(context)) so it exactly matches LaunchTheme's
//     windowSplashScreenBackground (@color/bgColor) in styles.xml — any
//     mismatch there would show as a one-frame color flash at the native
//     → Flutter handoff, which is the same class of bug this file fixes.
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
    with SingleTickerProviderStateMixin {
  // Survives hot-reload and background/foreground cycles for the Dart
  // VM's lifetime — same pattern the old _SplashOnEveryEntry doc comment
  // used. Only a genuine force-close + relaunch resets the process and
  // clears this, giving a fresh cold-start animation next time.
  static bool _played = false;

  late final AnimationController _controller;
  bool _showSplash = false;
  bool _controllerCreated = false;

  // Total on-screen time. Kept well under the old removed splash's
  // 2400ms — this is a single unbroken motion starting from a blank
  // native-matching background, not a second animation layered after
  // one that already ran, so it doesn't need nearly as much runway to
  // read as deliberate rather than slow.
  static const _duration = Duration(milliseconds: 1900);

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
    _controller = AnimationController(vsync: this, duration: _duration)
      ..forward();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        // Small settle beat after the animation finishes so the final
        // frame actually registers before cutting to the app, rather
        // than the last animated frame and the first app frame arriving
        // back-to-back.
        Future.delayed(const Duration(milliseconds: 260), () {
          if (mounted) setState(() => _showSplash = false);
        });
      }
    });
  }

  @override
  void dispose() {
    if (_controllerCreated) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    return Stack(
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return _SplashOverlay(progress: _controller.value);
          },
        ),
      ],
    );
  }
}

class _SplashOverlay extends StatelessWidget {
  final double progress;
  const _SplashOverlay({required this.progress});

  // Phase boundaries (fractions of the 1900ms total), mirrored from the
  // validated web preview timing: draw -> fill -> sheen -> rise -> settle.
  static const _drawEnd = 0.62; // stroke-draw of the wordmark
  static const _fillStart = 0.58;
  static const _fillEnd = 0.80; // gradient fill fades in
  static const _sheenStart = 0.72;
  static const _sheenEnd = 1.0; // light sweep across the letters
  static const _musicStart = 0.66;
  static const _musicEnd = 0.92; // "MUSIC" rises in below
  static const _lineStart = 0.80;
  static const _lineEnd = 1.0; // underline expands
  static const _fadeOutStart = 0.94; // whole overlay fades to reveal app

  double _clamp01(double v) => v.clamp(0.0, 1.0);

  double _phase(double t, double start, double end) {
    if (end <= start) return t >= end ? 1.0 : 0.0;
    return _clamp01((t - start) / (end - start));
  }

  @override
  Widget build(BuildContext context) {
    final drawT = Curves.easeOutCubic.transform(_phase(progress, 0.0, _drawEnd));
    final fillT = Curves.easeOut.transform(_phase(progress, _fillStart, _fillEnd));
    final sheenT = Curves.easeOut.transform(_phase(progress, _sheenStart, _sheenEnd));
    final musicT = Curves.easeOutCubic.transform(_phase(progress, _musicStart, _musicEnd));
    final lineT = Curves.easeOutCubic.transform(_phase(progress, _lineStart, _lineEnd));
    final overlayFade = 1.0 - Curves.easeIn.transform(_phase(progress, _fadeOutStart, 1.0));

    return IgnorePointer(
      child: Opacity(
        opacity: overlayFade,
        child: Container(
          color: AurumTheme.darkBg,
          width: double.infinity,
          height: double.infinity,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 300,
                  height: 90,
                  child: CustomPaint(
                    painter: _WordmarkPainter(
                      drawT: drawT,
                      fillT: fillT,
                      sheenT: sheenT,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Transform.translate(
                  offset: Offset(0, (1 - musicT) * 18),
                  child: Opacity(
                    opacity: musicT,
                    child: Text(
                      'MUSIC',
                      style: TextStyle(
                        color: const Color(0xFFDEDCE6),
                        fontSize: 17,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 9,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Opacity(
                  opacity: lineT > 0 ? 1 : 0,
                  child: Container(
                    height: 1.5,
                    width: 110 * lineT,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Color(0xFF4FE8D8),
                          Color(0xFFA47BFF),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints "ASTRA" as a hand-drawn stroke that traces itself on, then
/// fades to a filled gradient wordmark, then plays one soft diagonal
/// sheen sweep across the letters. All three phases are pure paint
/// operations driven by the controller — no image assets, no extra
/// packages, matches the app's real accent hue (AurumTheme.accent
/// family) blended toward a cyan so the mark reads as distinctly
/// "Astra" rather than reusing the exact in-app purple 1:1.
class _WordmarkPainter extends CustomPainter {
  final double drawT;
  final double fillT;
  final double sheenT;

  _WordmarkPainter({required this.drawT, required this.fillT, required this.sheenT});

  static const _text = 'ASTRA';

  static const _gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF8FF6E9),
      Color(0xFF4FE8D8),
      Color(0xFFA47BFF),
      Color(0xFFC9A6FF),
    ],
    stops: [0.0, 0.35, 0.8, 1.0],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final textStyle = const TextStyle(
      fontSize: 56,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.5,
    );
    final tp = TextPainter(
      text: TextSpan(text: _text, style: textStyle.copyWith(color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout();

    final offset = Offset(
      (size.width - tp.width) / 2,
      (size.height - tp.height) / 2,
    );
    final glyphBounds = Rect.fromLTWH(
      offset.dx, offset.dy - 14, tp.width, tp.height + 28,
    );

    // One saveLayer scopes everything painted for this frame so the
    // reveal clip, the sheen's srcIn blend, and normal painting all
    // composite together cleanly — exactly one matching restore() at
    // the very end closes it. No nested saveLayers, so there is no way
    // for the save/restore stack to end up unbalanced.
    canvas.saveLayer(Offset.zero & size, Paint());

    // Phase 1 — stroke-look "being traced" pass, masked to only the
    // portion already drawn (revealWidth grows with drawT). Fades out
    // as fillT rises so it hands off smoothly to the solid fill.
    final strokeOpacity = (1 - fillT).clamp(0.0, 1.0);
    if (strokeOpacity > 0 && drawT > 0) {
      final revealWidth = tp.width * drawT;
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(
        offset.dx, glyphBounds.top, revealWidth, glyphBounds.height,
      ));
      final strokeTp = TextPainter(
        text: TextSpan(
          text: _text,
          style: textStyle.copyWith(
            color: const Color(0xFF6FEFDD).withValues(alpha: strokeOpacity),
            shadows: [
              Shadow(
                color: const Color(0xFF4FE8D8).withValues(alpha: strokeOpacity * 0.7),
                blurRadius: 8,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      strokeTp.paint(canvas, offset);
      canvas.restore();
    }

    // Phase 2 — solid gradient fill, fading in as fillT rises. Painted
    // as white text with the gradient composited on top via srcIn, so
    // only the glyph pixels receive color.
    if (fillT > 0) {
      canvas.saveLayer(glyphBounds, Paint());
      final fillTp = TextPainter(
        text: TextSpan(
          text: _text,
          style: textStyle.copyWith(color: Colors.white.withValues(alpha: fillT)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      fillTp.paint(canvas, offset);
      canvas.drawRect(
        glyphBounds,
        Paint()
          ..shader = _gradient.createShader(glyphBounds)
          ..blendMode = BlendMode.srcIn,
      );
      canvas.restore();

      // Phase 3 — one soft diagonal sheen sweeping across the now-filled
      // letters, also masked to the glyph pixels via srcIn.
      if (sheenT > 0 && sheenT < 1) {
        canvas.saveLayer(glyphBounds, Paint());
        fillTp.paint(canvas, offset);
        final sweepX = offset.dx - 60 + (tp.width + 120) * sheenT;
        final band = Rect.fromLTWH(sweepX - 30, glyphBounds.top, 60, glyphBounds.height);
        canvas.drawRect(
          band,
          Paint()
            ..shader = LinearGradient(
              colors: [
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: 0.55),
                Colors.white.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(band)
            ..blendMode = BlendMode.srcIn,
        );
        canvas.restore();
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordmarkPainter oldDelegate) {
    return oldDelegate.drawT != drawT ||
        oldDelegate.fillT != fillT ||
        oldDelegate.sheenT != sheenT;
  }
}
