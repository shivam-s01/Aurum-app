import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FadedHorizontalList — wraps any horizontally-scrolling row (song cards,
// artist chips, playlist cards) with a soft edge fade, matching the
// background color, so a card sitting mid-scroll at the screen boundary
// reads as an intentional "peek, scroll for more" cue instead of a hard
// cut straight through the artwork.
//
// FIX (looked like a solid white/dark block instead of a subtle cue): the
// original version showed BOTH edge fades unconditionally, all the time —
// including the left fade on a row that was still scrolled to its very
// start, where there's nothing behind it to hint at. A background-colored
// gradient with no scrollable content on the other side doesn't read as
// "more content this way", it just reads as a flat, out-of-place colored
// stripe sitting on top of the first card — which is exactly the "white
// white" / "black black" patch look. Real apps (Spotify included) only
// show an edge fade once there's actually somewhere left to scroll.
// Fix: track scroll position and only paint each fade when the list is
// actually scrolled away from that edge.
//
// Previously this exact trick (ShaderMask/gradient-over-background) only
// existed on Search screen's artist/album rows (_FadedHorizontalList,
// private to search_screen.dart). Pulled it out to lib/widgets/ so both
// screens (and any future ones) share one implementation.
// ─────────────────────────────────────────────────────────────────────────────
class FadedHorizontalList extends StatefulWidget {
  final Widget child;
  final double height;

  /// Width of the fade zone on each edge. 20px matches the original
  /// Search-screen implementation; kept configurable since some rows
  /// (e.g. the artist circle chips) may want a narrower fade so it
  /// doesn't eat into a small 64px avatar.
  final double fadeWidth;

  /// Set false to permanently skip the left-edge fade regardless of
  /// scroll position — rare; most rows want the automatic scroll-aware
  /// behavior instead of an outright disable.
  final bool fadeLeft;

  /// The ScrollController used by [child]'s scroll view. Required for the
  /// fade to be scroll-position-aware; if not supplied, both fades fall
  /// back to always-visible (the old behavior) since there's no way to
  /// know the current scroll offset.
  final ScrollController? controller;

  const FadedHorizontalList({
    super.key,
    required this.child,
    required this.height,
    this.fadeWidth = 20,
    this.fadeLeft = true,
    this.controller,
  });

  @override
  State<FadedHorizontalList> createState() => _FadedHorizontalListState();
}

class _FadedHorizontalListState extends State<FadedHorizontalList> {
  bool _showLeft = false;
  bool _showRight = false;
  ScrollController? _ownedController;

  ScrollController get _controller =>
      widget.controller ?? (_ownedController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    // No controller supplied: fall back to the simple always-on fade
    // (previous behavior) rather than silently doing nothing, since we
    // can't observe scroll position on a controller we don't own unless
    // we attach our own — which only works if `child`'s scroll view
    // doesn't already have its own separate controller. Safest default
    // when unspecified is "always show", matching the pre-fix look for
    // any call site that hasn't been updated to pass one yet.
    if (widget.controller != null) {
      widget.controller!.addListener(_onScroll);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    } else {
      _showLeft = widget.fadeLeft;
      _showRight = true;
    }
  }

  void _onScroll() {
    if (!mounted) return;
    final c = widget.controller!;
    if (!c.hasClients) return;
    final atStart = c.offset <= c.position.minScrollExtent + 0.5;
    final atEnd = c.offset >= c.position.maxScrollExtent - 0.5;
    final newLeft = widget.fadeLeft && !atStart;
    final newRight = !atEnd;
    if (newLeft != _showLeft || newRight != _showRight) {
      setState(() {
        _showLeft = newLeft;
        _showRight = newRight;
      });
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onScroll);
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = AurumTheme.bgOf(context);
    return SizedBox(
      height: widget.height,
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_showLeft)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: widget.fadeWidth,
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
          if (_showRight)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: widget.fadeWidth,
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
