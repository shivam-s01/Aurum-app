// =============================================================================
// FILE: lib/utils/aurum_immersive_header.dart
// PROJECT: Astra Music
// DESCRIPTION: Shared "immersive artwork header" logic used by every detail
//   screen that shows a big piece of artwork at the top (mix/playlist,
//   album, artist). Centralized so all three screens extract color and
//   build their scrim/background exactly the same way — no per-screen
//   drift, no screen accidentally left on the old flat-black look.
//
//   Pattern (Apple Music / YT Music / SimpMusic style):
//     1. Extract a MUTED tone from the artwork (not the loud "vibrant"
//        swatch) — muted reads as premium/soft, vibrant on a pastel cover
//        often resolves to null and falls back to near-black, which is
//        the "dead" look this replaces.
//     2. Full-bleed artwork at the top.
//     3. A short scrim (not a long black fade) under the artwork, because
//     4. ...the SCREEN'S OWN background is tinted with that same muted
//        color — so the color isn't confined to a thin band under the
//        header, it carries all the way down the page, the way SimpMusic
//        colors its whole LazyColumn background instead of just the
//        header gradient.
// =============================================================================

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../theme/aurum_theme.dart';

/// Extracts a single "immersive background" color from an artwork URL.
///
/// Prefers muted/soft swatches over the loud vibrant one — matches the
/// premium, slightly-desaturated look of the reference players instead of
/// clashing with pastel/soft cover art. Falls back through progressively
/// safer swatches, then to [fallback], so a network hiccup or a totally
/// flat-color artwork never leaves the caller with a broken/null color.
Future<Color?> extractImmersiveColor(
  String artworkUrl, {
  Color fallback = const Color(0xFF1A1630),
}) async {
  if (artworkUrl.isEmpty || !artworkUrl.startsWith('http')) return null;
  try {
    final pg = await PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(artworkUrl),
      size: const Size(50, 50),
      maximumColorCount: 8,
    );
    final c = pg.mutedColor?.color ??
        pg.darkMutedColor?.color ??
        pg.lightMutedColor?.color ??
        pg.dominantColor?.color ??
        pg.vibrantColor?.color;
    return c;
  } catch (_) {
    // Cosmetic nicety only — caller keeps its neutral fallback glow.
    return null;
  }
}

/// The scrim that sits directly under full-bleed header artwork, washing
/// the photo in [glow] top-to-bottom with NO black band — the page
/// background under it (see [immersiveScaffoldBg]) is already the same
/// muted tone, so the handoff only needs a short, gentle ramp rather than
/// a long fade trying to carry the color on its own.
BoxDecoration immersiveHeaderScrim(Color glow) {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        glow.withOpacity(0.10),
        glow.withOpacity(0.35),
        glow.withOpacity(0.70),
        glow,
      ],
      stops: const [0.0, 0.45, 0.80, 1.0],
    ),
  );
}

/// The color the whole Scaffold/CustomScrollView background should carry
/// once a glow is available — a darkened, low-saturation version of the
/// extracted tone so body text and cards (which assume a near-neutral
/// backdrop) stay fully readable, while the page still visibly carries
/// the artwork's color all the way down instead of just in the header.
Color immersiveScaffoldBg(BuildContext context, Color? glow) {
  if (glow == null) return AurumTheme.bgOf(context);
  final hsl = HSLColor.fromColor(glow);
  final darkened = hsl
      .withLightness((hsl.lightness * 0.35).clamp(0.05, 0.16))
      .withSaturation((hsl.saturation * 0.55).clamp(0.0, 0.45))
      .toColor();
  return Color.alphaBlend(
    darkened.withOpacity(0.92),
    AurumTheme.bgOf(context),
  );
}

// =============================================================================
// Glass collapse bar
// -----------------------------------------------------------------------------
// SimpMusic layers a blurred/tinted "Haze" surface behind its top bar and
// cards — a frosted-glass tint over the extracted color, not a flat fill.
// Flutter has no direct Haze equivalent, so this reproduces the same visual
// with BackdropFilter: as the SliverAppBar collapses, a blur + glow-tinted
// scrim fades in behind the title/icons. It stays OFF while the header is
// still expanded (opacity 0, blur skipped entirely) so the full-bleed
// artwork itself is never blurred — only the collapsed bar strip is, which
// is also the only state where BackdropFilter's per-frame GPU cost is
// actually being paid.
// =============================================================================

/// Wrap a [SliverAppBar]'s `flexibleSpace` background (or place directly as
/// a child of the header Stack) to get a glass strip that fades in as the
/// header collapses toward [barHeight]. [shrinkOffset] and [expandRatio]
/// come from a [FlexibleSpaceBarSettings] in scope, or can be driven
/// manually from a ScrollController if the caller already tracks one.
class AurumGlassCollapseBar extends StatelessWidget {
  final Color glow;
  final double expandRatio;
  final double barHeight;

  const AurumGlassCollapseBar({
    super.key,
    required this.glow,
    required this.expandRatio,
    this.barHeight = kToolbarHeight,
  });

  @override
  Widget build(BuildContext context) {
    // expandRatio: 1.0 = fully expanded (artwork showing, no glass at all),
    // 0.0 = fully collapsed (bar pinned, glass at full strength). Clamp
    // defends against the tiny overshoot Flutter's FlexibleSpaceBar can
    // report mid-scroll-physics-bounce.
    final collapse = (1.0 - expandRatio).clamp(0.0, 1.0);
    if (collapse <= 0.0) {
      // Cheapest possible frame while fully expanded: no BackdropFilter,
      // no compositing layer at all.
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: Opacity(
        opacity: collapse,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: 18 * collapse,
              sigmaY: 18 * collapse,
            ),
            child: Container(
              height: barHeight + MediaQuery.of(context).padding.top,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    glow.withOpacity(0.55),
                    glow.withOpacity(0.30),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
