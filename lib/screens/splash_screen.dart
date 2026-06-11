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

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<double> _scale;
  late Animation<double> _exitFade;

  bool _showChild = false;
  bool _exiting   = false;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: AurumMotion.splash, // 650ms total — no artificial delay
    );

    // Logo: subtle scale 0.92 → 1.0 (not dramatic, intentional)
    _scale = Tween(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: AurumMotion.enter),
    );

    // Fade in: full duration
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );

    // Exit fade out (last 30% of animation)
    _exitFade = Tween(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.7, 1.0, curve: Curves.easeIn),
      ),
    );

    _ctrl.forward().then((_) {
      // Show child DURING exit fade — no hard cut
      if (mounted) setState(() => _showChild = true);
    });

    // Start exit as soon as app is ready — no artificial wall
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
    // Once animation done, show child directly — zero overhead
    if (_showChild && _exiting) return widget.child;

    return Stack(
      children: [
        // Child rendered underneath during crossfade
        if (_showChild) widget.child,

        // Splash fades out over child — smooth crossfade
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            final opacity = _exiting ? _exitFade.value : _fade.value;
            if (opacity <= 0.01) return const SizedBox.shrink();

            return Opacity(
              opacity: opacity,
              child: Scaffold(
                backgroundColor: AurumTheme.bg,
                body: Center(
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // App icon
                        Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: AurumTheme.gold.withOpacity(0.22),
                                blurRadius: 32,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: Image.asset(
                              'assets/images/ic_launcher.png',
                              errorBuilder: (_, __, ___) => Container(
                                decoration: BoxDecoration(
                                  color: AurumTheme.bgCard,
                                  borderRadius: BorderRadius.circular(22),
                                ),
                                child: const Icon(
                                  Icons.music_note_rounded,
                                  color: AurumTheme.gold,
                                  size: 44,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Wordmark
                        ShaderMask(
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
                        const SizedBox(height: 4),
                        const Text(
                          'MUSIC',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w300,
                            color: AurumTheme.textSecondary,
                            letterSpacing: 5,
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
