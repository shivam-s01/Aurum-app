// aurum_morph_loader.dart
// Astra Music — M3 Expressive "Shape-Morphing" Loading Indicator
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
// ADDED ("background wala use krna hai" — 2026-09-14): real Material 3
// ships two variants of this exact indicator — LoadingIndicator (no
// background) and ContainedLoadingIndicator (morph sits inside a filled
// circular container) — both at the SAME fixed 48dp/38dp token sizing;
// Google's own spec doesn't pick the variant by size, it picks it by
// CONTEXT: contained is for a loader that reads as its own self-contained
// control (a full-screen/centered loading state, a standalone spot on an
// otherwise-empty area), while the plain version is for a loader sitting
// inline alongside other content (a small spinner next to text in a list
// row or button), where an added background circle would visually compete
// with — and look bruised/awkward next to — whatever it's inline with.
// `containerColor` is null by default (opt-in, matching real Android's own
// `containerColor = transparent` default for the un-contained style) so
// every existing call site keeps its current plain look until a call site
// explicitly asks for the container. This widget only exposes the toggle;
// which existing call sites actually opt in is decided per-site, not here.
//
// Usage:
//   const AurumMorphLoader()              // 40px, live accent color
//   const AurumMorphLoader(size: 28)
//   const AurumMorphLoader(color: Colors.amber)
//   const AurumMorphLoader(size: 56, contained: true)   // background circle

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
    this.contained = false,
    this.containerColor,
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

  /// When true, renders the Material 3 "contained" variant: the morphing
  /// shape sits inside a filled circular background container (matching
  /// real Android's ContainedLoadingIndicator), instead of floating with
  /// no background. Defaults to false — see this file's own doc comment
  /// above for when to opt a call site in.
  final bool contained;

  /// Background circle color when [contained] is true. If null, defaults
  /// to [resolvedColor] at reduced opacity — a tinted container that
  /// stays visually tied to the active indicator's own color (matching
  /// real Android's own containedContainerColor, which derives from the
  /// theme's primary container rather than being a flat neutral gray).
  final Color? containerColor;

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

    final indicator = ExpressiveLoadingIndicator(
      color: resolvedColor,
      constraints: BoxConstraints(
        minWidth: size,
        minHeight: size,
        maxWidth: size,
        maxHeight: size,
      ),
    );

    if (!contained) {
      return RepaintBoundary(child: indicator);
    }

    // Container is sized larger than the active shape itself (real M3
    // spec: 48dp container around a 38dp active indicator — ~1.26x ratio)
    // so the morphing shape has breathing room inside the circle rather
    // than touching its edge.
    final containerSize = size / (38 / 48);
    return RepaintBoundary(
      child: Container(
        width: containerSize,
        height: containerSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: containerColor ?? resolvedColor.withOpacity(0.16),
        ),
        alignment: Alignment.center,
        child: indicator,
      ),
    );
  }
}
