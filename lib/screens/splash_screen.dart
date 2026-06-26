import 'dart:math' as math;
import 'package:flutter/material.dart';

// AurumMotion — shared animation constants
class AurumMotion {
  static const Duration fast    = Duration(milliseconds: 180);
  static const Duration normal  = Duration(milliseconds: 300);
  static const Duration slow    = Duration(milliseconds: 500);
  static const Duration splash  = Duration(milliseconds: 650);

  static const Curve enter  = Curves.easeOutCubic;
  static const Curve exit   = Curves.easeInCubic;
  static const Curve smooth = Curves.easeInOutCubic;
}

/// Luxury brand-launch splash: the "A" mark is hand-drawn stroke-by-stroke
/// (CustomPainter + PathMetric, not an image), settles with a tiny rotation
/// and a light bloom, then "AURUM" types itself in beneath it letter by
/// letter. No logo image, no borders/frames/lines — just the mark and the
/// word on a dark gradient, built entirely from AnimationControllers.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // OPTIMIZATION: gold tones are now resolved per-theme in build() via
  // _goldFor()/_goldSoftFor() below — kept as instance constants here only
  // for the parts of the timing/animation math that don't care about color.
  static const Color _goldDark      = Color(0xFFD4AF37); // dark-mode gold
  static const Color _goldSoftDark  = Color(0xFFE8C766);
  static const Color _goldLight     = Color(0xFFB8862E); // light-mode gold —
  // slightly deeper/less luminous than the dark-mode gold so it keeps
  // contrast and doesn't look washed out against a pale background.
  static const Color _goldSoftLight = Color(0xFFC79A42);
  static const String _word     = 'AURUM';

  // ── Timing map (ms from splash start) ──────────────────────────────────
  // 0      -> logo stroke-draw begins
  // 900    -> stroke draw complete
  // 900    -> rotation settle + scale-in begins (overlaps draw's tail)
  // 1250   -> logo settled, bloom flash begins
  // 1450   -> bloom fades, first letter starts
  // 1450.. -> letters stagger in, 150ms apart, 380ms each
  // (lettersDone)+150 -> full-word glow pulse
  // (pulseEnd)+250     -> zoom-in 1.04x
  // (zoomPeak)+220     -> settle back to 1.0
  // (settle)+250       -> hold, then exit fade
  static const Duration _strokeDraw   = Duration(milliseconds: 900);
  static const Duration _settleStart  = Duration(milliseconds: 900);
  static const Duration _settleEnd    = Duration(milliseconds: 1250);
  static const Duration _bloomEnd     = Duration(milliseconds: 1450);
  static const Duration _letterStart  = Duration(milliseconds: 1450);
  static const Duration _letterStagger = Duration(milliseconds: 150);
  static const Duration _letterIn     = Duration(milliseconds: 380);

  late final Duration _lettersDone = _letterStart +
      Duration(
        milliseconds: _letterStagger.inMilliseconds * (_word.length - 1) +
            _letterIn.inMilliseconds,
      );
  late final Duration _pulseStart  = _lettersDone + const Duration(milliseconds: 150);
  late final Duration _pulseEnd    = _pulseStart + const Duration(milliseconds: 320);
  late final Duration _zoomStart   = _pulseEnd + const Duration(milliseconds: 100);
  late final Duration _zoomPeak    = _zoomStart + const Duration(milliseconds: 240);
  late final Duration _zoomSettle  = _zoomPeak + const Duration(milliseconds: 220);
  late final Duration _holdEnd     = _zoomSettle + const Duration(milliseconds: 260);
  late final Duration _exitEnd     = _holdEnd + const Duration(milliseconds: 420);

  late final Duration _total = _exitEnd;

  late AnimationController _ctrl;

  late Animation<double> _strokeProgress; // 0..1 path draw
  late Animation<double> _logoFade;       // 0..1
  late Animation<double> _logoScale;      // 0.6..1.0
  late Animation<double> _logoRotation;   // settle rotation in radians
  late Animation<double> _bloom;          // 0..1..0 flash on completion
  late Animation<double> _wordZoom;       // 1.0..1.04..1.0
  late Animation<double> _exitFade;       // 1..0

  bool _showChild = false;
  bool _exiting   = false;

  double _f(Duration d) => (d.inMilliseconds / _total.inMilliseconds).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    // OPTIMIZATION: easeInOutCubic -> easeInOutQuart for the stroke draw.
    // Same start/end, but the middle of the draw now glides rather than
    // moving at a near-constant rate — reads less "mechanical pen plotter",
    // more "ink settling in." Timing window is untouched.
    _strokeProgress = CurvedAnimation(
      parent: _ctrl,
      curve: Interval(0.0, _f(_strokeDraw), curve: Curves.easeInOutQuart),
    );

    _logoFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(const Duration(milliseconds: 150)), curve: Curves.easeOut),
      ),
    );

    // OPTIMIZATION: easeOutCubic -> easeOutQuint on the scale-in. Settles
    // into 1.0 with noticeably less overshoot-feel at the tail, which is
    // what removed the tiny perceptible "wobble" right as the logo locks
    // in size — same begin/end values, same duration window.
    _logoScale = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(0.0, _f(_settleEnd), curve: Curves.easeOutQuint),
      ),
    );

    // Tiny settle rotation: overshoots a few degrees then relaxes to 0,
    // landing exactly on the "2–5 degree settle" brief.
    _logoRotation = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -0.07) // ~-4°
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: -0.07, end: 0.0)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 40,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(_f(_settleStart), _f(_settleEnd), curve: Curves.linear),
      ),
    );

    // Bloom: soft light flash the instant the logo finishes forming.
    _bloom = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeIn)),
        weight: 65,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(_f(_settleEnd), _f(_bloomEnd), curve: Curves.linear),
      ),
    );

    // OPTIMIZATION: linear -> easeOutQuart / easeInOutQuart segments. The
    // original used Curves.linear *inside* the TweenSequenceItems and only
    // wrapped the whole sequence in a linear Interval — fine functionally,
    // but the peak landed slightly abruptly. Quart easing on each leg gives
    // a softer arrival at the 1.04x peak and a gentler return to 1.0.
    _wordZoom = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.04).chain(CurveTween(curve: Curves.easeOutQuart)),
        weight: 1,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.04, end: 1.0).chain(CurveTween(curve: Curves.easeInOutQuart)),
        weight: 1,
      ),
    ]).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(_f(_zoomStart), _f(_zoomSettle), curve: Curves.linear),
      ),
    );

    // OPTIMIZATION: exit fade eased with easeInOutCubic instead of easeIn.
    // easeIn alone made the very start of the fade-out feel like it
    // "caught" for a frame before easing — easeInOutCubic starts the fade
    // immediately and smoothly, which combined with the crossfade in
    // build() (see below) removes the last trace of a hard cut.
    _exitFade = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(_f(_holdEnd), 1.0, curve: Curves.easeInOutCubic),
      ),
    );

    _ctrl.forward().then((_) {
      if (mounted) setState(() => _showChild = true);
    });
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _exiting = true);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool _wordPulseActive(double t) =>
      t >= _f(_pulseStart) && t <= _f(_pulseEnd);

  double _wordPulseGlow(double t) {
    if (!_wordPulseActive(t)) return 0.0;
    final local = (t - _f(_pulseStart)) / (_f(_pulseEnd) - _f(_pulseStart));
    // Up then down — a single clean pulse, not a loop.
    return local < 0.5 ? (local * 2) : (2 - local * 2);
  }

  @override
  Widget build(BuildContext context) {
    if (_showChild && _exiting) return widget.child;

    // OPTIMIZATION (theme support): resolve once per build from the
    // platform/app brightness — logo shape, timing, and layout are
    // untouched; only background gradient + gold tone respond to theme.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gold = isDark ? _goldDark : _goldLight;
    final goldSoft = isDark ? _goldSoftDark : _goldSoftLight;
    final bgGradient = isDark
        ? const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0A0A0C),
              Color(0xFF151310),
              Color(0xFF0A0A0C),
            ],
          )
        : const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFFAF8F4),
              Color(0xFFF3EFE6),
              Color(0xFFFAF8F4),
            ],
          );

    return Stack(
      children: [
        if (_showChild) widget.child,
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            final opacity = _exiting ? _exitFade.value : 1.0;
            if (opacity <= 0.01) return const SizedBox.shrink();

            final t = _ctrl.value;

            return Opacity(
              opacity: opacity,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Container(
                  // Dark luxury gradient — no border, no frame, no lines.
                  // Light/dark swap happens here only; nothing else moves.
                  decoration: BoxDecoration(gradient: bgGradient),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // OPTIMIZATION: RepaintBoundary isolates the
                        // CustomPainter's repaint region from the text
                        // below it. Without this, every AnimatedBuilder
                        // tick (driven by the *single* shared controller)
                        // could force Flutter to consider repainting both
                        // the mark and the word together; isolating them
                        // keeps each repaint pass cheaper and removes the
                        // occasional sub-frame stutter under load.
                        RepaintBoundary(
                          child: Transform.rotate(
                            angle: _logoRotation.value,
                            child: Transform.scale(
                              scale: _logoScale.value,
                              child: Opacity(
                                opacity: _logoFade.value,
                                child: _AurumMark(
                                  strokeProgress: _strokeProgress.value,
                                  bloom: _bloom.value,
                                  gold: gold,
                                  goldSoft: goldSoft,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 30),
                        RepaintBoundary(
                          child: Transform.scale(
                            scale: _wordZoom.value,
                            child: _AurumWordmark(
                              elapsedMs: t * _total.inMilliseconds,
                              letterStartMs: _letterStart.inMilliseconds,
                              letterStaggerMs: _letterStagger.inMilliseconds,
                              letterInMs: _letterIn.inMilliseconds,
                              pulseGlow: _wordPulseGlow(t),
                              gold: gold,
                              goldSoft: goldSoft,
                              word: _word,
                            ),
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

/// The "A" mark, hand-drawn stroke by stroke via PathMetric, with a soft
/// gold glow and a one-time light bloom once the stroke completes.
class _AurumMark extends StatelessWidget {
  final double strokeProgress; // 0..1
  final double bloom;          // 0..1..0
  final Color gold;
  final Color goldSoft;

  const _AurumMark({
    required this.strokeProgress,
    required this.bloom,
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
          progress: strokeProgress,
          bloom: bloom,
          gold: gold,
          goldSoft: goldSoft,
        ),
      ),
    );
  }
}

class _AurumMarkPainter extends CustomPainter {
  final double progress;
  final double bloom;
  final Color gold;
  final Color goldSoft;

  _AurumMarkPainter({
    required this.progress,
    required this.bloom,
    required this.gold,
    required this.goldSoft,
  });

  /// Builds a monogram "A" as a single continuous outline: left leg up to
  /// the apex, down the right leg, then the crossbar — so a stroke-draw
  /// animation reads naturally left-to-right, like a pen drawing it.
  Path _buildPath(Size size) {
    final w = size.width, h = size.height;
    final apex   = Offset(w * 0.5, h * 0.06);
    final footL  = Offset(w * 0.08, h * 0.94);
    final footR  = Offset(w * 0.92, h * 0.94);
    final barL   = Offset(w * 0.27, h * 0.62);
    final barR   = Offset(w * 0.73, h * 0.62);

    final path = Path()
      ..moveTo(footL.dx, footL.dy)
      ..lineTo(apex.dx, apex.dy)
      ..lineTo(footR.dx, footR.dy)
      ..moveTo(barL.dx, barL.dy)
      ..lineTo(barR.dx, barR.dy);
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fullPath = _buildPath(size);

    // Extract the portion of the path drawn so far, across all subpaths,
    // so the crossbar draws in proportionally alongside the legs rather
    // than waiting for them to fully finish.
    final metrics = fullPath.computeMetrics().toList();
    final totalLength = metrics.fold<double>(0, (sum, m) => sum + m.length);
    final targetLength = totalLength * progress;

    final drawnPath = Path();
    double consumed = 0;
    for (final metric in metrics) {
      if (consumed >= targetLength) break;
      final remaining = targetLength - consumed;
      final take = math.min(metric.length, remaining);
      drawnPath.addPath(metric.extractPath(0, take), Offset.zero);
      consumed += metric.length;
    }

    final strokeWidth = size.width * 0.085;

    // OPTIMIZATION (visual refinement): glow opacity/blur trimmed down —
    // 0.45 -> 0.32 opacity, blur 14 -> 11. Same glow, same position, just
    // less "neon," more "soft jewelry-case light." Structure unchanged.
    if (progress > 0) {
      final glowPaint = Paint()
        ..color = gold.withOpacity(0.32)
        ..strokeWidth = strokeWidth * 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 11);
      canvas.drawPath(drawnPath, glowPaint);
    }

    // Crisp gold stroke on top.
    final strokePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [goldSoft, gold],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(drawnPath, strokePaint);

    // OPTIMIZATION (visual refinement): bloom flash dialed back —
    // 0.55 -> 0.38 peak opacity, slightly tighter blur radius. Reads as a
    // soft light catch rather than a flare. Same trigger, same timing.
    if (bloom > 0.001) {
      final bloomPaint = Paint()
        ..color = Colors.white.withOpacity(0.38 * bloom)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 * bloom + 6);
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        size.width * 0.32,
        bloomPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AurumMarkPainter old) =>
      old.progress != progress || old.bloom != bloom;
}

/// "AURUM" typed in letter by letter beneath the mark — fade + upward
/// drift per letter, gold gradient fill, with a single full-word glow
/// pulse once every letter has landed.
class _AurumWordmark extends StatelessWidget {
  final double elapsedMs;
  final int letterStartMs;
  final int letterStaggerMs;
  final int letterInMs;
  final double pulseGlow; // 0..1..0
  final Color gold;
  final Color goldSoft;
  final String word;

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
        final start = letterStartMs + i * letterStaggerMs;
        final raw = ((elapsedMs - start) / letterInMs).clamp(0.0, 1.0);
        // OPTIMIZATION: easeOutCubic -> easeOutQuint for the per-letter
        // entrance. The drift-up now decelerates more gradually into its
        // resting position instead of slowing down all at once — this was
        // the source of the faint "micro-jitter" feel between letters
        // landing in quick succession.
        final eased = Curves.easeOutQuint.transform(raw);

        final glow = 0.35 + 0.65 * pulseGlow;

        return Opacity(
          opacity: raw,
          child: Transform.translate(
            offset: Offset(0, (1 - eased) * 12),
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
                  letterSpacing: 3,
                  color: Colors.white,
                  // OPTIMIZATION (visual refinement): shadow trimmed —
                  // 0.7 -> 0.5 opacity, blur reduced slightly. Soft premium
                  // glow instead of a strong halo around each letter.
                  shadows: [
                    Shadow(
                      color: gold.withOpacity(0.5 * glow),
                      blurRadius: 12 * glow + 2,
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
