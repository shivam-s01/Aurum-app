// ─────────────────────────────────────────────────────────────────────────────
// SpotifyFullPlayerScreen
//
// A second, alternate full-player screen matching the reference screenshots:
//   • Collapsing header: chevron-down, "NOW PLAYING" + song title subtitle,
//     overflow menu — collapses into a compact sticky row (small artwork +
//     title/artist + like + overflow) once the content below is scrolled
//     up, like Spotify's now-playing screen.
//   • Big square artwork, title/artist + like button, seekbar, shuffle /
//     prev / play-pause / next / repeat row.
//   • A row of three flat icon buttons: song info, add to queue, open queue.
//   • Below the fold (scrollable): a "Lyrics" preview card that opens the
//     app's own existing AurumLyricsPage (full synced lyrics experience,
//     reused as-is) in a full-screen route, an "Artists" card, and a
//     "Description" credits card.
//
// This is intentionally a NEW file — full_player_screen.dart and
// edge_to_edge_full_player.dart are untouched. Wire this up wherever you
// want to switch to it (e.g. swap the route in home_screen.dart / mini_player
// tap handler), it reads/writes the same PlayerProvider so switching between
// screens keeps playback state intact.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../models/artist.dart' show Artist;
import '../models/song.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_seek_bar.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/aurum_play_pause_icon.dart';
import '../utils/aurum_haptics.dart';
import '../services/api_service.dart';
import '../utils/aurum_transitions.dart' show AurumDepthRoute;
import 'artist_screen.dart';
import 'queue_screen.dart';
// Reuses the app's own existing lyrics widget (full fetch/sync/scroll/
// highlight behavior, already premium and battle-tested) and the existing
// song-info bottom sheet, instead of re-implementing either.
import 'full_player_screen.dart' show AurumLyricsPage, showSongInfoDialog;

// ─────────────────────────────────────────────────────────────────────────────
// Shared "more" action sheet — used by both the expanded and collapsed
// header's overflow button. Was previously wired to onPressed: () {}
// (no-op), which is why tapping the ⋮ icon did nothing.
// ─────────────────────────────────────────────────────────────────────────────
void _showPlayerMoreSheet(
  BuildContext context, {
  required PlayerProvider player,
  required FavoritesProvider favorites,
  required Song song,
}) {
  AurumHaptics.light();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => _PlayerMoreSheet(
      song: song,
      isLiked: favorites.isFavorite(song.id),
      onToggleLike: () {
        AurumHaptics.light();
        favorites.toggleFavorite(song);
      },
      onSongInfo: () => showSongInfoDialog(context, song),
      onAddToQueue: () {
        AurumHaptics.light();
        player.addToQueue(song);
      },
      onOpenQueue: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const QueueScreen()),
        );
      },
    ),
  );
}

class _PlayerMoreSheet extends StatelessWidget {
  final Song song;
  final bool isLiked;
  final VoidCallback onToggleLike;
  final VoidCallback onSongInfo;
  final VoidCallback onAddToQueue;
  final VoidCallback onOpenQueue;

  const _PlayerMoreSheet({
    required this.song,
    required this.isLiked,
    required this.onToggleLike,
    required this.onSongInfo,
    required this.onAddToQueue,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: AurumArtwork(
                        url: song.artworkUrl, size: 46, borderRadius: 6),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            _SheetTile(
              icon: isLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              iconColor: isLiked ? const Color(0xFF1ED760) : Colors.white,
              label: isLiked ? 'Remove from Liked Songs' : 'Add to Liked Songs',
              onTap: () {
                Navigator.of(context).pop();
                onToggleLike();
              },
            ),
            _SheetTile(
              icon: Icons.playlist_add_rounded,
              label: 'Add to queue',
              onTap: () {
                Navigator.of(context).pop();
                onAddToQueue();
              },
            ),
            _SheetTile(
              icon: Icons.queue_music_rounded,
              label: 'View queue',
              onTap: () {
                Navigator.of(context).pop();
                onOpenQueue();
              },
            ),
            _SheetTile(
              icon: Icons.info_outline_rounded,
              label: 'Song info',
              onTap: () {
                Navigator.of(context).pop();
                onSongInfo();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    this.iconColor = Colors.white,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: 20),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SpotifyFullPlayerScreen extends StatefulWidget {
  const SpotifyFullPlayerScreen({super.key});

  @override
  State<SpotifyFullPlayerScreen> createState() =>
      _SpotifyFullPlayerScreenState();
}

class _SpotifyFullPlayerScreenState extends State<SpotifyFullPlayerScreen> {
  final ScrollController _scrollCtrl = ScrollController();
  // Drives the header collapse fade — a plain double kept in sync with
  // scroll offset via a listener, not a second AnimationController. Only
  // triggers a rebuild of the small header row, not the whole screen.
  double _collapseT = 0.0;

  static const double _collapseDistance = 120.0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    final t = (_scrollCtrl.offset / _collapseDistance).clamp(0.0, 1.0);
    if (t != _collapseT) setState(() => _collapseT = t);
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _openFullLyrics(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => const _LyricsPageWrapper(),
        transitionsBuilder: (_, animation, __, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  // Tracks the live vertical drag offset for the whole-screen swipe-down-
  // to-dismiss gesture (Spotify-style: drag from anywhere in the header/
  // hero area downward past a threshold, or with enough velocity, closes
  // the player; otherwise it springs back). Only active while collapseT
  // is ~0 (i.e. the scroll view itself is at the top) so it never fights
  // the SingleChildScrollView's own vertical drag when the user is
  // scrolling the lyrics/artists content.
  double _dragDy = 0.0;
  bool _dragging = false;

  static const double _dismissDistance = 140.0;
  static const double _dismissVelocity = 700.0;

  void _onVerticalDragStart(DragStartDetails details) {
    if (_collapseT > 0.02) return; // let the scroll view handle it instead
    setState(() => _dragging = true);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    setState(() {
      _dragDy = (_dragDy + details.delta.dy).clamp(0.0, 400.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    final shouldDismiss = _dragDy > _dismissDistance ||
        details.primaryVelocity != null &&
            details.primaryVelocity! > _dismissVelocity;
    if (shouldDismiss) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _dragging = false;
      _dragDy = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) {
          return const Scaffold(
            backgroundColor: Color(0xFF121212),
            body: SizedBox.shrink(),
          );
        }
        final favorites = context.watch<FavoritesProvider>();

        // Fade + shrink slightly as it's dragged down, like the reference
        // app's own now-playing sheet, so the gesture reads as physical
        // rather than the screen just silently ignoring the drag.
        final dragT = (_dragDy / 400.0).clamp(0.0, 1.0);
        final scale = 1.0 - (dragT * 0.06);
        final opacity = 1.0 - (dragT * 0.35);

        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Transform.translate(
              offset: Offset(0, _dragDy),
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topCenter,
                child: Opacity(
                  opacity: opacity,
                  child: Stack(
                    children: [
                      _BackgroundGlow(
                        artworkUrl:
                            AurumArtwork.upgradeForFullPlayer(song.artworkUrl),
                      ),
                      SafeArea(
                        bottom: false,
                        child: Column(
                          children: [
                            _CollapsingHeader(
                              collapseT: _collapseT,
                              song: song,
                              favorites: favorites,
                              onClose: () => Navigator.of(context).maybePop(),
                              onMore: () => _showPlayerMoreSheet(
                                context,
                                player: player,
                                favorites: favorites,
                                song: song,
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                controller: _scrollCtrl,
                                physics: const BouncingScrollPhysics(
                                  parent: AlwaysScrollableScrollPhysics(),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _NowPlayingHero(player: player, song: song),
                                    _ControlsBlock(player: player, song: song),
                                    _IconActionsRow(player: player, song: song),
                                    const SizedBox(height: 28),
                                    _LyricsPreviewCard(
                                      player: player,
                                      onOpenFullScreen: () =>
                                          _openFullLyrics(context),
                                    ),
                                    const SizedBox(height: 20),
                                    _ArtistsSection(song: song),
                                    _DescriptionCard(
                                      song: song,
                                      onMore: () => _openFullLyrics(context),
                                    ),
                                    const SizedBox(height: 40),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-screen lyrics route content — just the app's own AurumLyricsPage
// with a minimal top bar (back chevron only; AurumLyricsPage supplies its
// own scroll/highlight/glow chrome beneath it).
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPageWrapper extends StatelessWidget {
  const _LyricsPageWrapper();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 20, 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down_rounded,
                        color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Expanded(
                    child: Text(
                      'Lyrics',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Balances the leading chevron button's width so the
                  // title above stays visually centered instead of
                  // drifting left, matching the reference screenshots'
                  // centered "Lyrics" bar.
                  const SizedBox(width: 48),
                ],
              ),
            ),
            const Expanded(child: AurumLyricsPage()),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background — soft blurred glow from the artwork's dominant tone.
// ─────────────────────────────────────────────────────────────────────────────
class _BackgroundGlow extends StatelessWidget {
  final String artworkUrl;
  const _BackgroundGlow({required this.artworkUrl});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF121212)),
          Opacity(
            opacity: 0.55,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 90, sigmaY: 90),
              child: Transform.scale(
                scale: 1.4,
                child: AurumArtwork(
                  url: artworkUrl,
                  size: double.infinity,
                  fadeIn: false,
                  isBlurredBackground: true,
                ),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.15),
                  const Color(0xFF121212).withOpacity(0.55),
                  const Color(0xFF121212),
                ],
                stops: const [0.0, 0.5, 0.85],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Collapsing header — expanded state shows the chevron / "NOW PLAYING" +
// song title subtitle / overflow menu (matches the reference screenshot's
// top bar while the hero artwork is in view). As the list scrolls up, it
// cross-fades into the compact sticky row: small artwork + title/artist +
// like + overflow (matches the same screenshot's collapsed state). Driven
// by a single 0..1 double, no extra AnimationController.
// ─────────────────────────────────────────────────────────────────────────────
class _CollapsingHeader extends StatelessWidget {
  final double collapseT;
  final Song song;
  final FavoritesProvider favorites;
  final VoidCallback onClose;
  final VoidCallback onMore;

  const _CollapsingHeader({
    required this.collapseT,
    required this.song,
    required this.favorites,
    required this.onClose,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Stack(
        children: [
          Opacity(
            opacity: (1 - collapseT * 1.6).clamp(0.0, 1.0),
            child: IgnorePointer(
              ignoring: collapseT > 0.5,
              child:
                  _ExpandedHeaderRow(onClose: onClose, song: song, onMore: onMore),
            ),
          ),
          Opacity(
            opacity: ((collapseT - 0.35) / 0.65).clamp(0.0, 1.0),
            child: IgnorePointer(
              ignoring: collapseT < 0.5,
              child: _CollapsedHeaderRow(
                  song: song, favorites: favorites, onMore: onMore),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpandedHeaderRow extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback onMore;
  final Song song;
  const _ExpandedHeaderRow(
      {required this.onClose, required this.song, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white, size: 30),
            onPressed: onClose,
          ),
          Expanded(
            child: Column(
              children: [
                const Text(
                  'NOW PLAYING',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '"${song.title}"',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded,
                color: Colors.white, size: 24),
            onPressed: onMore,
          ),
        ],
      ),
    );
  }
}

class _CollapsedHeaderRow extends StatelessWidget {
  final Song song;
  final FavoritesProvider favorites;
  final VoidCallback onMore;
  const _CollapsedHeaderRow(
      {required this.song, required this.favorites, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: AurumArtwork(url: song.artworkUrl, size: 44, borderRadius: 6),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          AurumLikeButton(
            isLiked: favorites.isFavorite(song.id),
            size: 22,
            likedColor: const Color(0xFF1ED760),
            unlikedColor: Colors.white,
            onTap: () => favorites.toggleFavorite(song),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert_rounded,
                color: Colors.white, size: 22),
            onPressed: onMore,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero — big square artwork + title/artist row + like button
// ─────────────────────────────────────────────────────────────────────────────
class _NowPlayingHero extends StatelessWidget {
  final PlayerProvider player;
  final Song song;
  const _NowPlayingHero({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesProvider>();
    final screenWidth = MediaQuery.of(context).size.width;
    final artSize = screenWidth - 64;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
      child: Column(
        children: [
          Center(
            child: Hero(
              tag: 'spotify_full_player_art_${song.id}',
              child: PhysicalModel(
                color: Colors.black,
                elevation: 18,
                shadowColor: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                child: AurumArtwork(
                  url: AurumArtwork.upgradeForFullPlayer(song.artworkUrl),
                  size: artSize,
                  borderRadius: 8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                AurumLikeButton(
                  isLiked: favorites.isFavorite(song.id),
                  size: 26,
                  likedColor: const Color(0xFF1ED760),
                  unlikedColor: Colors.white70,
                  onTap: () {
                    AurumHaptics.light();
                    favorites.toggleFavorite(song);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seekbar + transport controls — Spotify order: shuffle, prev, play/pause
// (big filled pill), next, repeat.
// ─────────────────────────────────────────────────────────────────────────────
class _ControlsBlock extends StatelessWidget {
  final PlayerProvider player;
  final Song song;
  const _ControlsBlock({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
      child: Column(
        children: [
          AurumSeekBar(
            player: player,
            hPad: 24,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            timeColor: Colors.white60,
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(
                    Icons.shuffle_rounded,
                    size: 22,
                    color: player.shuffle
                        ? const Color(0xFF1ED760)
                        : Colors.white70,
                  ),
                  onPressed: () {
                    AurumHaptics.light();
                    player.toggleShuffle();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous_rounded,
                      color: Colors.white, size: 36),
                  onPressed: () {
                    AurumHaptics.light();
                    player.skipPrev();
                  },
                ),
                _PlayPauseButton(player: player),
                IconButton(
                  icon: const Icon(Icons.skip_next_rounded,
                      color: Colors.white, size: 36),
                  onPressed: () {
                    AurumHaptics.light();
                    player.skipNext();
                  },
                ),
                IconButton(
                  icon: Icon(
                    player.loopMode == LoopMode.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    size: 22,
                    color: player.loopMode == LoopMode.off
                        ? Colors.white70
                        : const Color(0xFF1ED760),
                  ),
                  onPressed: () {
                    AurumHaptics.light();
                    player.toggleLoop();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  final PlayerProvider player;
  const _PlayPauseButton({required this.player});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            AurumHaptics.medium();
            player.togglePlay();
          },
          child: Center(
            child: player.isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: Colors.black,
                    ),
                  )
                : AurumPlayPauseIcon(
                    isPlaying: player.isPlaying,
                    color: Colors.black,
                    size: 30,
                  ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Icon actions row — song info / add to queue / open queue. Matches the
// reference screenshot's flat three-icon row directly under transport
// controls: ⓘ far-left, add-to-queue and open-queue grouped at the right.
// ─────────────────────────────────────────────────────────────────────────────
class _IconActionsRow extends StatelessWidget {
  final PlayerProvider player;
  final Song song;
  const _IconActionsRow({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded,
                color: Colors.white70, size: 22),
            onPressed: () => showSongInfoDialog(context, song),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.playlist_add_rounded,
                    color: Colors.white70, size: 24),
                onPressed: () {
                  AurumHaptics.light();
                  player.addToQueue(song);
                },
              ),
              IconButton(
                icon: const Icon(Icons.queue_music_rounded,
                    color: Colors.white70, size: 22),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const QueueScreen()),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics preview card — shows a plain-text preview (fetched once) with a
// "Show"/"Hide" toggle in the card itself, and tapping the preview text
// (once expanded) opens the full AurumLyricsPage synced-lyrics experience
// as a dedicated full-screen route, matching the reference screenshots'
// two-stage flow: inline card first, full immersive view on demand.
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPreviewCard extends StatefulWidget {
  final PlayerProvider player;
  final VoidCallback onOpenFullScreen;
  const _LyricsPreviewCard({
    required this.player,
    required this.onOpenFullScreen,
  });

  @override
  State<_LyricsPreviewCard> createState() => _LyricsPreviewCardState();
}

class _LyricsPreviewCardState extends State<_LyricsPreviewCard> {
  bool _expanded = false;
  bool _loading = false;
  String? _text;
  String? _loadedForSongId;

  Future<void> _toggle() async {
    final song = widget.player.currentSong;
    if (song == null) return;

    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    if (_loadedForSongId == song.id && _text != null) return;

    setState(() => _loading = true);
    try {
      final result = await widget.player.fetchSyncedLyrics();
      if (!mounted) return;
      setState(() {
        _text = result.hasAny ? result.plain : null;
        _loadedForSongId = song.id;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _text = null;
        _loadedForSongId = song.id;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.player.currentSong;
    if (song != null && _loadedForSongId != null && _loadedForSongId != song.id) {
      _expanded = false;
      _text = null;
      _loadedForSongId = null;
    }

    final hasText = _text != null && _text!.trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A2E7A), Color(0xFF2B1854)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Lyrics',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Material(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _toggle,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    child: Text(
                      _expanded ? 'Hide' : 'Show',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(height: 0, width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 20),
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white70,
                        ),
                      ),
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: hasText ? widget.onOpenFullScreen : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasText ? _text! : 'Lyrics not found',
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hasText
                                  ? Colors.white.withOpacity(0.92)
                                  : Colors.white54,
                              fontSize: 16,
                              height: 1.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (hasText) ...[
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Text(
                                  'View full lyrics',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.85),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: Colors.white.withOpacity(0.85),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artists card — artwork banner + name + "Artist" caption, Spotify style.
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// Artists section — splits song.artist on common multi-artist separators
// ("Kumar Sanu & Asha Bhosle", "A, B", "A feat. B", "A x B") into individual
// names, then shows one real, tappable artist card per name (own banner
// photo, resolved + fetched via the app's own ApiService — the same
// resolveArtistId/fetchArtist pair ArtistScreen itself uses — instead of
// one shared card reusing the song's album artwork for every artist).
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistsSection extends StatefulWidget {
  final Song song;
  const _ArtistsSection({required this.song});

  @override
  State<_ArtistsSection> createState() => _ArtistsSectionState();
}

class _ArtistsSectionState extends State<_ArtistsSection> {
  static final _splitPattern = RegExp(
    r'\s*(?:,|&|/|\bfeat\.?\b|\bft\.?\b|\bx\b|\bvs\.?\b)\s*',
    caseSensitive: false,
  );

  late final List<String> _names = _splitNames(widget.song.artist);

  List<String> _splitNames(String raw) {
    final parts = raw
        .split(_splitPattern)
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? [raw.trim()] : parts;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            'Artists',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final name in _names) ...[
          _SingleArtistCard(
            artistName: name,
            // Only the song's own primary artist name carries a known
            // channel id from search time; other split names (a featured
            // artist, a co-singer) always resolve by name.
            knownArtistId: name.trim().toLowerCase() ==
                    widget.song.artist.trim().toLowerCase()
                ? widget.song.artistChannelId
                : null,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _SingleArtistCard extends StatefulWidget {
  final String artistName;
  final String? knownArtistId;
  const _SingleArtistCard({required this.artistName, this.knownArtistId});

  @override
  State<_SingleArtistCard> createState() => _SingleArtistCardState();
}

class _SingleArtistCardState extends State<_SingleArtistCard> {
  bool _loading = true;
  bool _navigating = false;
  String? _resolvedId;
  String? _imageUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var id = widget.knownArtistId;
      id ??= await ApiService.resolveArtistId(widget.artistName);
      if (id == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final Artist? artist = await ApiService.fetchArtist(id, songCount: 1, albumCount: 1);
      if (!mounted) return;
      setState(() {
        _resolvedId = id;
        _imageUrl = artist?.imageUrl;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(BuildContext context) async {
    if (_navigating) return;
    AurumHaptics.selection();
    var id = _resolvedId;
    if (id == null) {
      setState(() => _navigating = true);
      id = await ApiService.resolveArtistId(widget.artistName);
      if (!mounted) return;
      setState(() => _navigating = false);
    }
    if (id == null || !context.mounted) return;
    AurumDepthRoute.to(
      context,
      ArtistScreen(artistId: id, artistName: widget.artistName),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFF1B1B1B),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _open(context),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_loading)
                    const ColoredBox(
                      color: Color(0xFF1B1B1B),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    )
                  else if (_imageUrl != null && _imageUrl!.isNotEmpty)
                    AurumArtwork(
                      url: _imageUrl!,
                      size: double.infinity,
                      borderRadius: 0,
                    )
                  else
                    ColoredBox(
                      color: Colors.white.withOpacity(0.06),
                      child: Center(
                        child: Icon(Icons.person_rounded,
                            color: Colors.white.withOpacity(0.3), size: 48),
                      ),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.75),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 16,
                    bottom: 14,
                    right: 16,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                'Artist',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_navigating)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white70,
                            ),
                          )
                        else
                          const Icon(Icons.chevron_right_rounded,
                              color: Colors.white70, size: 22),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Description / credits card — title, duration, artist, "Description" +
// "More" affordance.
// ─────────────────────────────────────────────────────────────────────────────
class _DescriptionCard extends StatelessWidget {
  final Song song;
  final VoidCallback onMore;
  const _DescriptionCard({required this.song, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A2E7A), Color(0xFF2B1854)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            song.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            song.durationString.isNotEmpty ? song.durationString : '--:--',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            song.artist,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Description',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${song.title} • ${song.artist}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: onMore,
            child: const Text(
              'More',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
