import 'package:flutter/material.dart';
import '../services/audio_prefs.dart';
import '../utils/aurum_motion.dart';

// ─────────────────────────────────────────────────────────────────────────
// AurumScrollFadeIn — wraps a single list/grid item (a song tile, card,
// chip, whatever) so it fades + rises in the FIRST time it becomes visible
// on screen, then never re-animates for that item again.
//
// WHY VisibilityDetector-free / IntersectionObserver-free:
// Aurum doesn't currently depend on the `visibility_detector` package, and
// pulling in a new native plugin just for this is unnecessary weight for a
// purely cosmetic effect. Instead this piggybacks on the fact that list
// items are already built lazily by ListView.builder/GridView.builder as
// they scroll into the viewport — so "item entered build()" IS "item just
// became visible" for a lazily-built list. A one-shot AnimationController
// on initState, no scroll-position math, no listeners on the scroll
// controller itself. Cheap: one controller per currently-built item,
// disposed the instant that item is scrolled far enough to be rebuilt off
// the list (standard Flutter element lifecycle), same footprint class as
// any other item-level entrance animation already in the app.
//
// GATING (respects both toggles, matching every other animation in Aurum):
// • Master "Enable Animations" off → AurumMotion.enabled is false →
//   this renders the child immediately at full opacity, no controller
//   even created.
// • "Scroll Animations" off (independent of the master toggle, same
//   pattern as Back Animations / Background Gradient Animation) → same
//   immediate full-opacity render, no controller.
// • Battery Saver → already folds into AurumMotion.enabled, so it's
//   covered for free.
//
// USAGE:
//   itemBuilder: (_, i) => AurumScrollFadeIn(
//     index: i,
//     child: SongTile(song: songs[i]),
//   ),
// ─────────────────────────────────────────────────────────────────────────
class AurumScrollFadeIn extends StatefulWidget {
  const AurumScrollFadeIn({
    super.key,
    required this.child,
    this.index = 0,
  });

  final Widget child;

  /// Item's position within its list/grid. Used only to stagger the start
  /// of each item's own fade by a few ms so a first-load screen doesn't
  /// have every visible row popping in on the exact same frame — capped
  /// low and clamped to a small max item count so a long list's later
  /// items don't end up with a silly multi-second delay.
  final int index;

  @override
  State<AurumScrollFadeIn> createState() => _AurumScrollFadeInState();
}

class _AurumScrollFadeInState extends State<AurumScrollFadeIn>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _fade;
  Animation<Offset>? _slide;

  bool get _shouldAnimate =>
      AurumMotion.enabled && AudioPrefs.scrollAnimations;

  @override
  void initState() {
    super.initState();
    if (!_shouldAnimate) return;

    _controller = AnimationController(
      vsync: this,
      duration: AurumMotion.medium2,
    );
    final curved = CurvedAnimation(
      parent: _controller!,
      curve: AurumMotion.standard,
    );
    _fade = curved;
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(curved);

    // Small, capped stagger — index 0..8 get a slight ripple-in, beyond
    // that everything starts together rather than queuing up a visible
    // "waterfall" delay on long lists.
    final delayMs = (widget.index.clamp(0, 8)) * 25;
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _controller?.forward();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldAnimate || _controller == null) return widget.child;
    return FadeTransition(
      opacity: _fade!,
      child: SlideTransition(
        position: _slide!,
        child: widget.child,
      ),
    );
  }
}
