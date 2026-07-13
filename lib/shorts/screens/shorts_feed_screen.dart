import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart' as prov;
import '../../models/song.dart' as aurum;
import '../../providers/player_provider.dart';
import '../../services/api_service.dart';
import '../models/short_item.dart';
import '../providers/shorts_feed_controller.dart';
import '../widgets/shorts_action_rail.dart';
import '../widgets/shorts_info_overlay.dart';

/// Full-screen vertical Shorts feed. Reels-style swipe navigation.
/// Runs its own ShortsFeedController + its own just_audio instance —
/// never touches the main Aurum queue, history, or native engine.
/// Only "Listen Full Song" crosses the boundary, and only by handing
/// off song identity (title/artist/artwork) to the real player.
class ShortsFeedScreen extends StatefulWidget {
  const ShortsFeedScreen({super.key});

  @override
  State<ShortsFeedScreen> createState() => _ShortsFeedScreenState();
}

class _ShortsFeedScreenState extends State<ShortsFeedScreen> {
  late final ShortsFeedController _controller;
  late final PageController _pageController;
  bool _showHeart = false;
  bool _resolvingFullSong = false;

  @override
  void initState() {
    super.initState();
    _controller = ShortsFeedController();
    _pageController = PageController();
    _controller.init();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _flashHeart() {
    setState(() => _showHeart = true);
    Future.delayed(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _showHeart = false);
    });
  }

  Future<void> _onDoubleTap() async {
    HapticFeedback.mediumImpact();
    if (!_controller.isLiked) {
      await _controller.toggleLike();
    }
    _flashHeart();
  }

  Future<void> _onListenFull(ShortItem item) async {
    if (_resolvingFullSong) return;
    setState(() => _resolvingFullSong = true);
    _controller.togglePlayPause(); // pause the preview

    try {
      final query = '${item.artist} ${item.title}';
      final results = await ApiService.quickSearch(query, limit: 5);

      aurum.Song songToPlay;
      if (results.isNotEmpty) {
        songToPlay = results.first;
      } else {
        // Fallback: build a minimal Song from the preview itself so
        // the user still gets *something* playing instead of an
        // error, even though it's only 30s.
        songToPlay = aurum.Song(
          id: item.id,
          title: item.title,
          artist: item.artist,
          album: item.album,
          artworkUrl: item.artworkUrl,
          streamUrl: item.previewUrl,
          duration: (item.durationMs / 1000).round(),
        );
      }

      if (!mounted) return;
      final player = prov.Provider.of<PlayerProvider>(context, listen: false);
      await player.playSong(songToPlay);

      if (!mounted) return;
      Navigator.of(context).pop(); // exit Shorts back to wherever it was opened from
    } finally {
      if (mounted) setState(() => _resolvingFullSong = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return prov.ChangeNotifierProvider.value(
      value: _controller,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: prov.Consumer<ShortsFeedController>(
          builder: (context, ctrl, _) {
            if (ctrl.initialLoading) {
              return const Center(
                child: CircularProgressIndicator(color: Colors.white54),
              );
            }
            if (ctrl.items.isEmpty) {
              return _EmptyFeedState(onRetry: () => ctrl.init());
            }

            return Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  itemCount: ctrl.items.length,
                  onPageChanged: (index) {
                    final movingForward = index > ctrl.currentIndex;
                    if (movingForward) {
                      ctrl.registerSkip();
                    }
                    ctrl.jumpTo(index);
                  },
                  itemBuilder: (context, index) {
                    final item = ctrl.items[index];
                    final isCurrent = index == ctrl.currentIndex;

                    return GestureDetector(
                      onDoubleTap: _onDoubleTap,
                      onTap: () => ctrl.togglePlayPause(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: item.artworkUrl,
                            fit: BoxFit.cover,
                            fadeInDuration: const Duration(milliseconds: 200),
                            placeholder: (_, __) =>
                                Container(color: const Color(0xFF0A0A0A)),
                            errorWidget: (_, __, ___) => Container(
                              color: const Color(0xFF0A0A0A),
                              child: const Icon(Icons.music_note,
                                  color: Colors.white24, size: 48),
                            ),
                          ),
                          Container(color: Colors.black.withOpacity(0.28)),
                          if (isCurrent && _showHeart)
                            const Center(
                              child: _LikeBurst(),
                            ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: ShortsInfoOverlay(
                              item: item,
                              position: isCurrent
                                  ? ctrl.position
                                  : Duration.zero,
                              duration: isCurrent
                                  ? ctrl.duration
                                  : Duration(milliseconds: item.durationMs),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 130,
                            child: ShortsActionRail(
                              item: item,
                              liked: isCurrent ? ctrl.isLiked : false,
                              onLike: () => ctrl.toggleLike(),
                              onSave: () {
                                HapticFeedback.selectionClick();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Saved'),
                                    duration: Duration(seconds: 1),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                              onShare: () {
                                HapticFeedback.selectionClick();
                              },
                              onMore: () {
                                HapticFeedback.selectionClick();
                              },
                              onListenFull: () => _onListenFull(item),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: SafeArea(
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white, size: 26),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
                if (_resolvingFullSong)
                  Container(
                    color: Colors.black54,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
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

class _LikeBurst extends StatefulWidget {
  const _LikeBurst();

  @override
  State<_LikeBurst> createState() => _LikeBurstState();
}

class _LikeBurstState extends State<_LikeBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    )..forward();
    _scale = TweenSequence([
      TweenSequenceItem(
          tween: Tween(begin: 0.4, end: 1.15)
              .chain(CurveTween(curve: Curves.easeOutBack)),
          weight: 55),
      TweenSequenceItem(
          tween: Tween(begin: 1.15, end: 1.0), weight: 45),
    ]).animate(_anim);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: const Icon(
        Icons.favorite_rounded,
        color: Color(0xFFFF4D6D),
        size: 100,
        shadows: [Shadow(color: Colors.black45, blurRadius: 16)],
      ),
    );
  }
}

class _EmptyFeedState extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyFeedState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white38, size: 40),
          const SizedBox(height: 16),
          const Text(
            'Couldn\'t load your feed',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
