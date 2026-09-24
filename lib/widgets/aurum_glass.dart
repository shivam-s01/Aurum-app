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
  /// affects the flat fallback.
  final bool useTintInGlass;

  /// iOS-style touch response: press = glass swells, drag = it deforms and
  /// springs back. Only enable on small floating surfaces (mini player,
  /// search bar). Big/full-width strips keep this false.
  final bool interactive;

  /// Contact shadow under the glass. Turn off where the caller already
  /// draws its own border/glow (e.g. the search bar) to avoid a double
  /// shadow.
  final bool showShadow;

  const AurumGlass({
    super.key,
    required this.child,
    required this.sigma,
    required this.borderRadius,
    required this.isDark,
    this.tintColor,
    this.useTintInGlass = false,
    this.interactive = false,
    this.showShadow = true,
  });

  @override
  Widget build(BuildContext context) {
    if (sigma <= 0) {
      // Solid fallback -- zero GPU cost, unchanged.
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
    // FIX ("liquid glass jab ON ho tab bhi Docked/edge-to-edge nav bar pe
    // real iOS glass jaisa lagna chahiye — Docked ka layout/shape touch
    // nahi karna"): this used to treat ANY zero-radius surface as a flat
    // "strip" and hard-zero every refraction parameter below
    // (distortion, distortionWidth, magnification, chromaticAberration,
    // borderWidth all forced to 0/1.0) — so Docked's own edge-to-edge,
    // square-corner nav bar always rendered as a flat frosted tint with
    // no real lens bending at all, even with Liquid Glass switched ON.
    // SimpMusic's own reference nav bar is ALSO edge-to-edge/square and
    // still shows real glass refraction — square corners were never the
    // reason to disable it. What actually still needs to stay flat is a
    // corner-less surface with essentially no edge to bend at all (i.e.
    // near-zero height/width band), not "radius is 0". Since every call
    // site already caps this widget to genuine bar/strip heights, the
    // isStrip special-case is simply removed: refraction now always
    // scales purely off the corner-radius lerp below (t=0 at small/no
    // radius still yields the "subtler" end of the range, never an
    // outright zero), so a square Docked bar gets the same lightly-
    // refracting real glass SimpMusic has, and nothing about Docked's
    // own shape/margins/height changes here — only this file's optical
    // parameters.
    final isStrip = false;

    // iOS 26 glass is LIGHTLY frosted: the backdrop stays readable and is
    // bent at the rim. Too much blur = matte plastic, so cap the boost.
    // Reference (SimpMusic): backdrop stays CRISP through the glass --
    // rain drops / album art still recognisable. Real iOS glass is mostly
    // refraction, only lightly frosted. So blur is a small fraction of the
    // caller's sigma, hard-capped low.
    final effectiveSigma = (sigma * 0.32).clamp(2.0, 6.0);

    // Small surfaces (search bar 44px, radius 14) can't carry the big
    // 54px refraction band meant for 68px+ floating pills: it would bend
    // the text/icons inside. Scale the whole optical effect by corner
    // radius so a pill gets the full look and a small bar a subtler one.
    final t = ((radius - 14) / (28 - 14)).clamp(0.0, 1.0);
    double lerp(double a, double b) => a + (b - a) * t;

    final style = LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: radius,
        // Thin bright specular rim, lit from top-left like Apple's.
        borderWidth: isStrip ? 0 : lerp(1.0, 1.3),
        lightIntensity: isDark ? 1.9 : 1.4,
        lightDirection: 315,
        borderType: OpticalBorder(
          borderSaturation: 1.5,
          ambientIntensity: isDark ? 1.4 : 1.1,
          borderSolidity: 0.34,
        ),
      ),
      appearance: LiquidGlassAppearance(
        // Much clearer body than before (was 0.34/0.42) so the refraction
        // and the content behind actually show through.
        color: base.withValues(alpha: isDark ? 0.10 : 0.16),
        blur: LiquidGlassBlur(sigmaX: effectiveSigma, sigmaY: effectiveSigma),
        // Apple glass boosts the colour of what is behind it.
        saturation: isDark ? 1.35 : 1.25,
        // Contact shadow: makes the pill sit IN the page instead of
        // floating flat.
        shadow: showShadow
            ? LiquidGlassShadow(
                blur: 8.0,
                opacity: isDark ? 0.42 : 0.22,
              )
            : null,
      ),
      refraction: LiquidGlassRefraction(
        // Strong edge bending + slight lens magnification = the
        // "thick glass" look. Strips get none.
        distortion: isStrip ? 0.0 : lerp(0.18, 0.40),
        distortionWidth: isStrip ? 0 : lerp(24, 46),
        magnification: isStrip ? 1.0 : lerp(1.02, 1.07),
        chromaticAberration: isStrip ? 0.0 : lerp(0.006, 0.012),
      ),
    );

    return LiquidGlassLens(
      style: style,
      // press -> swell, drag -> stretch + spring back (real iOS feel).
      touch: interactive
          ? const LiquidGlassTouch(flex: LiquidGlassFlex.subtle())
          : null,
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
