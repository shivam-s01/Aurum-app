import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FadedHorizontalList — wraps any horizontally-scrolling row (song cards,
// artist chips, playlist cards) with a soft edge fade on both sides,
// matching the background color, so a card sitting mid-scroll at the
// screen boundary reads as an intentional "peek, scroll for more" cue
// instead of a hard, awkward cut straight through the artwork.
//
// Previously this exact trick (ShaderMask/gradient-over-background) only
// existed on Search screen's artist/album rows (_FadedHorizontalList,
// private to search_screen.dart). Home screen's own carousels (dynamic
// mix sections, popular artists, trending playlists) had no such
// treatment — their last/first visible card was a bare, unstyled cut
// against the screen edge, which is what read as "content cut off" even
// though the underlying scroll/padding math was already correct. Pulled
// the widget out to lib/widgets/ so both screens (and any future ones)
// share one implementation instead of duplicating it.
//
// Purely decorative + IgnorePointer'd — adds no gesture/hit-test
// interference with the scroll view underneath, and is cheap: two static
// DecoratedBox gradients, no AnimatedBuilder, no per-frame cost.
// ─────────────────────────────────────────────────────────────────────────────
class FadedHorizontalList extends StatelessWidget {
  final Widget child;
  final double height;

  /// Width of the fade zone on each edge. 20px matches the original
  /// Search-screen implementation; kept configurable since some rows
  /// (e.g. the artist circle chips) may want a narrower fade so it
  /// doesn't eat into a small 64px avatar.
  final double fadeWidth;

  /// Set false to skip the left-edge fade — useful for a row that's
  /// always scrolled to its start with nothing to hint at on that side
  /// (rare; most rows want both edges faded since the user can scroll
  /// back after swiping forward).
  final bool fadeLeft;

  const FadedHorizontalList({
    super.key,
    required this.child,
    required this.height,
    this.fadeWidth = 20,
    this.fadeLeft = true,
  });

  @override
  Widget build(BuildContext context) {
    final bg = AurumTheme.bgOf(context);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (fadeLeft)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: fadeWidth,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [bg, bg.withOpacity(0.0)],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: fadeWidth,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [bg, bg.withOpacity(0.0)],
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
