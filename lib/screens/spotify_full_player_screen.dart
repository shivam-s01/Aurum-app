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
import '../models/lyrics.dart' show LyricsResult, LyricLine;
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_seek_bar.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/aurum_play_pause_icon.dart';
// FIX ("3 dot pr ekdam real app ka sheet khule — albums/liked/download
// wala"): swapped the screen's own bespoke _PlayerMoreSheet (a short,
// hand-rolled 4-row sheet with no album/download/playlist rows) for the
// app's single shared "3-dot" song menu — the exact same sheet every
// other screen (song tiles, library, Classic player) already opens.
import '../widgets/aurum_song_options_sheet.dart' show showAurumSongOptions;
import '../utils/aurum_haptics.dart';
import '../services/api_service.dart';
import '../utils/aurum_transitions.dart' show AurumDepthRoute;
import 'artist_screen.dart';
import 'queue_screen.dart';
// FIX ("us icon pr click pr playlist ka option aana chahiye save ke
// liye — jisme add kare ya new banaye"): the app's own shared
// add-to-playlist picker (create/select playlist), reused instead of
// leaving the icon wired to a silent queue-add.
import 'library_screen.dart' show showAddToPlaylistSheet;
// Reuses the app's own existing lyrics widget (full fetch/sync/scroll/
// highlight behavior, already premium and battle-tested) and the existing
// song-info bottom sheet, instead of re-implementing either.
import 'full_player_screen.dart' show AurumLyricsPage, showSongInfoDialog;

// ─────────────────────────────────────────────────────────────────────────────
// The 3-dot "more" button below now opens showAurumSongOptions directly
// (see import above) — the app's single shared song menu, not a bespoke
// sheet local to this screen.
// ─────────────────────────────────────────────────────────────────────────────

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

  // FIX ("up next ekdam same aisa chahiye ekdam top level ka"): this was
  // opening QueueScreen via a plain MaterialPageRoute — the stock
  // slide-in-from-the-right push, which reads like leaving the player
  // for an unrelated screen. QueueScreen's own layout already matches
  // the reference (see its file header comment), so nothing there
  // needed to change — only how it's presented. Routing it through the
  // exact same fade+rise PageRouteBuilder as _openFullLyrics above
  // makes it feel like the same "top level" surface as lyrics, both
  // reached the same way from this player.
  void _openQueue(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, __, ___) => const QueueScreen(),
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

  // FIX ("thumbnail ke paas se swipe down se dismiss nahi ho raha"): the
  // outer GestureDetector and the inner SingleChildScrollView were both
  // vertical-drag recognizers competing over the exact same touch area
  // (the hero/artwork sits INSIDE the scroll view, not above it) — in
  // Flutter's gesture arena the Scrollable routinely wins that race, so
  // a drag starting over the thumbnail scrolled the list instead of
  // dismissing. Freezing the list to NeverScrollableScrollPhysics for the
  // duration of a from-the-top downward drag removes the competing
  // recognizer entirely, so the outer detector is the only thing that can
  // claim the gesture. Physics are restored the instant the drag ends
  // (dismiss or spring-back) so normal scrolling is completely unaffected
  // once the user isn't actively dragging from the top.
  bool _scrollLocked = false;

  void _onVerticalDragStart(DragStartDetails details) {
    if (_collapseT > 0.02) return; // let the scroll view handle it instead
    setState(() {
      _dragging = true;
      _scrollLocked = true;
    });
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    // FIX ("thumbnail ekdam niche chala jaata hai, unstable/akward"): this
    // used a flat clamp(0.0, 400.0) — a fixed pixel cap with no relation
    // to the device's actual screen height. On a shorter screen 400px of
    // travel is most/all of the screen, so the whole Column (hero art +
    // controls + icon row, all inside the single Transform.translate in
    // build() below) could drag almost fully off-screen before the
    // release threshold (140px) even mattered — reading as the artwork
    // "falling" and the bottom row "jumping up" to meet the header.
    // Scaling the cap to a fraction of the real screen height (same
    // approach Classic's own _DragTransform in full_player_screen.dart
    // uses) keeps the drag small, proportional and stable on every
    // device, while the 140px/700 velocity thresholds below still decide
    // when it actually dismisses.
    final screenH = MediaQuery.of(context).size.height;
    final maxDrag = screenH * 0.28;
    setState(() {
      _dragDy = (_dragDy + details.delta.dy).clamp(0.0, maxDrag);
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
      _scrollLocked = false;
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
        // FIX: kept in sync with the height-scaled cap in
        // _onVerticalDragUpdate above (was a flat 400.0, same
        // instability). Denominator matches maxDrag there exactly.
        final screenH = MediaQuery.of(context).size.height;
        final dragT = (_dragDy / (screenH * 0.28)).clamp(0.0, 1.0);
        final scale = 1.0 - (dragT * 0.06);
        final opacity = 1.0 - (dragT * 0.35);

        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: Listener(
            // FIX ("thumbnail ke paas se swipe down dismiss nahi ho raha"):
            // fires on the raw pointer-down, before the gesture arena
            // between this drag detector and the scroll view's own
            // Scrollable even starts resolving. Locking scroll physics
            // here — whenever a touch lands while the list is still at
            // the top — guarantees the outer vertical-drag detector below
            // is the only recognizer left standing for that touch, so a
            // drag starting on the thumbnail always dismisses instead of
            // occasionally scrolling instead.
            onPointerDown: (_) {
              if (_collapseT <= 0.02 && !_scrollLocked) {
                setState(() => _scrollLocked = true);
              }
            },
            // A plain tap (no drag ever recognized) leaves _dragging false,
            // so onVerticalDragEnd never fires to release the lock taken on
            // pointer-down above — release it here instead whenever the
            // pointer goes up/away without a drag having started.
            onPointerUp: (_) {
              if (!_dragging && _scrollLocked) {
                setState(() => _scrollLocked = false);
              }
            },
            onPointerCancel: (_) {
              if (!_dragging && _scrollLocked) {
                setState(() => _scrollLocked = false);
              }
            },
            child: GestureDetector(
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
                              onMore: () => showAurumSongOptions(
                                context,
                                song,
                                showPlayerTools: true,
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                controller: _scrollCtrl,
                                physics: _scrollLocked
                                    ? const NeverScrollableScrollPhysics()
                                    : const BouncingScrollPhysics(
                                        parent: AlwaysScrollableScrollPhysics(),
                                      ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _NowPlayingHero(player: player, song: song),
                                    _ControlsBlock(player: player, song: song),
                                    _IconActionsRow(
                                      player: player,
                                      song: song,
                                      onOpenQueue: () => _openQueue(context),
                                    ),
                                    const SizedBox(height: 28),
                                    _LyricsPreviewCard(
                                      player: player,
                                      onOpenFullScreen: () =>
                                          _openFullLyrics(context),
                                    ),
                                    const SizedBox(height: 20),
                                    _ArtistsSection(song: song),
                                    _DescriptionCard(song: song),
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
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-screen lyrics route content — the app's own AurumLyricsPage (live
// synced highlight/scroll/glow, unchanged) under a real "now playing"
// header: thumbnail, title/artist, like, 3-dot — matching the reference
// screenshot instead of a bare centered "Lyrics" title bar.
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPageWrapper extends StatelessWidget {
  const _LyricsPageWrapper();

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        final favorites = context.watch<FavoritesProvider>();
        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: Stack(
            children: [
              if (song != null)
                _BackgroundGlow(
                  artworkUrl: AurumArtwork.upgradeForFullPlayer(
                      song.artworkUrl),
                ),
              SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 6, 12, 10),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white,
                                size: 28),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          if (song != null) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: AurumArtwork(
                                url: song.artworkUrl,
                                size: 40,
                                borderRadius: 6,
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                          Expanded(
                            child: song == null
                                ? const Text(
                                    'Lyrics',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
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
                          if (song != null) ...[
                            AurumLikeButton(
                              isLiked: favorites.isFavorite(song.id),
                              size: 22,
                              likedColor: const Color(0xFF1ED760),
                              unlikedColor: Colors.white,
                              onTap: () {
                                AurumHaptics.light();
                                favorites.toggleFavorite(song);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert_rounded,
                                  color: Colors.white, size: 22),
                              onPressed: () => showAurumSongOptions(
                                context,
                                song,
                                showPlayerTools: true,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Expanded(child: AurumLyricsPage()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
    final screenSize = MediaQuery.of(context).size;
    // FIX ("thumbnail chhota kro aur thumbnail-controls ke bich ka gap
    // kam kro"): the hero cover was sized to near-full screen width
    // (width - 36) with a 32dp gap before the title/controls below —
    // read as oversized and too spaced-out compared to the reference.
    // Smaller side inset multiplier (0.62 of width instead of ~0.95) and
    // a tighter post-art gap (18 instead of 32) close both up.
    final artSize = (screenSize.width * 0.62)
        .clamp(0.0, screenSize.height * 0.32);

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
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
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
// Icon actions row — song info / add to playlist / open queue (Up Next).
// Matches the reference screenshot's flat three-icon row directly under
// transport controls: ⓘ far-left, playlist-save and open-queue grouped
// at the right.
// ─────────────────────────────────────────────────────────────────────────────
class _IconActionsRow extends StatelessWidget {
  final PlayerProvider player;
  final Song song;
  final VoidCallback onOpenQueue;
  const _IconActionsRow({
    required this.player,
    required this.song,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 0),
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
              // FIX ("playlist ke bagal wala option working nahi tha —
              // click pr playlist ka option aana chahiye save ke liye,
              // jisme add kare ya new banaye"): this silently called
              // player.addToQueue with no visible sheet or feedback,
              // which is exactly why it looked broken/dead. Wired to the
              // app's own shared add-to-playlist picker instead — same
              // one every other screen uses to add a song to an existing
              // playlist or create a new one.
              IconButton(
                icon: const Icon(Icons.playlist_add_rounded,
                    color: Colors.white70, size: 24),
                onPressed: () {
                  AurumHaptics.light();
                  showAddToPlaylistSheet(context, song);
                },
              ),
              IconButton(
                icon: const Icon(Icons.queue_music_rounded,
                    color: Colors.white70, size: 22),
                onPressed: onOpenQueue,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics peek card — a bigger, "Bhojpuri-reference" sized box (not a thin
// one-line teaser row) that shows 3 real lyric lines with the currently
// playing line live-highlighted and auto-centered as the song advances —
// same data source as the app's full lyrics screen (PlayerProvider.
// fetchSyncedLyrics() + LyricsResult.activeIndexFor(position)), just a
// fixed, short "peek" height here so only a glimpse is visible in the
// player itself; tapping it opens the app's full AurumLyricsPage for the
// complete, scrollable experience.
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
  // FIX ("bina scroll kiye lyrics ka pura box na dikhe, bs 10% jitna peek
  // ho ki niche kuch hai"): was 132 tall with room for 3 full lines (one
  // above, active, one below) — closer to the full lyrics view already
  // laid out inline than a teaser. Shrunk to a single active-line sliver
  // under the "Lyrics" header, clipped short enough that only a hint of
  // it is visible — the rest only appears once the user actually scrolls
  // it into fuller view or taps through to the full lyrics screen.
  static const double _peekHeight = 76.0;

  bool _loading = true;
  LyricsResult? _result;
  String? _loadedForSongId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final song = widget.player.currentSong;
    if (song == null) return;
    try {
      final result = await widget.player.fetchSyncedLyrics();
      if (!mounted) return;
      setState(() {
        _result = result;
        _loadedForSongId = song.id;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _loadedForSongId = song.id;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.player.currentSong;
    if (song != null &&
        _loadedForSongId != null &&
        _loadedForSongId != song.id) {
      _loading = true;
      _result = null;
      _loadedForSongId = null;
      // Re-check for the new song without blocking this build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    final result = _result;
    final hasLyrics = result?.hasAny ?? false;
    final hasSynced = result?.hasSynced ?? false;

    return Container(
      height: _peekHeight,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4A2E7A), Color(0xFF2B1854)],
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: (_loading || !hasLyrics) ? null : widget.onOpenFullScreen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lyrics_rounded,
                        color: Colors.white70, size: 18),
                    const SizedBox(width: 10),
                    const Text(
                      'Lyrics',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (_loading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white54,
                        ),
                      )
                    else if (hasLyrics)
                      Icon(Icons.chevron_right_rounded,
                          size: 18, color: Colors.white.withOpacity(0.75)),
                  ],
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: _loading
                      ? const SizedBox.shrink()
                      : !hasLyrics
                          ? const Center(
                              child: Text(
                                'Lyrics not found',
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : hasSynced
                              ? _LivePeekLines(result: result!)
                              : Center(
                                  child: Text(
                                    result!.plain!.split('\n').first,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14.5,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Live single-line lyric peek — shows ONLY the currently-active line,
// updating live with playback position, top-aligned in a short box with a
// fade at the bottom so it reads as "there's more below" rather than the
// full lyrics view sitting inline. Tapping the card (see _LyricsPreviewCard
// above) opens the app's full AurumLyricsPage for the complete scroll.
// ─────────────────────────────────────────────────────────────────────────────
class _LivePeekLines extends StatelessWidget {
  final LyricsResult result;
  const _LivePeekLines({required this.result});

  @override
  Widget build(BuildContext context) {
    final position =
        context.select<PlayerProvider, Duration>((p) => p.position);
    final lines = result.synced!;
    final activeIndex = result.activeIndexFor(position);
    final activeText = (activeIndex >= 0 && activeIndex < lines.length)
        ? lines[activeIndex].text
        : (lines.isNotEmpty ? lines.first.text : '');

    return ClipRect(
      child: ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: Align(
          alignment: Alignment.topLeft,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: Text(
              activeText.isEmpty ? ' ' : activeText,
              key: ValueKey(activeIndex),
              maxLines: 2,
              overflow: TextOverflow.fade,
              softWrap: true,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ),
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
// ─────────────────────────────────────────────────────────────────────────────
// Description card — sized to match the Artists card exactly (same 16:9
// AspectRatio, same horizontal 16 margin) so the two sections below the
// lyrics peek read as one consistent set of banner-sized cards, instead of
// a tall artist banner sitting above a short, content-height details box.
// ─────────────────────────────────────────────────────────────────────────────
class _DescriptionCard extends StatelessWidget {
  final Song song;
  const _DescriptionCard({required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          padding: const EdgeInsets.all(18),
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
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${song.durationString.isNotEmpty ? song.durationString : '--:--'} • ${song.artist}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  '${song.title} • ${song.artist}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
              // FIX ("More" pr ekdam lyrics khulte the — usko song details
              // ka page/sheet khulna chahiye): swapped to the app's own
              // showSongInfoDialog — the same "details" surface the ⓘ icon
              // and shared 3-dot menu already use.
              GestureDetector(
                onTap: () => showSongInfoDialog(context, song),
                child: const Text(
                  'More',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
