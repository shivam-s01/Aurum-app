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
import '../theme/aurum_theme.dart';
import 'artwork_palette_cache.dart';

/// Extracts a single "immersive background" color from an artwork URL.
///
/// FIX ("artwork khulte hi turant catch le, 1-2 sec ka flash na ho"):
/// this used to call PaletteGenerator directly, uncached, on every single
/// screen entry — no `peek()`, no fast approximation, no timeout, and (like
/// artwork_palette_cache.dart's own history) it only recognized http(s)
/// URLs, silently doing nothing for a local/content:// song's art. That
/// meant a full ~1s+ decode+quantize EVERY time this screen opened, even
/// for artwork already extracted elsewhere in the app (Full Player, a
/// playlist card) two seconds earlier.
///
/// Routing through the same [ArtworkPaletteCache] Full Player and
/// PlaylistColorCover already use fixes all of that in one move: an
/// already-seen artwork resolves from [ArtworkPaletteCache.peek] instantly
/// (same frame, no async gap at all), a first-ever look gets the ~16x16
/// fast pass in well under 100ms instead of a full decode, content://
/// and local file art now actually extracts instead of silently no-op'ing,
/// and every cache entry is shared across every screen — so by the time a
/// user backs out of a mix screen into an album screen showing the same
/// artwork, that screen's first frame is already the real color, not the
/// fallback.
///
/// Prefers muted/soft swatches over the loud vibrant one — matches the
/// premium, slightly-desaturated look of the reference players instead of
/// clashing with pastel/soft cover art.
Future<Color?> extractImmersiveColor(
  String artworkUrl, {
  Color fallback = const Color(0xFF1A1630),
}) async {
  if (artworkUrl.isEmpty) return null;

  // Instant path: this exact artwork was already extracted anywhere else
  // in the app (Full Player, a playlist card, another detail screen) —
  // resolves synchronously, so the very first frame can already show the
  // real color instead of the flat fallback.
  final cached = ArtworkPaletteCache.peek(artworkUrl);
  if (cached != null) return _pickMuted(cached);

  // First-ever look at this artwork: kick off the accurate extraction
  // (which caches itself for every future call/screen) but don't make
  // the caller wait 1.2s for it — race it against the ~16x16 fast pass,
  // which typically resolves in well under 100ms, and take whichever
  // finishes first. Either way the accurate one keeps running and will
  // update the cache for the next screen/replay regardless of which arm
  // of this race wins.
  final accurateFuture = ArtworkPaletteCache.get(artworkUrl);
  final fast = await ArtworkPaletteCache.getFast(artworkUrl);
  if (fast != null) return _pickMuted(fast);

  // No fast approximation available (e.g. unrecognized URL shape) — fall
  // through to waiting on the accurate extraction, which itself has its
  // own internal 1.2s timeout and never throws.
  final accurate = await accurateFuture;
  return _pickMuted(accurate);
}

Color _pickMuted(ArtworkPalette p) => p.darkMuted;

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

  // CHANGE ("hamesha halka glass dikhe, simpmusic jaisa"): SimpMusic's
  // Haze bar isn't scroll-gated at all — it's a permanently-transparent
  // container with hazeEffect() always active, so the bar reads as
  // faintly glassy even at the very top of a fully expanded header, then
  // visibly strengthens once real content scrolls behind it. A hard 0.0
  // floor (the old behavior) meant zero glass the instant a screen
  // opened — correct for "cheapest possible frame while expanded," but
  // not the always-on glass look being asked for here.
  //
  // _minStrength is that floor: never fully off, always ramping up to
  // full strength by the time the header finishes collapsing. Softer
  // than full strength at rest so it still reads as "expanded, but with
  // a glass hint" rather than "already collapsed."
  static const double _minStrength = 0.22;

  @override
  Widget build(BuildContext context) {
    // expandRatio: 1.0 = fully expanded, 0.0 = fully collapsed. Clamp
    // defends against the tiny overshoot Flutter's FlexibleSpaceBar can
    // report mid-scroll-physics-bounce.
    final collapseRaw = (1.0 - expandRatio).clamp(0.0, 1.0);
    // Remap so 0.0 collapse -> _minStrength (not 0), 1.0 collapse -> 1.0,
    // linearly in between — the floor, not a separate on/off switch.
    final strength = _minStrength + (1.0 - _minStrength) * collapseRaw;
    return IgnorePointer(
      child: Opacity(
        opacity: strength,
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: 18 * strength,
              sigmaY: 18 * strength,
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
