import 'dart:math';
import 'package:flutter/material.dart';
import '../../theme/aurum_theme.dart';

/// Animated waveform-style progress indicator — replaces a flat
/// LinearProgressIndicator with a static-but-varied bar pattern where
/// bars ahead of playback position are dim and bars behind are lit
/// with the brand gradient. Deterministic per-song (seeded by the
/// song id) so it doesn't reshuffle every rebuild/frame.
class ShortsWaveformBar extends StatelessWidget {
  final double progress; // 0.0 – 1.0
  final String seed; // song id, keeps bar heights stable per song
  final int barCount;

  const ShortsWaveformBar({
    super.key,
    required this.progress,
    required this.seed,
    this.barCount = 40,
  });

  List<double> _heights() {
    // Deterministic pseudo-random heights from the seed so the same
    // song always renders the same "waveform" shape rather than
    // jittering every frame (which would look glitchy, not premium).
    final rng = Random(seed.hashCode);
    return List.generate(barCount, (i) {
      // Bias toward a gentle envelope (louder in the middle) rather
      // than pure noise, for a more natural waveform silhouette.
      final envelope = 1.0 - (2.0 * (i / barCount - 0.5)).abs() * 0.5;
      final noise = 0.35 + rng.nextDouble() * 0.65;
      return (0.25 + envelope * noise).clamp(0.2, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final heights = _heights();
    final litCount = (progress.clamp(0.0, 1.0) * barCount).floor();

    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(barCount, (i) {
          final lit = i <= litCount;
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              margin: const EdgeInsets.symmetric(horizontal: 1),
              height: 4 + (heights[i] * 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                color: lit
                    ? AurumTheme.gold
                    : Colors.white.withOpacity(0.18),
              ),
            ),
          );
        }),
      ),
    );
  }
}
