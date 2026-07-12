// aurum_morph_loader.dart
// Aurum Music — M3 Expressive "Shape-Morphing" Loading Indicator
// Thin wrapper around the real `expressive_loading_indicator` package
// (an authentic Dart port of Android's Compose Material3 LoadingIndicator,
// using true RoundedPolygon shapes + spring-physics morph animation).
//
// FIX — this used to be a hand-rolled approximation: a cosine-ripple radius
// function lerped with a flat easeInOutCubic curve. That produced a
// mechanical, linear-feeling morph with no bounce — visibly "cheaper" than
// the real Material 3 Expressive spinner (e.g. the Play Store loader),
// which morphs with spring physics (damped bounce, not a straight curve).
// Swapping the internals to wrap ExpressiveLoadingIndicator (already a
// dependency — see packages/expressive_loading_indicator) gets the real
// spring-morph feel everywhere this widget is used, with zero changes
// needed at any call site since the public API (size/color/durations) is
// unchanged.
//
// Usage:
//   const AurumMorphLoader()              // 40px, live accent color
//   const AurumMorphLoader(size: 28)
//   const AurumMorphLoader(color: Colors.amber)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';
import '../providers/theme_provider.dart';

/// Fallback color — only used if no ThemeProvider is reachable in the
/// widget tree (should basically never happen in normal app usage).
const Color kAurumMorphBlue = Color(0xFFA855F7); // Aurum purple (fallback only)

class AurumMorphLoader extends StatelessWidget {
  const AurumMorphLoader({
    super.key,
    this.size = 40.0,
    this.color,
    this.morphDuration = const Duration(milliseconds: 650),
    this.rotateDuration = const Duration(milliseconds: 4000),
  });

  /// Bounding box size (square) the blob is drawn in.
  final double size;

  /// Solid fill color of the blob. If null (the common case — nearly
  /// every call site in the app omits this), the loader reads the user's
  /// live accent color from ThemeProvider — the SAME color the nav bar
  /// and Settings → Appearance accent picker use, so every loading blob
  /// across the app (Home, Search, Liked, full player buffering,
  /// artist/album loading, etc.) always matches the chosen accent instead
  /// of a fixed purple.
  final Color? color;

  /// Kept for API compatibility with existing call sites. The underlying
  /// package uses its own tuned spring-physics timings (matching the real
  /// Android source) rather than a fixed linear duration, since that's
  /// what makes the morph feel premium rather than mechanical — so these
  /// are accepted but not forwarded.
  final Duration morphDuration;
  final Duration rotateDuration;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ??
        (context.select<ThemeProvider, Color>((tp) => tp.accentColor));

    return RepaintBoundary(
      child: ExpressiveLoadingIndicator(
        color: resolvedColor,
        constraints: BoxConstraints(
          minWidth: size,
          minHeight: size,
          maxWidth: size,
          maxHeight: size,
        ),
      ),
    );
  }
}
