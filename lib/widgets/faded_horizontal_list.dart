import 'package:flutter/material.dart';

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
    // FIX ("Top Hits" / any short row — last card reads as cut-off/hazy
    // behind a permanent right-edge fade): maxScrollExtent is 0 whenever
    // the row's content is short enough to fit on screen without any
    // scrolling at all (few items, or a narrow screen with room to
    // spare). Previously `atEnd` only compared offset to maxScrollExtent
    // — with maxScrollExtent already at 0, offset (also 0) trivially
    // satisfied "at end", so this SHOULD have suppressed the fade... but
    // right after the very first layout pass, ListView's Sliver hasn't
    // always reported a final maxScrollExtent yet on the postFrameCallback
    // this fires from (particularly once real network images swap in for
    // placeholders and cards resize), leaving a stale 0 vs a genuinely
    // non-zero extent for one extra frame — during that window `atEnd`
    // could read true==true by coincidence but the NEXT layout pass
    // (once images load and the row's true width is known) could recompute
    // a small positive maxScrollExtent, flipping the fade back on for a
    // row that still visually has nothing left to scroll to (last card
    // fully on-screen with a little padding after it) — exactly the
    // "Top Hits" card reading as permanently faded/cut at the edge.
    // Fix: treat any maxScrollExtent below a small px threshold as "no
    // real scrolling possible here", not just exactly 0 — this absorbs
    // that late-layout jitter and keeps the fade off for rows that are
    // functionally non-scrollable, matching Spotify/Echo (no edge cue at
    // all on a row that already shows everything it has).
    const noScrollThreshold = 4.0;
    final hasRoomToScroll =
        c.position.maxScrollExtent > noScrollThreshold;
    final atStart = c.offset <= c.position.minScrollExtent + 0.5;
    final atEnd = !hasRoomToScroll ||
        c.offset >= c.position.maxScrollExtent - 0.5;
    final newLeft = widget.fadeLeft && hasRoomToScroll && !atStart;
    final newRight = hasRoomToScroll && !atEnd;
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
    // FIX ("foggy"/hazy edges on every horizontal carousel — user wants a
    // flat, clean look like JioSaavn/SimpMusic instead): the scroll-aware
    // logic above was working as designed, but the fade cue itself reads
    // as an unwanted haze rather than a helpful "more to scroll" hint.
    // Short-circuit here to just render the child untouched — no Stack,
    // no gradient overlay, on either edge, ever. Left the state-tracking
    // above intact (harmless — it just no longer affects what's drawn)
    // so this is a one-line revert if a fade is ever wanted again later.
    return SizedBox(height: widget.height, child: widget.child);
  }
}
