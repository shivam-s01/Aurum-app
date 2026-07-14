import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/short_item.dart';
import '../providers/shorts_feed_controller.dart' show DownloadTrackState;

/// Vertical action rail on the right edge of each Shorts card —
/// Reels-style: heart, save, download, share, more, listen-full-song.
class ShortsActionRail extends StatelessWidget {
  final ShortItem item;
  final bool liked;
  final bool saved;
  final DownloadTrackState downloadState;
  final VoidCallback onLike;
  final VoidCallback onSave;
  final VoidCallback onDownload;
  final VoidCallback onShare;
  final VoidCallback onMore;
  final VoidCallback onListenFull;

  const ShortsActionRail({
    super.key,
    required this.item,
    required this.liked,
    required this.saved,
    required this.downloadState,
    required this.onLike,
    required this.onSave,
    required this.onDownload,
    required this.onShare,
    required this.onMore,
    required this.onListenFull,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LikeButton(liked: liked, onTap: onLike),
        const SizedBox(height: 22),
        _SaveButton(saved: saved, onTap: onSave),
        const SizedBox(height: 22),
        _DownloadButton(state: downloadState, onTap: onDownload),
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

/// Heart button with a real "pop" — overshoots past 1.0 then settles,
/// plus a quick color morph. Distinct feel from a plain icon swap.
class _LikeButton extends StatefulWidget {
  final bool liked;
  final VoidCallback onTap;
  const _LikeButton({required this.liked, required this.onTap});

  @override
  State<_LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<_LikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  late final Animation<double> _scale = TweenSequence([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 0.75)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20),
    TweenSequenceItem(
        tween: Tween(begin: 0.75, end: 1.28)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 45),
    TweenSequenceItem(
        tween: Tween(begin: 1.28, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 35),
  ]).animate(_ctrl);

  @override
  void didUpdateWidget(covariant _LikeButton old) {
    super.didUpdateWidget(old);
    if (widget.liked && !old.liked) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            widget.liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: ValueKey(widget.liked),
            color: widget.liked ? const Color(0xFFFF4D6D) : Colors.white,
            size: 30,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}

/// Save/bookmark button — fills in with a quick squash-and-stretch,
/// plus a small "Saved" toast-style flash the first time.
class _SaveButton extends StatefulWidget {
  final bool saved;
  final VoidCallback onTap;
  const _SaveButton({required this.saved, required this.onTap});

  @override
  State<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends State<_SaveButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );
  late final Animation<double> _scaleY = TweenSequence([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.3)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40),
    TweenSequenceItem(
        tween: Tween(begin: 1.3, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 60),
  ]).animate(_ctrl);

  @override
  void didUpdateWidget(covariant _SaveButton old) {
    super.didUpdateWidget(old);
    if (widget.saved && !old.saved) {
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedBuilder(
        animation: _scaleY,
        builder: (context, child) => Transform.scale(
          scaleY: _scaleY.value,
          alignment: Alignment.bottomCenter,
          child: child,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            widget.saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            key: ValueKey(widget.saved),
            color: widget.saved ? AurumTheme.gold : Colors.white,
            size: 30,
            shadows: const [Shadow(color: Colors.black45, blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}

/// Download button with 3 real states: idle (outline), downloading
/// (spinner ring — an honest progress indicator, not a fake instant
/// success), done (filled check). Tapping mid-download does nothing
/// (avoids double-triggering a resolve+download).
class _DownloadButton extends StatelessWidget {
  final DownloadTrackState state;
  final VoidCallback onTap;
  const _DownloadButton({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: state == DownloadTrackState.downloading
          ? null
          : () {
              HapticFeedback.selectionClick();
              onTap();
            },
      child: SizedBox(
        width: 30,
        height: 30,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: switch (state) {
            DownloadTrackState.idle => const Icon(
                Icons.download_rounded,
                key: ValueKey('idle'),
                color: Colors.white,
                size: 28,
                shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
              ),
            DownloadTrackState.downloading => const SizedBox(
                key: ValueKey('downloading'),
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  valueColor: AlwaysStoppedAnimation(AurumTheme.gold),
                ),
              ),
            DownloadTrackState.done => const Icon(
                Icons.download_done_rounded,
                key: ValueKey('done'),
                color: AurumTheme.gold,
                size: 28,
                shadows: [Shadow(color: Colors.black45, blurRadius: 6)],
              ),
          },
        ),
      ),
    );
  }
}
