// aurum_like_button.dart
// Aurum Music — Premium Like/Heart Button
//
// Single source of truth for the "like a song" interaction across the app
// (song rows, full player). Replaces the plain ScaleTransition icon-swap
// that was duplicated ad hoc in song_tile.dart and full_player_screen.dart
// with one deliberate, higher-fidelity animation:
//
//   LIKE   — heart pops with a spring overshoot (1.0 -> 1.32 -> 1.0) and a
//            small burst of 6 sparkle particles flick outward and fade.
//            Medium haptic tick, matching the weight of "saving something".
//   UNLIKE — heart shrinks slightly and gives one quick side-to-side wobble
//            as it fades to the outline — reads as "letting go" without
//            reaching for a literal cracked-heart glyph (which tends to
//            look cheap/cartoonish at 18-24px icon sizes).
//
// Deliberately built with only AnimationController + CustomPainter — no
// new package, no image assets, no continuous ticking (the controller is
// idle at rest, matching the app's existing perf/battery constraints).
//
// Usage:
//   AurumLikeButton(
//     isLiked: isLiked,
//     onTap: () => fav.toggleFavorite(song),
//     size: 18,
//   )

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AurumLikeButton extends StatefulWidget {
  const AurumLikeButton({
    super.key,
    required this.isLiked,
    required this.onTap,
    this.size = 20,
    this.likedColor = const Color(0xFFE1306C),
    this.unlikedColor,
    this.haptic = true,
  });

  final bool isLiked;
  final VoidCallback onTap;
  final double size;
  final Color likedColor;

  /// Color when not liked. Defaults to a muted grey if not supplied.
  final Color? unlikedColor;

  final bool haptic;

  @override
  State<AurumLikeButton> createState() => _AurumLikeButtonState();
}

class _AurumLikeButtonState extends State<AurumLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  // Fixed random burst directions/speeds — computed once, reused every
  // like, so there's no per-frame allocation beyond the paint call itself.
  static final List<_Sparkle> _sparkles = List.generate(6, (i) {
    final angle = (i / 6) * math.pi * 2 + 0.35; // offset so none point straight up/down
    return _Sparkle(angle: angle, distance: 0.85 + (i.isEven ? 0.15 : 0.0));
  });

  bool _wasLiked = false;

  @override
  void initState() {
    super.initState();
    _wasLiked = widget.isLiked;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
  }

  @override
  void didUpdateWidget(covariant AurumLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLiked != _wasLiked) {
      _wasLiked = widget.isLiked;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (widget.haptic) {
      // Slightly heavier tick for "like" (adding something) than
      // "unlike" (removing) — small detail, reads as more intentional.
      widget.isLiked
          ? HapticFeedback.selectionClick()
          : HapticFeedback.mediumImpact();
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final unlikedColor = widget.unlikedColor ?? Colors.grey.withAlpha(150);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: SizedBox(
        // Give the sparkle burst room to breathe outside the icon's own
        // bounds without affecting row layout (the extra space is
        // transparent and hit-tests as part of the tap target, which
        // also nicely enlarges the touch target for a small icon).
        width: widget.size * 2.2,
        height: widget.size * 2.2,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = _ctrl.value;
            final liked = widget.isLiked;

            // ---- Heart scale/wobble curve ----
            double scale;
            double wobble = 0;
            if (liked) {
              // 0 -> 0.35: shoot up to 1.32x (easeOutBack-ish overshoot)
              // 0.35 -> 1.0: settle back to 1.0 (easeOutCubic)
              if (t < 0.35) {
                final p = t / 0.35;
                scale = 1.0 + (0.32 * Curves.easeOutBack.transform(p));
              } else {
                final p = (t - 0.35) / 0.65;
                scale = 1.32 - (0.32 * Curves.easeOutCubic.transform(p));
              }
            } else {
              // Quick shrink to 0.82x then spring back to 1.0, with a
              // fast horizontal wobble layered on top during the dip —
              // the "letting go" flinch.
              if (t < 0.25) {
                final p = t / 0.25;
                scale = 1.0 - (0.18 * Curves.easeOut.transform(p));
              } else {
                final p = ((t - 0.25) / 0.75).clamp(0.0, 1.0);
                scale = 0.82 + (0.18 * Curves.easeOutCubic.transform(p));
              }
              if (t < 0.4) {
                wobble = math.sin(t * math.pi * 6) * (1 - t / 0.4) * 3;
              }
            }

            return Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Sparkle burst — only painted (and only costs anything)
                // during the first ~55% of the like animation; fully
                // transparent/no-op the rest of the time, including at
                // rest, so this widget is free when idle.
                if (liked && t < 0.55)
                  CustomPaint(
                    size: Size(widget.size * 2.2, widget.size * 2.2),
                    painter: _SparklePainter(
                      progress: (t / 0.55).clamp(0.0, 1.0),
                      color: widget.likedColor,
                      sparkles: _sparkles,
                    ),
                  ),
                Transform.translate(
                  offset: Offset(wobble, 0),
                  child: Transform.scale(
                    scale: scale,
                    child: Icon(
                      liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      color: liked ? widget.likedColor : unlikedColor,
                      size: widget.size,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Sparkle {
  final double angle;
  final double distance; // multiplier on the base travel distance
  const _Sparkle({required this.angle, required this.distance});
}

class _SparklePainter extends CustomPainter {
  final double progress; // 0..1
  final Color color;
  final List<_Sparkle> sparkles;

  _SparklePainter({
    required this.progress,
    required this.color,
    required this.sparkles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxTravel = size.width * 0.32;
    // Ease-out travel, fade in the back half.
    final travel = Curves.easeOutCubic.transform(progress) * maxTravel;
    final opacity = (1.0 - progress).clamp(0.0, 1.0);
    if (opacity <= 0) return;

    final paint = Paint()..color = color.withOpacity(opacity * 0.9);
    for (final s in sparkles) {
      final dx = math.cos(s.angle) * travel * s.distance;
      final dy = math.sin(s.angle) * travel * s.distance;
      final radius = 1.6 * (1.0 - progress * 0.4);
      canvas.drawCircle(center + Offset(dx, dy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_SparklePainter old) =>
      old.progress != progress || old.color != color;
}
