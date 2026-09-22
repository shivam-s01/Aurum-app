import 'dart:ui';
import 'package:flutter/material.dart';

/// Real iOS-style "Liquid Glass" surface.
///
/// A plain `BackdropFilter` + flat translucent color (what Aurum had
/// before) is NOT what reads as "iOS glass" — it's just a blurred flat
/// tint, which looks muddy/awkward because it's missing the things that
/// actually sell the iOS look:
///
///  1. The tint needs to sit in iOS's own opacity range (roughly
///     60-75% behind the blur, not 20-35%) — too transparent reads as
///     "washed out"/thin instead of "frosted glass with real weight".
///     iOS's own UIVisualEffectView materials are closer to this heavier
///     end; a too-light tint is one of the most common causes of a
///     blur effect reading as "off"/awkward rather than "glass".
///  2. A soft, narrow highlight hugging the TOP EDGE only (not a big
///     diagonal streak across the whole surface) — like light catching
///     the rim of a glass pane. A wide diagonal "shine wipe" looks odd
///     on a short pill-shaped bar; a slim top-hugging band reads as
///     "glass edge", which is what iOS materials actually show.
///  3. A subtle inner top-edge highlight border (bright hairline on the
///     top, near-invisible on the bottom) instead of a uniform-alpha
///     border all the way around — real glass catches light unevenly.
///
/// All static, painted once per frame alongside the blur — no shaders,
/// no continuous animation, no extra decode — so this costs nothing
/// beyond the BackdropFilter blur that was already there. `sigma <= 0`
/// skips BackdropFilter entirely (solid fallback), exactly like before,
/// so a user who wants zero blur/GPU cost still gets that — this only
/// changes what a *non-zero* sigma looks like.
class AurumGlass extends StatelessWidget {
  final Widget child;
  final double sigma;
  final BorderRadius borderRadius;
  final bool isDark;
  final Color? tintColor;

  const AurumGlass({
    super.key,
    required this.child,
    required this.sigma,
    required this.borderRadius,
    required this.isDark,
    this.tintColor,
  });

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) {
      // Solid fallback — identical cost/behavior to before: no blur, no
      // gradient overlay, just a flat panel. Zero extra GPU work.
      return ClipRRect(
        borderRadius: borderRadius,
        child: Container(
          decoration: BoxDecoration(
            color: tintColor ??
                (isDark ? const Color(0xFF1B1927) : Colors.white),
            borderRadius: borderRadius,
          ),
          child: child,
        ),
      );
    }

    final base = tintColor ?? (isDark ? Colors.black : Colors.white);
    // iOS-accurate fill: heavier than a "barely there" tint so the panel
    // reads as real frosted glass (with weight/body) rather than a thin
    // wash. Dark materials sit a bit lighter than light ones on iOS too.
    final fillAlpha = isDark ? 0.55 : 0.68;
    // Hairline top-edge highlight vs a near-invisible bottom edge — real
    // glass/metal catches light on the edge facing the (implied) light
    // source, not uniformly.
    final edgeHighlight = Colors.white.withValues(alpha: isDark ? 0.18 : 0.65);
    final edgeShade =
        Colors.black.withValues(alpha: isDark ? 0.25 : 0.06);

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // Base tint — lets the blurred page content read through
            // while still giving the panel real "glass" body/weight.
            Container(color: base.withValues(alpha: fillAlpha)),
            // Top-edge sheen: a slim highlight band hugging just the top
            // of the surface, fading out within ~35% of the height —
            // NOT a diagonal streak across the whole bar. This is what
            // reads as "glass catching light on its rim" rather than an
            // odd wipe/shine effect on a short pill-shaped bar.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: isDark ? 0.14 : 0.40),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35],
                    ),
                  ),
                ),
              ),
            ),
            // The actual content on top of the glass.
            child,
            // Edge highlight: bright hairline on top, faint shade on
            // bottom — drawn last so it always sits above content, like a
            // real border.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    border: Border(
                      top: BorderSide(color: edgeHighlight, width: 1),
                      left: BorderSide(
                          color: edgeHighlight.withValues(
                              alpha: edgeHighlight.a * 0.4),
                          width: 1),
                      right: BorderSide(
                          color: edgeShade, width: 1),
                      bottom: BorderSide(color: edgeShade, width: 1),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
