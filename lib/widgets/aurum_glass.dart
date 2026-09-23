import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// Real iOS 26-style "Liquid Glass" surface, backed by the `liquid_glass_easy`
/// package's shader lens (`LiquidGlassLens`) — genuine refraction of the live
/// backdrop, not a flat blurred tint.
///
/// On Impeller (Flutter's default engine on modern iOS/Android — this app's
/// target) `LiquidGlassLens` refracts the live backdrop directly: no
/// `LiquidGlassView` or captured background needed, so every existing call
/// site (mini player, nav bar) needs no changes beyond this file.
///
/// The public API is unchanged from the previous hand-rolled shader version,
/// so callers keep passing `sigma`/`borderRadius`/`isDark`/`tintColor`/
/// `useTintInGlass` exactly as before. `sigma <= 0` still takes the
/// zero-cost solid-panel fallback path -- no lens, no blur, no GPU cost.
class AurumGlass extends StatelessWidget {
  final Widget child;
  final double sigma;
  final BorderRadius borderRadius;
  final bool isDark;

  /// Optional solid colour used ONLY for the sigma<=0 flat fallback panel.
  /// When the glass lens is active this is deliberately ignored unless
  /// [useTintInGlass] is true -- glass must stay neutral (theme-coloured),
  /// never take on the currently playing song's artwork colour.
  final Color? tintColor;

  /// false (default): the glass body colour is always the neutral theme
  /// colour (black in dark / white in light). [tintColor] then only
  /// affects the flat fallback. This is what fixes "thumbnail colour
  /// changes the glass colour" on the mini player.
  final bool useTintInGlass;

  const AurumGlass({
    super.key,
    required this.child,
    required this.sigma,
    required this.borderRadius,
    required this.isDark,
    this.tintColor,
    this.useTintInGlass = false,
  });

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) {
      // Solid fallback -- identical cost/behavior to before: no blur, no
      // lens, just a flat panel. Zero extra GPU work.
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

    final base = useTintInGlass
        ? (tintColor ?? (isDark ? Colors.black : Colors.white))
        : (isDark ? Colors.black : Colors.white);
    final radius = borderRadius.topLeft.x;
    // iOS's real "Thin/Regular Material" blur reads noticeably stronger
    // than a plain sigma pass-through — boosting the caller's sigma here
    // (not changing call sites) gets the frost density in the same range
    // as actual iOS glass instead of looking under-blurred.
    final effectiveSigma = sigma * 2.4;

    return LiquidGlassLens(
      style: LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderType: const OpticalBorder(
            borderSaturation: 1.6,
            ambientIntensity: 1.4,
            borderSolidity: 0.15,
          ),
        ),
        appearance: LiquidGlassAppearance(
          color: base.withValues(alpha: isDark ? 0.34 : 0.42),
          blur: LiquidGlassBlur(sigmaX: effectiveSigma, sigmaY: effectiveSigma),
          saturation: 1.8,
          shadow: const LiquidGlassShadow(blur: 6.0, opacity: 0.28),
        ),
        refraction: const LiquidGlassRefraction(
          distortion: 0.22,
          distortionWidth: 42,
          magnification: 1.04,
          chromaticAberration: 0.012,
        ),
      ),
      child: child,
    );
  }
}

/// Enter/exit transition that never creates an offscreen layer.
///
/// A FadeTransition/Opacity below 1.0 forces a `saveLayer`, which cuts a
/// glass surface off from the page behind it -- so the glass would flash
/// flat for the duration of the transition. This drives the same 'appear'
/// feel with only translate + scale (no opacity), left as a passthrough
/// here since callers only need the identity behavior.
/// [anim] is the AnimatedSwitcher animation (0 -> 1 in, 1 -> 0 out).
class GlassSafeEnter extends StatelessWidget {
  final Animation<double> anim;
  final Widget child;
  const GlassSafeEnter({super.key, required this.anim, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
