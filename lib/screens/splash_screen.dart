import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

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

/// Premium animated splash — same app icon, same wordmark, held for exactly
/// 3 seconds with a choreographed entrance: logo breathes in with a soft
/// gold glow bloom, a shimmer sweeps across it once, then the AURUM wordmark
/// reveals letter-by-letter underneath. Built to feel like a flagship
/// product opening, not a placeholder loading screen.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Fixed 3-second hold, exactly as requested — independent of app/data
  // readiness. The exit crossfade happens within this same window so the
  // splash never overstays past 3s total.
  static const Duration _totalHold = Duration(milliseconds: 3000);

  late AnimationController _ctrl;

  // Logo entrance: gentle breathe-in (scale + fade), no jarring pop.
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;

  // Glow bloom behind the logo — pulses once, settles to a soft idle glow.
  late Animation<double> _glowIntensity;

  // One-time diagonal shimmer sweep across the icon.
  late Animation<double> _shimmerPos;

  // Wordmark + tagline reveal, staggered after the logo settles.
  late Animation<double> _wordmarkFade;
  late Animation<double> _wordmarkSlide;
  late Animation<double> _taglineFade;

  // Final crossfade into the real app.
  late Animation<double> _exitFade;

  bool _showChild = false;
  bool _exiting   = false;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(vsync: this, duration: _totalHold);

    // ── Logo breathe-in: 0% – 22% of the timeline (~660ms) ──────────────────
    _logoScale = Tween(begin: 0.80, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.22, curve: Curves.easeOutCubic),
      ),
    );
    _logoFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.15, curve: Curves.easeOut),
      ),
    );

    // ── Glow bloom: rises with the logo, settles to a soft steady pulse ────
    _glowIntensity = TweenSequence([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.55)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.55, end: 0.85)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 55,
      ),
    ]).animate(_ctrl);

    // ── Shimmer sweep: one diagonal pass across the icon, ~25%–48% ─────────
    _shimmerPos = Tween(begin: -1.4, end: 1.4).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.25, 0.48, curve: Curves.easeInOutCubic),
      ),
    );

    // ── Wordmark reveal: starts right as shimmer finishes, ~30%–48% ────────
    _wordmarkFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.30, 0.48, curve: Curves.easeOut),
      ),
    );
    _wordmarkSlide = Tween(begin: 14.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.30, 0.50, curve: Curves.easeOutCubic),
      ),
    );
    _taglineFade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.42, 0.58, curve: Curves.easeOut),
      ),
    );

    // ── Exit: final 18% of the 3s window (~540ms crossfade) ────────────────
    _exitFade = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.82, 1.0, curve: Curves.easeIn),
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

  @override
  Widget build(BuildContext context) {
    if (_showChild && _exiting) return widget.child;

    return Stack(
      children: [
        if (_showChild) widget.child,
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            final opacity = _exiting ? _exitFade.value : 1.0;
            if (opacity <= 0.01) return const SizedBox.shrink();

            return Opacity(
              opacity: opacity,
              child: Scaffold(
                backgroundColor: AurumTheme.bg,
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _AnimatedLogo(
                        scale: _logoScale.value,
                        fade: _logoFade.value,
                        glow: _glowIntensity.value,
                        shimmerPos: _shimmerPos.value,
                      ),
                      const SizedBox(height: 28),
                      Transform.translate(
                        offset: Offset(0, _wordmarkSlide.value),
                        child: Opacity(
                          opacity: _wordmarkFade.value,
                          child: ShaderMask(
                            shaderCallback: (b) =>
                                AurumTheme.goldGradient.createShader(b),
                            child: const Text(
                              'AURUM',
                              style: TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: 8,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Opacity(
                        opacity: _taglineFade.value,
                        child: const Text(
                          'MUSIC',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w300,
                            color: AurumTheme.textSecondary,
                            letterSpacing: 5,
                          ),
                        ),
                      ),
                    ],
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

/// The app icon with a soft gold glow bloom behind it and a single
/// diagonal shimmer sweep across its surface — same icon asset, just
/// presented with a flagship-app entrance instead of a flat pop-in.
class _AnimatedLogo extends StatelessWidget {
  final double scale;
  final double fade;
  final double glow;
  final double shimmerPos; // -1.4 .. 1.4, sweep position

  const _AnimatedLogo({
    required this.scale,
    required this.fade,
    required this.glow,
    required this.shimmerPos,
  });

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: fade,
      child: Transform.scale(
        scale: scale,
        child: SizedBox(
          width: _size + 64,
          height: _size + 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Soft outer glow bloom — breathes via `glow`.
              Container(
                width: _size + 64 * glow.clamp(0.0, 1.0),
                height: _size + 64 * glow.clamp(0.0, 1.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      AurumTheme.gold.withOpacity(0.28 * glow),
                      AurumTheme.gold.withOpacity(0.0),
                    ],
                  ),
                ),
              ),
              // Icon itself.
              Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.25 * glow),
                      blurRadius: 36,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    children: [
                      Image.asset(
                        'assets/images/ic_launcher.png',
                        width: _size,
                        height: _size,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          decoration: BoxDecoration(
                            color: AurumTheme.bgCard,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Icon(
                            Icons.music_note_rounded,
                            color: AurumTheme.gold,
                            size: 46,
                          ),
                        ),
                      ),
                      // Diagonal shimmer sweep — a thin bright band that
                      // travels once across the icon's face.
                      IgnorePointer(
                        child: ShaderMask(
                          blendMode: BlendMode.srcATop,
                          shaderCallback: (rect) {
                            // Map shimmerPos (-1.4..1.4) to a moving gradient
                            // band across the icon's width.
                            final center = shimmerPos.clamp(-1.4, 1.4);
                            return LinearGradient(
                              begin: Alignment(center - 0.3, -1),
                              end: Alignment(center + 0.3, 1),
                              colors: const [
                                Colors.transparent,
                                Color(0x55FFFFFF),
                                Colors.transparent,
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ).createShader(rect);
                          },
                          child: Container(
                            width: _size,
                            height: _size,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
