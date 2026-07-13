import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/short_item.dart';

/// Vertical action rail on the right edge of each Shorts card —
/// Reels-style: heart, save, share, more, listen-full-song.
class ShortsActionRail extends StatelessWidget {
  final ShortItem item;
  final bool liked;
  final VoidCallback onLike;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onMore;
  final VoidCallback onListenFull;

  const ShortsActionRail({
    super.key,
    required this.item,
    required this.liked,
    required this.onLike,
    required this.onSave,
    required this.onShare,
    required this.onMore,
    required this.onListenFull,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: liked ? const Color(0xFFFF4D6D) : Colors.white,
          onTap: onLike,
          animateScale: liked,
        ),
        const SizedBox(height: 22),
        _RailButton(
          icon: Icons.bookmark_border_rounded,
          color: Colors.white,
          onTap: onSave,
        ),
        const SizedBox(height: 22),
        _RailButton(
          icon: Icons.share_outlined,
          color: Colors.white,
          onTap: onShare,
        ),
        const SizedBox(height: 22),
        _RailButton(
          icon: Icons.more_horiz_rounded,
          color: Colors.white,
          onTap: onMore,
        ),
        const SizedBox(height: 26),
        GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            onListenFull();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: AurumTheme.goldGradient,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.queue_music_rounded,
              color: Colors.black,
              size: 22,
            ),
          ),
        ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool animateScale;

  const _RailButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.animateScale = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedScale(
        scale: animateScale ? 1.12 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: Icon(icon, color: color, size: 30, shadows: const [
          Shadow(color: Colors.black45, blurRadius: 6),
        ]),
      ),
    );
  }
}
