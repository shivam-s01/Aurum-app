import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_equalizer_bars.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AurumStackedArtwork — the "depth stack" look behind a track/artist cover,
// matched to Echo Nightly's item_shelf_media_cover.xml: two faint, offset
// rounded rectangles sit behind the real artwork (like a deck of cards peeking
// out), giving a flat square/circle image a sense of physical stacking instead
// of floating flat against the row. Echo's exact recipe, ported 1:1:
//   • back layer:  full width, -4dp/+4dp size delta, alpha 0.15
//   • front layer: full width, -2.5dp size delta,    alpha 0.25
//   • cover:       full size, alpha 1.0, on top
// Echo uses square corners tinted to the foreground color for the stack
// layers regardless of the cover's own shape — same here: the two backing
// layers always use `stackColor` (defaults to the theme's foreground/muted
// tone), while the cover itself can be circular (artist) or rounded-square
// (song) via `circular`.
//
// When `showNowPlaying` is true, an Echo-style dark circular badge with the
// live 3-bar equalizer wave is centered on top of the artwork — same visual
// role as Echo's `isPlaying` SmallNowPlayingButton overlay.
// ─────────────────────────────────────────────────────────────────────────────
class AurumStackedArtwork extends StatelessWidget {
  final String url;
  final double size;
  final double borderRadius;
  final bool circular;
  final bool showNowPlaying;
  final bool isPlaying;
  final Color? stackColor;

  const AurumStackedArtwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.circular = false,
    this.showNowPlaying = false,
    this.isPlaying = false,
    this.stackColor,
  });

  @override
  Widget build(BuildContext context) {
    final tint = stackColor ?? AurumTheme.textPrimaryOf(context);
    final stackRadius = circular ? size / 2 : borderRadius;

    return SizedBox(
      // Stack layers extend 4dp beyond the cover on each side (Echo's
      // -4dp/+4dp margins), so the box needs headroom or siblings in a
      // Row would clip the back layer's corners.
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Back layer — furthest offset, faintest, very slightly smaller
          // than the cover so it reads as a card peeking out from behind
          // rather than a blurred halo bleeding past the edges.
          Transform.translate(
            offset: const Offset(0, -4),
            child: Container(
              width: size - 3,
              height: size - 3,
              decoration: BoxDecoration(
                color: tint.withOpacity(0.15),
                borderRadius: BorderRadius.circular(stackRadius),
              ),
            ),
          ),
          // Front layer — closer offset, slightly stronger.
          Transform.translate(
            offset: const Offset(0, -2.5),
            child: Container(
              width: size - 1.5,
              height: size - 1.5,
              decoration: BoxDecoration(
                color: tint.withOpacity(0.25),
                borderRadius: BorderRadius.circular(stackRadius),
              ),
            ),
          ),
          // Real cover, full opacity, on top.
          circular
              ? ClipOval(
                  child: AurumArtwork(url: url, size: size, borderRadius: 0),
                )
              : AurumArtwork(url: url, size: size, borderRadius: borderRadius),

          if (showNowPlaying)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.45),
                borderRadius: BorderRadius.circular(stackRadius),
              ),
              alignment: Alignment.center,
              child: AurumEqualizerBars(
                playing: isPlaying,
                color: Colors.white,
                size: size * 0.36,
              ),
            ),
        ],
      ),
    );
  }
}
