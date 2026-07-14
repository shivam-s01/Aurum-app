import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart' as prov;
import '../../models/song.dart' as aurum;
import '../../providers/download_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/api_service.dart';
import '../models/short_item.dart';
import '../providers/shorts_feed_controller.dart';
import '../widgets/shorts_action_rail.dart';
import '../widgets/shorts_info_overlay.dart';
import '../widgets/shorts_visual_card.dart';
import 'shorts_preferences_screen.dart';

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
  ShortsFeedController _controller = ShortsFeedController();
  PageController _pageController = PageController();
  bool _showHeart = false;
  bool _resolvingFullSong = false;
  // Bumped on every preferences-driven restart. Used as a Widget key
  // for the PageView so Flutter treats the post-restart feed as a
  // brand-new widget instance rather than reusing internal scroll
  // state tied to the previous PageController/controller pairing —
  // that stale reuse was part of what made refresh feel "stuck".
  int _feedGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Rebuilds the feed from scratch with a brand-new controller —
  /// used after the user changes their language/category preferences
  /// in ShortsPreferencesScreen. The old controller (and its player,
  /// shown-item history) is fully disposed so nothing from the old
  /// preference set leaks into the new feed.
  Future<void> _restartFeedWithNewPreferences() async {
    final oldController = _controller;
    final oldPageController = _pageController;
    final fresh = ShortsFeedController();

    // Swap in a brand-new PageController + bump the generation key
    // together with the new feed controller. Reusing the old
    // PageController across a full feed replacement was fragile —
    // it could retain a page/offset from the previous feed that no
    // longer made sense once the new (usually shorter, freshly
    // fetched) item list swapped in, effectively hanging the view.
    setState(() {
      _controller = fresh;
      _pageController = PageController();
      _feedGeneration++;
    });

    // Let init() fully populate items BEFORE touching the
    // PageController. Calling jumpToPage(0) while the new
    // controller's item list is still empty was the root cause of
    // the "refresh gets stuck" bug — PageView has nothing to jump
    // to yet, so the page silently fails to reset and the UI hangs
    // showing the loading spinner indefinitely.
    await fresh.init();

    if (!mounted) {
      oldController.dispose();
      oldPageController.dispose();
      return;
    }

    oldController.dispose();
    oldPageController.dispose();
  }

  /// Warms the image cache for the next couple of cards so swiping
  /// forward never shows a blank/loading flash while the artwork
  /// decodes — this is what makes the feed feel instant rather than
  /// merely "not broken".
  void _precacheUpcomingArtwork(ShortsFeedController ctrl, int currentIndex) {
    final upcoming = ctrl.items.skip(currentIndex + 1).take(2);
    for (final item in upcoming) {
      if (item.artworkUrl.isEmpty) continue;
      precacheImage(
        CachedNetworkImageProvider(item.artworkUrl),
        context,
      ).catchError((_) {});
    }
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

  /// Resolves a ShortItem (30s preview) to a real, fully-streamable
  /// Song via the existing Saavn search pipeline — shared by both
  /// "Listen Full Song" and "Download".
  Future<aurum.Song> _resolveFullSong(ShortItem item) async {
    final query = '${item.artist} ${item.title}';
    final results = await ApiService.quickSearch(query, limit: 5);
    if (results.isNotEmpty) return results.first;
    // Fallback: minimal Song from the preview itself.
    return aurum.Song(
      id: item.id,
      title: item.title,
      artist: item.artist,
      album: item.album,
      artworkUrl: item.artworkUrl,
      streamUrl: item.previewUrl,
      duration: (item.durationMs / 1000).round(),
    );
  }

  Future<void> _onListenFull(ShortItem item) async {
    if (_resolvingFullSong) return;
    setState(() => _resolvingFullSong = true);
    _controller.togglePlayPause(); // pause the preview

    try {
      final songToPlay = await _resolveFullSong(item);

      if (!mounted) return;
      final player = prov.Provider.of<PlayerProvider>(context, listen: false);
      await player.playSong(songToPlay);

      if (!mounted) return;
      Navigator.of(context).pop(); // exit Shorts back to wherever it was opened from
    } finally {
      if (mounted) setState(() => _resolvingFullSong = false);
    }
  }

  Future<void> _onDownload(ShortItem item) async {
    if (_controller.downloadState != DownloadTrackState.idle) return;
    _controller.setDownloadState(DownloadTrackState.downloading);
    HapticFeedback.mediumImpact();

    try {
      final song = await _resolveFullSong(item);
      if (!mounted) return;
      final downloads =
          prov.Provider.of<DownloadProvider>(context, listen: false);
      final ok = await downloads.download(song);

      if (!mounted) return;
      if (ok) {
        _controller.setDownloadState(DownloadTrackState.done);
      } else {
        _controller.setDownloadState(DownloadTrackState.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download failed — check connection / Wi-Fi setting'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        _controller.setDownloadState(DownloadTrackState.idle);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t download this song'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _precacheUpcomingArtwork(ctrl, ctrl.currentIndex);
            });

            return Stack(
              children: [
                PageView.builder(
                  key: ValueKey(_feedGeneration),
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  // Premium/Reels-style feel: a slightly "heavier" page
                  // physics than the default so a swipe always resolves
                  // cleanly to the next/previous page rather than
                  // sometimes landing in a half-scrolled state — that
                  // half-scrolled rebound is what reads as "janky"
                  // rather than smooth, even when frame rate itself is
                  // fine.
                  physics: const PageScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  pageSnapping: true,
                  itemCount: ctrl.items.length,
                  onPageChanged: (index) {
                    final movingForward = index > ctrl.currentIndex;
                    if (movingForward) {
                      ctrl.registerSkip();
                    }
                    // Deferred to the next frame so the page-change
                    // callback (which fires WHILE the swipe animation
                    // is still settling) never triggers a
                    // notifyListeners()-driven rebuild in the same
                    // frame as the scroll animation — that overlap was
                    // the main source of visible stutter on swipe.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) ctrl.jumpTo(index);
                    });
                    _precacheUpcomingArtwork(ctrl, index);
                  },
                  itemBuilder: (context, index) {
                    final item = ctrl.items[index];
                    final isCurrent = index == ctrl.currentIndex;

                    return RepaintBoundary(
                      child: GestureDetector(
                      onDoubleTap: _onDoubleTap,
                      onTap: () => ctrl.togglePlayPause(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ShortsVisualCard(
                            artworkUrl: item.artworkUrl,
                            isActive: isCurrent,
                            videoController:
                                isCurrent ? ctrl.videoController : null,
                          ),
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
                              saved: isCurrent ? ctrl.isSaved : false,
                              downloadState: isCurrent
                                  ? ctrl.downloadState
                                  : DownloadTrackState.idle,
                              onLike: () => ctrl.toggleLike(),
                              onSave: () async {
                                await ctrl.toggleSave();
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                        ctrl.isSaved ? 'Saved' : 'Removed'),
                                    duration: const Duration(seconds: 1),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                              onDownload: () => _onDownload(item),
                              onShare: () {
                                HapticFeedback.selectionClick();
                              },
                              onMore: () async {
                                HapticFeedback.selectionClick();
                                ctrl.togglePlayPause(); // pause while editing prefs
                                final changed = await Navigator.of(context)
                                    .push<bool>(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        const ShortsPreferencesScreen(),
                                    fullscreenDialog: true,
                                  ),
                                );
                                if (changed == true && mounted) {
                                  await _restartFeedWithNewPreferences();
                                } else {
                                  ctrl.togglePlayPause(); // resume
                                }
                              },
                              onListenFull: () => _onListenFull(item),
                            ),
                          ),
                        ],
                      ),
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
