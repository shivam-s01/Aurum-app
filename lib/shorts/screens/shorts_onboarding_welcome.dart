import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import 'shorts_onboarding_languages.dart';

/// Screen 1 of Shorts onboarding: minimal welcome, dark AMOLED, premium
/// typography. Shown only once (gated by ShortsPrefs.isOnboarded).
class ShortsWelcomeScreen extends StatelessWidget {
  const ShortsWelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const Spacer(flex: 3),
              ShaderMask(
                shaderCallback: (rect) =>
                    AurumTheme.goldGradient.createShader(rect),
                child: const Icon(
                  Icons.play_circle_fill_rounded,
                  size: 72,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                'Welcome to\nMusic Shorts',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.25,
                    ),
              ),
              const SizedBox(height: 14),
              Text(
                'Discover new music, one swipe at a time.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withOpacity(0.55),
                    ),
              ),
              const Spacer(flex: 4),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AurumTheme.gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).push(
                      PageRouteBuilder(
                        pageBuilder: (_, anim, __) =>
                            const ShortsLanguageScreen(),
                        transitionsBuilder: (_, anim, __, child) =>
                            FadeTransition(opacity: anim, child: child),
                        transitionDuration:
                            const Duration(milliseconds: 260),
                      ),
                    );
                  },
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
