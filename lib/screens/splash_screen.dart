import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;
  late Animation<double> _glow;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
    _scale = Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.4)));
    _glow = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.4, 1.0)));
    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Scaffold(
      backgroundColor: AurumTheme.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: AurumTheme.gold.withOpacity(0.3 * _glow.value), blurRadius: 40, spreadRadius: 10)],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Image.asset('assets/images/ic_launcher.png',
                        errorBuilder: (_, __, ___) => Container(
                          decoration: BoxDecoration(color: AurumTheme.bgCard, borderRadius: BorderRadius.circular(24)),
                          child: const Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 48),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  ShaderMask(
                    shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
                    child: const Text('AURUM', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 10)),
                  ),
                  const SizedBox(height: 6),
                  const Text('MUSIC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w300, color: AurumTheme.textSecondary, letterSpacing: 6)),
                  const SizedBox(height: 60),
                  _LoadingDots(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingDots extends StatefulWidget {
  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final val = ((_ctrl.value - i / 3) % 1.0);
          final opacity = val < 0.5 ? val * 2 : (1.0 - val) * 2;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: 6, height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: AurumTheme.gold.withOpacity(opacity.clamp(0.2, 1.0))),
          );
        }),
      ),
    );
  }
}
