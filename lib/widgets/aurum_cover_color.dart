// =============================================================================
// FILE: lib/widgets/aurum_cover_color.dart
// PROJECT: Aurum Music
// DESCRIPTION: SimpMusic-style "no thumbnail" playlist cover — a smooth
//   diagonal gradient derived automatically from the playlist's own first
//   song's artwork (via the shared ArtworkPaletteCache, same extractor the
//   Full Player background already uses), not a user-picked color.
//     • getFast() paints an instant coarse average-color gradient the
//       moment art bytes exist, so there's never a flat/blank frame
//     • the accurate multi-swatch palette (vibrant + darkMuted) crossfades
//       in over it once ready — both extractions are already cached, so
//       every repeat visit to the same playlist is instant either way
//     • a playlist with genuinely no songs (nothing to extract from) falls
//       back to one fixed, deliberately-designed brand gradient — never a
//       randomized or mismatched pair, so it never reads as broken.
// =============================================================================

import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';
import '../utils/artwork_palette_cache.dart';
import '../utils/aurum_motion.dart';

/// Renders a playlist's "no thumbnail" identity as a rich diagonal
/// gradient sourced from its own first song's artwork — the shared
/// treatment for every screen that shows a playlist without a real
/// cover image (detail header, library card, "add to playlist" picker).
class PlaylistColorCover extends StatefulWidget {
  /// The artwork URL/URI to derive the gradient from — pass the
  /// playlist's first song's artworkUrl (or '' for a genuinely empty
  /// playlist, which uses the fixed brand fallback below).
  final String artworkUrl;
  final double size;
  final double borderRadius;
  final double? iconSize;

  const PlaylistColorCover({
    super.key,
    required this.artworkUrl,
    required this.size,
    this.borderRadius = 12,
    this.iconSize,
  });

  // Fixed, deliberately-designed fallback for playlists with no songs at
  // all to extract a color from yet — never randomized, so every empty
  // playlist looks intentional and consistent rather than mismatched.
  static const Color _fallbackA = AurumTheme.accent;
  static const Color _fallbackB = Color(0xFF3A2F5C);

  @override
  State<PlaylistColorCover> createState() => _PlaylistColorCoverState();
}

class _PlaylistColorCoverState extends State<PlaylistColorCover> {
  List<Color>? _colors;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PlaylistColorCover old) {
    super.didUpdateWidget(old);
    if (old.artworkUrl != widget.artworkUrl) {
      _colors = null;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.artworkUrl;
    if (url.isEmpty) return;

    // Instant coarse pass — paints something real the moment art bytes
    // exist instead of sitting on the flat fallback while the accurate
    // extraction (below) is still decoding.
    final fast = ArtworkPaletteCache.peek(url) ?? await ArtworkPaletteCache.getFast(url);
    if (fast != null && mounted) {
      setState(() => _colors = [fast.vibrant, fast.darkMuted]);
    }

    // Accurate pass — cached, so every repeat visit resolves instantly
    // and this just overwrites the coarse guess with the real palette.
    final accurate = await ArtworkPaletteCache.get(url);
    if (mounted) {
      setState(() => _colors = [accurate.vibrant, accurate.darkMuted]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors ??
        const [
          PlaylistColorCover._fallbackA,
          PlaylistColorCover._fallbackB,
        ];
    // FIX (recheck pass): PlaylistDetailScreen's full-width header calls
    // this with size: double.infinity — blurRadius/offset below were
    // derived directly from widget.size, so an infinite size produced an
    // infinite blurRadius (Flutter throws/paints garbage on that). Same
    // guard the width/height already used (widget.size.isFinite),
    // applied to the shadow's math too, with a fixed sensible blur for
    // the infinite-size header case instead of trying to scale off a
    // size that isn't a real number.
    final hasFiniteSize = widget.size.isFinite;
    final shadowBlur = hasFiniteSize ? widget.size * 0.18 : 24.0;
    final shadowOffsetY = hasFiniteSize ? widget.size * 0.06 : 8.0;
    return AnimatedContainer(
      duration: AurumMotion.durationOrZero(AurumMotion.long1),
      curve: Curves.easeOutCubic,
      width: widget.size.isFinite ? widget.size : null,
      height: widget.size.isFinite ? widget.size : null,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        // Soft colored glow matching the extracted palette instead of a
        // flat generic shadow — makes each cover feel like it's actually
        // lit by its own gradient rather than sitting on a plain card.
        // Pure decoration math, no extra image work, so this costs
        // nothing on top of the AnimatedContainer that was already here.
        boxShadow: [
          BoxShadow(
            color: colors.first.withOpacity(0.35),
            blurRadius: shadowBlur,
            offset: Offset(0, shadowOffsetY),
          ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Faint diagonal sheen — a single translucent gradient overlay,
          // not a shader/image, so it's effectively free to paint and
          // never re-triggers any decode/extraction work.
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withOpacity(0.16),
                      Colors.white.withOpacity(0.0),
                      Colors.black.withOpacity(0.10),
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Icon(
            Icons.queue_music_rounded,
            color: Colors.white.withOpacity(0.92),
            size: widget.iconSize ?? widget.size * 0.4,
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: widget.size * 0.06,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
