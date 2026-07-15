// aurum_loader.dart
// Aurum Music — Loading System
// Material 3 Fluid Morphing Indeterminate Progress Bar
// Use everywhere: AurumM3Loader() for inline, AurumM3Loader(height:6) for thick bars.
// Mini player progress bar stays as LinearProgressIndicator — intentional.

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:aurum_music/widgets/aurum_morph_loader.dart';
import 'package:aurum_music/providers/theme_provider.dart';
export 'package:aurum_music/widgets/aurum_morph_loader.dart';

// ══════════════════════════════════════════════════════════════════
// DESIGN TOKENS
// ══════════════════════════════════════════════════════════════════

// (Hardcoded _C color tokens removed — colors now derive from the user's
// live accent color via ThemeProvider, see AurumM3Loader.build() above.)

// ══════════════════════════════════════════════════════════════════
// AurumM3Loader — Material 3 Fluid Morphing Indeterminate Bar
// ══════════════════════════════════════════════════════════════════
//
// Two segments travel across the track with independent easing
// so they stretch and compress organically — exactly M3 spec motion.
// Color: gold shimmer → purple glow, with bright head highlight.
//
// Usage:
//   const AurumM3Loader()                      // fill parent width, 3px tall
//   const AurumM3Loader(height: 6)             // thicker
//   const AurumM3Loader(width: 120, height: 2) // fixed width
//   const AurumM3Spinner()                     // icon-sized square slot
//   const AurumM3Spinner(size: 20)

// Nudges [color] away from [surface] when their perceived brightness is
// too close to tell apart, so an indeterminate bar/glow never visually
// disappears into whatever it's painted on top of. Leaves [color]
// untouched when contrast is already fine — this only kicks in for
// accent choices that would otherwise be a near-invisible bug.
Color _ensureContrast(Color color, Color surface) {
  final colorLum = color.computeLuminance();
  final surfaceLum = surface.computeLuminance();
  if ((colorLum - surfaceLum).abs() > 0.25) return color;
  // Push toward white on a dark surface, toward black on a light one —
  // whichever direction guarantees separation from the surface.
  final target = surfaceLum > 0.5 ? Colors.black : Colors.white;
  return Color.lerp(color, target, 0.45)!;
}

class AurumM3Loader extends StatefulWidget {
  const AurumM3Loader({
    super.key,
    this.width,
    this.height = 3.0,
    this.borderRadius = 99.0,
  });

  final double? width;
  final double  height;
  final double  borderRadius;

  @override
  State<AurumM3Loader> createState() => _AurumM3LoaderState();
}

class _AurumM3LoaderState extends State<AurumM3Loader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static final _s1s = CurveTween(curve: const Interval(0.0,  0.70, curve: Curves.easeIn));
  static final _s1e = CurveTween(curve: const Interval(0.10, 0.90, curve: Curves.fastOutSlowIn));
  static final _s2s = CurveTween(curve: const Interval(0.40, 0.98, curve: Curves.easeIn));
  static final _s2e = CurveTween(curve: const Interval(0.50, 1.00, curve: Curves.fastOutSlowIn));

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    // FIX — "loading bar is a fixed purple/pink, doesn't match my chosen
    // accent color": this used to always paint with hardcoded _C.purple
    // tokens. Now derives light/base/dark shades from the user's live
    // accent color (same source as the nav bar and Settings → Appearance
    // picker), so every M3 loading bar in the app matches whatever accent
    // is actually selected.
    final rawAccent = context.select<ThemeProvider, Color>((tp) => tp.accentColor);
    // FIX ("search bar goes theme-colored, can't see anything while
    // typing"): this loader (shown right under the search bar during
    // live search) always painted using the user's raw accent color with
    // no check against what it's sitting on. If someone picks an accent
    // close in tone to the card/background surface, the moving bar and
    // its surrounding glow blend almost invisibly into the search bar —
    // it reads as the whole bar "going theme-colored" with no visible
    // contrast to tap or read against. Guard against that by nudging the
    // accent away from the current surface color whenever contrast is
    // too low, so the loader (and by extension the search bar it sits
    // in) always stays clearly visible no matter which accent is chosen.
    final surface = AurumTheme.bgCardOf(context);
    final accent = _ensureContrast(rawAccent, surface);
    final accentLight = Color.lerp(accent, Colors.white, 0.30)!;
    final accentDark = Color.lerp(accent, Colors.black, 0.35)!;

    final painter = AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _M3Painter(
          s1s: _s1s.evaluate(_ctrl),
          s1e: _s1e.evaluate(_ctrl),
          s2s: _s2s.evaluate(_ctrl),
          s2e: _s2e.evaluate(_ctrl),
          h: widget.height,
          r: widget.borderRadius,
          base: accent,
          light: accentLight,
          dark: accentDark,
        ),
      ),
    );

    // If a fixed width was given, just size to it directly.
    if (widget.width != null) {
      return RepaintBoundary(
        child: SizedBox(width: widget.width, height: widget.height, child: painter),
      );
    }

    // No width given — fill whatever space is available (e.g. inside
    // Center(), which otherwise hands us unbounded width and collapses
    // a null-width SizedBox to 0px, making the bar invisible).
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : (constraints.biggest.width.isFinite
                  ? constraints.biggest.width
                  : MediaQuery.sizeOf(context).width);
          return SizedBox(width: w, height: widget.height, child: painter);
        },
      ),
    );
  }
}

class _M3Painter extends CustomPainter {
  const _M3Painter({
    required this.s1s, required this.s1e,
    required this.s2s, required this.s2e,
    required this.h,   required this.r,
    required this.base, required this.light, required this.dark,
  });

  final double s1s, s1e, s2s, s2e, h, r;
  final Color base, light, dark;

  @override
  void paint(Canvas canvas, Size size) {
    final w  = size.width;
    final br = math.min(r, h / 2);

    // Track
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), Radius.circular(br)),
      Paint()..color = base.withOpacity(0.10),
    );

    void seg(double normStart, double normEnd) {
      if (normEnd <= normStart) return;
      final left  = (normStart * w).clamp(0.0, w);
      final right = (normEnd   * w).clamp(0.0, w);
      if (right - left < 0.5) return;

      final rect  = Rect.fromLTWH(left, 0, right - left, h);
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(br));

      // Bloom glow — matches the accent color so every loading indicator
      // in the app reads as the same single accent color the user chose.
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.inflate(h), Radius.circular(br + h)),
        Paint()
          ..color      = light.withOpacity(0.18)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 2),
      );

      // Solid accent bar (dark -> base -> light only)
      canvas.drawRRect(rrect, Paint()
        ..shader = ui.Gradient.linear(
          Offset(left, 0), Offset(right, 0),
          [dark, base, light],
          [0.0, 0.5, 1.0],
        ));

      // Bright head highlight
      final headW = math.min(h * 3, right - left);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(right - headW, 0, headW, h),
          Radius.circular(br),
        ),
        Paint()..shader = ui.Gradient.linear(
          Offset(right - headW, 0), Offset(right, 0),
          [Colors.transparent, Colors.white.withOpacity(0.55)],
        ),
      );
    }

    seg(s1s, s1e);
    seg(s2s, s2e);
  }

  @override
  bool shouldRepaint(covariant _M3Painter o) =>
      o.s1s != s1s || o.s1e != s1e || o.s2s != s2s || o.s2e != s2e ||
      o.base != base || o.light != light || o.dark != dark;
}

// ══════════════════════════════════════════════════════════════════
// AurumM3Spinner — drop-in for icon-sized loading slots
// ══════════════════════════════════════════════════════════════════

class AurumM3Spinner extends StatelessWidget {
  const AurumM3Spinner({super.key, this.size = 28.0});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size,
    child: Center(child: AurumM3Loader(width: size, height: 2.5)),
  );
}

// ══════════════════════════════════════════════════════════════════
// AurumLoaderScreen — full-page loading screen (uses M3 bar now)
// ══════════════════════════════════════════════════════════════════

class AurumLoaderScreen extends StatelessWidget {
  const AurumLoaderScreen({super.key, this.onCompleted});
  final VoidCallback? onCompleted;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: const Center(
        child: AurumMorphLoader(size: 56),
      ),
    );
  }
}
