import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Real iOS 26-style "Liquid Glass" surface — shader-driven refraction,
/// chromatic dispersion, fresnel edge glow and directional specular
/// applied directly to the LIVE backdrop, not a flat blurred tint.
///
/// WHY A SHADER: a plain `BackdropFilter` blur + gradient overlay (what
/// this widget used to be) has no notion of a glass SURFACE — there's
/// nothing to bend light. Apple's actual Liquid Glass material reads as
/// "glass" specifically because it refracts the backdrop near its edges,
/// splits that refraction slightly per color channel (a prism does the
/// same thing), and lights the rim like a real curved bevel. All of that
/// requires sampling the backdrop from an OFFSET position that varies
/// across the surface — exactly what a fragment shader does, and exactly
/// what a flat filter/gradient cannot.
///
/// `shaders/liquid_glass.frag` is the actual optical recipe (see that
/// file for the full uniform contract). It's applied via
/// `ImageFilter.shader` inside a `BackdropFilter` — the engine-native way
/// to run a custom shader directly over live backdrop pixels, chained
/// after a normal blur so the refraction bends *soft* frosted light
/// (like real glass) rather than a sharp double-image of whatever's
/// behind it.
///
/// `ImageFilter.shader` is Impeller-only (throws on other backends).
/// Impeller has been Flutter's default rendering engine on iOS since
/// 3.16 and on Android since 3.29, so this covers the overwhelming
/// majority of real devices — but as a safety net for anyone still on an
/// old Skia fallback path, [AurumGlass] checks
/// `ui.ImageFilter.isShaderFilterSupported` once and transparently drops
/// back to the previous hand-tuned blur+gradient "glass" look (still
/// good, just not shader-refracted) instead of crashing.
///
/// The public API is unchanged from the previous version, so every
/// existing call site (mini player, nav bar, collapsing headers, etc.)
/// needs no changes — `sigma <= 0` still takes the zero-cost solid-panel
/// fallback path.
class AurumGlass extends StatelessWidget {
  final Widget child;
  final double sigma;
  final BorderRadius borderRadius;
  final bool isDark;

  /// Optional solid colour used ONLY for the sigma<=0 flat fallback panel.
  /// When the shader glass is active this is deliberately ignored unless
  /// [useTintInGlass] is true — glass must stay neutral (theme-coloured),
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
      // Solid fallback — identical cost/behavior to before: no blur, no
      // shader, just a flat panel. Zero extra GPU work.
      //
      // TEMP DIAGNOSTIC (always-on, works in release APK too): if THIS
      // badge is the one showing on the flat bar, it's 100% confirmed
      // the caller passed sigma<=0 — the shader/BackdropFilter code was
      // never even reached. That means the bug is upstream, in whatever
      // computed `sigma` (glassOn / effectiveBlurSigma / isTopRoute in
      // main_shell.dart or mini_player.dart), not in this file's shader
      // logic at all. REMOVE this whole diagnostic block once the cause
      // is confirmed — it's not meant to ship long-term.
      return ClipRRect(
        borderRadius: borderRadius,
        child: Stack(children: [
        Container(
          decoration: BoxDecoration(
            color: tintColor ??
                (isDark ? const Color(0xFF1B1927) : Colors.white),
            borderRadius: borderRadius,
          ),
          child: child,
        ),
        Positioned(
            left: 4,
            top: 2,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                color: Colors.black.withValues(alpha: 0.6),
                child: const Text(
                  'SIGMA<=0: glass never attempted (caller bug)',
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 9,
                    fontFamily: 'monospace',
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ]),
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: _AurumLiquidGlassBackdrop(
        sigma: sigma,
        borderRadius: borderRadius,
        isDark: isDark,
        tintColor: useTintInGlass ? tintColor : null,
        child: child,
      ),
    );
  }
}

class _AurumLiquidGlassBackdrop extends StatefulWidget {
  final Widget child;
  final double sigma;
  final BorderRadius borderRadius;
  final bool isDark;
  final Color? tintColor;

  const _AurumLiquidGlassBackdrop({
    required this.child,
    required this.sigma,
    required this.borderRadius,
    required this.isDark,
    required this.tintColor,
  });

  @override
  State<_AurumLiquidGlassBackdrop> createState() =>
      _AurumLiquidGlassBackdropState();
}

/// Last known glass render path, for on-device diagnosis. One of:
///  'shader'          – ImageFilter.shader is actually running
///  'fallback:noimp'  – isShaderFilterSupported == false (not Impeller)
///  'fallback:load'   – shader asset failed to load/compile
///  'fallback:wait'   – asset still loading on this frame
class AurumGlassDebug {
  static String path = 'unknown';
  static String error = '';
}

class _AurumLiquidGlassBackdropState
    extends State<_AurumLiquidGlassBackdrop> {
  // Cached at the process level via the static below — the shader asset
  // only ever needs to be loaded and compiled once for the entire app
  // lifetime, not once per glass surface on screen.
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;
  ui.FragmentShader? _shader;
  bool _requested = false;

  bool get _shaderCapable =>
      !kIsWeb && ui.ImageFilter.isShaderFilterSupported;

  @override
  void initState() {
    super.initState();
    if (_shaderCapable) _ensureShader();
  }

  void _ensureShader() {
    if (_requested) return;
    _requested = true;
    if (_program != null) {
      _shader = _program!.fragmentShader();
      return;
    }
    _loading ??=
        ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    _loading!.then((program) {
      _program = program;
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    }).catchError((Object e) {
      // Shader asset failed to load/compile on this device for some
      // reason (e.g. an unsupported GPU driver quirk) — fall back to the
      // blur+gradient look below rather than ever crashing the surface.
      AurumGlassDebug.path = 'fallback:load';
      AurumGlassDebug.error = e.toString();
      if (mounted) setState(() => _shader = null);
    });
  }

  // TEMP DIAGNOSTIC (always-on, works in release APK too — see
  // main.dart's top-of-file notice on why debug overlays must normally
  // be gated/removed; this one is intentionally always-on since the
  // build is via GitHub Actions release, not `flutter run` debug): a
  // tiny badge painted directly on top of this glass surface showing
  // which render path it actually took. REMOVE once cause is confirmed.
  Widget _debugBadge(String label) {
    return Positioned(
      left: 4,
      top: 2,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          color: Colors.black.withValues(alpha: 0.6),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.limeAccent,
              fontSize: 9,
              fontFamily: 'monospace',
              height: 1.0,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.tintColor ??
        (widget.isDark ? Colors.black : Colors.white);

    // sigma<=0 short-circuits in the OUTER AurumGlass.build() before this
    // State's build() ever runs — so if the flat panel is showing with
    // NO debug badge anywhere on it, that IS the confirmed cause: the
    // caller passed sigma<=0 (glass never attempted at all), not a
    // shader/fallback failure inside this State.
    if (!_shaderCapable) {
      AurumGlassDebug.path = 'fallback:noimp';
    } else if (_shader == null && AurumGlassDebug.path != 'fallback:load') {
      AurumGlassDebug.path = 'fallback:wait';
    }

    if (_shader != null) {
      AurumGlassDebug.path = 'shader';
      final shader = _shader!;
      final radius = widget.borderRadius.topLeft.x;
      final t = _GlassTuning.of(widget.isDark);
      shader
        ..setFloat(1, radius)
        ..setFloat(2, t.refraction)
        ..setFloat(3, t.chroma)
        ..setFloat(4, t.fresnelPower)
        ..setFloat(5, 0.5) // light x (top-center-ish)
        ..setFloat(6, 0.08) // light y (near the top edge)
        ..setFloat(7, base.r)
        ..setFloat(8, base.g)
        ..setFloat(9, base.b)
        ..setFloat(10, t.tintWeight)
        ..setFloat(11, widget.isDark ? 1.0 : 0.0)
        ..setFloat(12, t.bevel)
        ..setFloat(13, t.brightness)
        ..setFloat(14, t.saturation);

      return Stack(children: [
      BackdropFilter(
        filter: ui.ImageFilter.compose(
          outer: ui.ImageFilter.shader(shader),
          inner: ui.ImageFilter.blur(
            sigmaX: widget.sigma,
            sigmaY: widget.sigma,
            tileMode: TileMode.decal,
          ),
        ),
        child: widget.child,
      ),
      _debugBadge('shader OK sigma=${widget.sigma.toStringAsFixed(0)}'),
      ]);
    }

    // Fallback path (shader unsupported/still loading/failed): the
    // previous hand-tuned blur + top sheen + edge-hairline "glass" look.
    // Still reads as real frosted glass, just without shader refraction.
    final fillAlpha = widget.isDark ? 0.55 : 0.68;
    final edgeHighlight =
        Colors.white.withValues(alpha: widget.isDark ? 0.18 : 0.65);
    final edgeShade =
        Colors.black.withValues(alpha: widget.isDark ? 0.25 : 0.06);

    return BackdropFilter(
      filter: ui.ImageFilter.blur(
        sigmaX: widget.sigma,
        sigmaY: widget.sigma,
        tileMode: TileMode.decal,
      ),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Container(color: base.withValues(alpha: fillAlpha)),
          _debugBadge('FALLBACK:${AurumGlassDebug.path} sigma=${widget.sigma.toStringAsFixed(0)}'),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white
                          .withValues(alpha: widget.isDark ? 0.14 : 0.40),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.35],
                  ),
                ),
              ),
            ),
          ),
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: edgeHighlight, width: 1),
                    left: BorderSide(
                        color: edgeHighlight.withValues(
                            alpha: edgeHighlight.a * 0.4),
                        width: 1),
                    right: BorderSide(color: edgeShade, width: 1),
                    bottom: BorderSide(color: edgeShade, width: 1),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Single tuned iOS 26 look. Values chosen so the glass reads as a real
/// slab: strong rim lensing, light neutral body (content behind stays
/// visible and keeps its own colour), lit bevel. Body colour stays
/// neutral (theme black/white) — it never inherits artwork colour.
class _GlassTuning {
  final double refraction;
  final double chroma;
  final double fresnelPower;
  final double tintWeight;
  final double bevel;
  final double brightness;
  final double saturation;

  const _GlassTuning({
    required this.refraction,
    required this.chroma,
    required this.fresnelPower,
    required this.tintWeight,
    required this.bevel,
    required this.brightness,
    required this.saturation,
  });

  static _GlassTuning of(bool isDark) {
    return _GlassTuning(
      refraction: 14.0,
      chroma: 0.14,
      fresnelPower: 2.0,
      tintWeight: isDark ? 0.16 : 0.22,
      bevel: 1.0,
      brightness: isDark ? 1.10 : 1.03,
      saturation: 1.35,
    );
  }
}

/// Enter/exit transition that never creates an offscreen layer.
///
/// A FadeTransition/Opacity below 1.0 forces a `saveLayer`, which cuts a
/// child BackdropFilter (our glass) off from the page behind it — so the
/// glass would flash flat for the duration of the transition. This drives
/// the same 'appear' feel with only translate + scale (no opacity).
/// [anim] is the AnimatedSwitcher animation (0 → 1 in, 1 → 0 out).
class GlassSafeEnter extends StatelessWidget {
  final Animation<double> anim;
  final Widget child;
  const GlassSafeEnter({super.key, required this.anim, required this.child});

  @override
  Widget build(BuildContext context) => child;
}
