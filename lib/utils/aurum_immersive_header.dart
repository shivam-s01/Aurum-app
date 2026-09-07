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
/// the photo in [glow] top-to-bottom — the page background under it (see
/// [immersiveScaffoldBg]) is already the same muted tone, so the handoff
/// only needs a short, gentle ramp rather than a long fade trying to
/// carry the color on its own.
///
/// FIX ("Pritam artist page, 90s songs playlist, Saajan Chale Sasural
/// album — title text invisible on light/washed artwork"): this used to
/// end the gradient at raw [glow] with no floor on how dark that bottom
/// stop actually is. [glow] can legitimately be light — either because
/// the source artwork itself is pale (a snowy photo, a faded film-poster
/// scan) or because `ensureContrastSafe` deliberately lightens it for
/// light-mode readability elsewhere on the same screen — and every
/// caller draws solid-white title text with only a soft shadow directly
/// over this exact bottom stop, assuming it's always dark. A light glow
/// made that assumption false and the title unreadable. The bottom stop
/// now always blends toward nearly-black regardless of glow's own
/// lightness, so the artwork's color still carries the wash (it's still
/// visibly tinted, not flat black) but the strip title text sits on is
/// guaranteed dark enough for white text every time.
BoxDecoration immersiveHeaderScrim(Color glow) {
  // Locks in a dark floor for the bottom of the scrim independent of how
  // light `glow` itself is — keeps the hue (blended in, not replaced)
  // while guaranteeing the luminance white text needs.
  final textSafeBottom = Color.alphaBlend(
    glow.withOpacity(0.55),
    const Color(0xFF0A0810),
  );
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        glow.withOpacity(0.10),
        glow.withOpacity(0.35),
        glow.withOpacity(0.70),
        textSafeBottom,
      ],
      stops: const [0.0, 0.45, 0.80, 1.0],
    ),
  );
}

/// The color the whole Scaffold/CustomScrollView background should carry
/// once a glow is available — a low-saturation version of the extracted
/// tone so body text and cards (which assume a near-neutral backdrop)
/// stay fully readable, while the page still visibly carries the
/// artwork's color all the way down instead of just in the header.
///
/// FIX ("kuch sec mein artwork chalta hai to alag color aata hai" —
/// theme-blind crush): this used to unconditionally clamp lightness to
/// 0.05-0.16 regardless of theme, i.e. it always produced a near-black
/// tint and alpha-blended it at 92% opacity over the scaffold. In dark
/// mode that's roughly invisible against an already-dark background, but
/// in light mode it dumps a dark blob under white/bright cards — reads
/// as a rendering glitch, not a deliberate wash. The correct, Apple
/// Music/YT Music/SimpMusic-style behavior is theme-symmetric: dark mode
/// gets a deepened, low-saturation version of the glow; light mode gets
/// a lifted, gently-tinted version of the SAME glow — same hue carried
/// through both, only lightness/saturation direction flips, and the
/// blend ratio is tuned separately per mode so the result never fights
/// with either theme's own surface tone.
Color immersiveScaffoldBg(BuildContext context, Color? glow) {
  if (glow == null) return AurumTheme.bgOf(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final hsl = HSLColor.fromColor(glow);

  final Color tinted;
  final double blendOpacity;
  if (isDark) {
    // Deepen toward the dark surfaces' own tonal range (darkBg sits
    // around L≈0.11) instead of crushing all the way to near-black —
    // keeps the hue readable as a color, not a shadow.
    tinted = hsl
        .withLightness((hsl.lightness * 0.45).clamp(0.09, 0.22))
        .withSaturation((hsl.saturation * 0.55).clamp(0.0, 0.45))
        .toColor();
    blendOpacity = 0.92;
  } else {
    // Lift toward the light surfaces' own tonal range (lightBg sits
    // around L≈0.94) — same hue, pushed up instead of down, and
    // saturation pulled in further since a light wash reads "tinted"
    // at a much lower saturation than a dark one needs to.
    tinted = hsl
        .withLightness((0.90 + hsl.lightness * 0.08).clamp(0.90, 0.97))
        .withSaturation((hsl.saturation * 0.35).clamp(0.0, 0.22))
        .toColor();
    // Lighter touch in light mode: the goal is a warm cast behind white
    // cards, not a colored panel — too strong here reads as a stain.
    blendOpacity = 0.55;
  }

  return Color.alphaBlend(
    tinted.withOpacity(blendOpacity),
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

  // REVERTED ("scroll pr upar akward sa patti aa rahi hai" — 2026-09-07):
  // the previous always-on floor (0.22) meant a faint hazy strip sat
  // across the top of the header even while fully expanded, over sharp
  // artwork that was never meant to be blurred at rest — read as a
  // rendering glitch/dead strip, not intentional chrome. Reference
  // players (Bloomee, YT Music) only show glass once the bar has
  // actually started collapsing over content — zero blur, zero tint,
  // completely invisible at full expansion.
  static const double _minStrength = 0.0;

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
