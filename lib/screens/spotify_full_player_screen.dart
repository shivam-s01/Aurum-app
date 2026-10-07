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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../models/song.dart';
import '../models/lyrics.dart' show LyricsResult, LyricLine;
import '../widgets/aurum_artwork.dart';
import '../utils/artwork_palette_cache.dart';
import '../utils/route_drag_dismiss.dart';
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
  // PERF: ValueNotifier — scrolling the first 120px used to setState the
  // WHOLE player (artwork, lyrics, controls…) every frame just to fade the
  // header. Now only the header subtree rebuilds.
  final ValueNotifier<double> _collapseN = ValueNotifier<double>(0.0);

  static const double _collapseDistance = 120.0;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
  }

  void _onScroll() {
    final t = (_scrollCtrl.offset / _collapseDistance).clamp(0.0, 1.0);
    if (t != _collapseN.value) _collapseN.value = t;
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _collapseN.dispose();
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
        // FIX (swipe-down: background me alag layer): a route-level
        // barrierColor is a separate full-screen layer that stays put and
        // fades on its own while the queue moves — that was the extra
        // layer visible behind. QueueScreen now carries its own solid
        // base that moves WITH it, so no barrier layer is needed.
        barrierColor: null,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => const QueueScreen(),
        // Full-height slide (same motion family as the player itself).
        // This is what makes swipe-down 1:1: QueueScreen drives THIS
        // route's controller with the finger (RouteDragDismiss), so the
        // queue follows the finger exactly and releasing continues the
        // very same motion — no second transform, no fade-under layer.
        transitionsBuilder: (ctx, animation, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(routeDragCurve(ctx, animation)),
          child: child,
        ),
      ),
    );
  }

  // ── Swipe-down-to-dismiss ────────────────────────────────────────────────
  //
  // Swipe-down-to-dismiss is driven by the ROUTE'S OWN animation controller
  // (see utils/route_drag_dismiss.dart). The finger sets the route's
  // controller value directly, so the route's SlideTransition is the ONE
  // and only thing that moves the screen — the whole player (artwork
  // included) slides as a single piece, with no second transform stacked
  // on top, no extra layer, and no double slide on release.
  static const double _dismissDistance = 120.0;
  static const double _dismissVelocity = 900.0;

  // Finger side of the dismiss lives in PullDownDismiss (raw Listener, see
  // utils/route_drag_dismiss.dart) — a GestureDetector above the scroll view
  // never won the gesture arena, so the scroll view over-scrolled and only
  // the artwork moved.
  final PullDownDismissController _pull = PullDownDismissController();

  @override
  Widget build(BuildContext context) {
    // PERF: was Consumer<PlayerProvider> — rebuilt this whole screen on every
    // 500ms position tick. Only these five fields are read below (the seek
    // bar has its own Selector), so rebuild only when one of them changes.
    return Selector<PlayerProvider, (Song?, bool, bool, LoopMode, bool)>(
      selector: (_, p) =>
          (p.currentSong, p.isLoading, p.isPlaying, p.loopMode, p.shuffle),
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        final song = player.currentSong;
        if (song == null) {
          return const Scaffold(
            backgroundColor: Color(0xFF121212),
            body: SizedBox.shrink(),
          );
        }
        final favorites = context.watch<FavoritesProvider>();

        // No per-frame transform here any more: the route's own
        // SlideTransition moves this whole screen (driven by the finger
        // via RouteDragDismiss), so artwork + controls + lyrics travel as
        // one rigid piece and nothing is composited twice.
        return Scaffold(
          backgroundColor: const Color(0xFF121212),
          body: PullDownDismiss(
            controller: _pull,
            scrollController: _scrollCtrl,
            dismissDistance: _dismissDistance,
            dismissVelocity: _dismissVelocity,
            child: RepaintBoundary(
              child: ColoredBox(
                color: const Color(0xFF121212),
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
                            ValueListenableBuilder<double>(
                              valueListenable: _collapseN,
                              builder: (context, collapseT, _) =>
                                  _CollapsingHeader(
                                collapseT: collapseT,
                                song: song,
                                favorites: favorites,
                                onClose: () =>
                                    Navigator.of(context).maybePop(),
                                onMore: () => showAurumSongOptions(
                                  context,
                                  song,
                                  showPlayerTools: true,
                                ),
                              ),
                            ),
                            Expanded(
                              // LayoutBuilder gives us the REAL height left
                              // under the header, so "page 1" can be sized to
                              // exactly that (minus a small lyrics peek) —
                              // the hero/controls then always fit one screen
                              // on any device, instead of flowing wherever
                              // their fixed paddings happen to land.
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  // How much of the lyrics card peeks in at
                                  // the bottom of page 1 (Spotify-style hint
                                  // that there is more below the fold).
                                  const double peek = 64.0;
                                  final double page1H =
                                      (constraints.maxHeight - peek)
                                          .clamp(0.0, double.infinity)
                                          .toDouble();
                                  return SingleChildScrollView(
                                    controller: _scrollCtrl,
                                    physics: _pull.physics,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // ── PAGE 1: only artwork + title +
                                        // seekbar + controls + icon row.
                                        SizedBox(
                                          height: page1H,
                                          child: _PlayerPage(
                                            player: player,
                                            song: song,
                                            onOpenQueue: () =>
                                                _openQueue(context),
                                          ),
                                        ),
                                        // ── BELOW THE FOLD: lyrics peeks in
                                        // from the bottom of page 1, then
                                        // artists + description on scroll.
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
                                  );
                                },
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
    return Selector<PlayerProvider, Song?>(
      selector: (_, p) => p.currentSong,
      builder: (context, song, _) {
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
// Background — Spotify-style SOLID TINT, not a blurred copy of the artwork.
//
// Why not blur: a heavily blurred, scaled-up copy of the cover turns
// multi-coloured / white-heavy artwork (like the Imtihan poster) into a
// muddy, washed-out smear, and it costs a full-screen Gaussian blur every
// frame. Spotify instead extracts ONE dominant colour from the cover and
// fades it top → the app's near-black, which is why every Spotify player
// looks clean regardless of the cover.
//
// Here that colour comes from the app's own ArtworkPaletteCache (same
// extractor the classic player uses, cached, so it is instant for songs
// already seen). It is pushed through ensureContrastSafe() so white text
// can never disappear on a light cover, and the tint animates smoothly
// when the song changes rather than snapping.
// ─────────────────────────────────────────────────────────────────────────────
class _BackgroundGlow extends StatefulWidget {
  final String artworkUrl;
  const _BackgroundGlow({required this.artworkUrl});

  @override
  State<_BackgroundGlow> createState() => _BackgroundGlowState();
}

class _BackgroundGlowState extends State<_BackgroundGlow> {
  static const Color _base = Color(0xFF121212);
  // Calm neutral shown only until the first colour arrives.
  static const Color _neutral = Color(0xFF2A2A2A);

  Color _tint = _neutral;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _BackgroundGlow old) {
    super.didUpdateWidget(old);
    if (old.artworkUrl != widget.artworkUrl) _resolve();
  }

  // Turns the extracted cover colour into the player's top tint.
  //
  // Rules, tuned so it behaves like Spotify's own now-playing screen:
  //  • keep the cover's HUE and most of its saturation — a red cover reads
  //    red, not brown;
  //  • brightness is capped (≈0.50) so white title/controls always have
  //    strong contrast, and never lifted for dark covers — a near-black
  //    cover must stay near-black (Spotify does not turn it grey);
  //  • near-grey / near-white covers (no real hue) get a small, neutral
  //    charcoal instead of a flat mid-grey slab, which is what looked
  //    "washed out" on pale artwork.
  Color _pick(ArtworkPalette p) {
    final raw =
        p.gradientColors.isNotEmpty ? p.gradientColors.first : p.dominant;
    final hsv = HSVColor.fromColor(raw);

    // Colourless cover (grey / white / black): neutral charcoal, scaled a
    // little by how light the cover is so it still feels connected to it.
    if (hsv.saturation < 0.12) {
      final v = (0.16 + hsv.value * 0.10).clamp(0.16, 0.26).toDouble();
      return HSVColor.fromAHSV(1.0, hsv.hue, 0.0, v).toColor();
    }

    // Coloured cover: keep hue, tame neon, cap brightness. No lower lift —
    // a genuinely dark colour stays dark.
    final sat = (hsv.saturation * 0.88).clamp(0.30, 0.82).toDouble();
    final val = (hsv.value * 0.62).clamp(0.20, 0.50).toDouble();
    return HSVColor.fromAHSV(1.0, hsv.hue, sat, val).toColor();
  }

  Future<void> _resolve() async {
    final url = widget.artworkUrl;
    if (url.isEmpty) return;

    // 1) Instant: already cached from a previous play/other screen.
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      if (mounted) setState(() => _tint = _pick(cached));
      return;
    }
    // 2) Quick coarse colour first so the screen is tinted almost at once…
    ArtworkPaletteCache.getFast(url).then((fast) {
      if (!mounted || widget.artworkUrl != url || fast == null) return;
      setState(() => _tint = _pick(fast));
    });
    // 3) …then the accurate palette replaces it (animated, so no jump).
    final full = await ArtworkPaletteCache.get(url);
    if (!mounted || widget.artworkUrl != url) return;
    setState(() => _tint = _pick(full));
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: TweenAnimationBuilder<Color?>(
        // Only `end` changes; the builder animates from whatever colour is
        // currently on screen to the new one, so song changes cross-fade.
        tween: ColorTween(end: _tint),
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeOut,
        builder: (context, color, _) {
          final c = color ?? _tint;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [c, Color.lerp(c, _base, 0.5)!, _base],
                stops: const [0.0, 0.38, 0.85],
              ),
            ),
          );
        },
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
// _PlayerPage — the whole first screen of the player, laid out to fill the
// exact viewport it is given (see LayoutBuilder in build()):
//
//   [ flexible space ]
//   big square artwork            ← takes every pixel that's left over
//   title / artist + like
//   seekbar + times
//   shuffle / prev / play / next / repeat
//   ⓘ ............ + playlist  queue
//
// The artwork is the ONLY flexible element. Everything else has a fixed,
// compact height, so on a tall phone the cover simply grows, on a short one
// it shrinks — but the controls always sit at the same comfortable spot
// right above the lyrics peek, never pushed off-screen and never floating
// with awkward empty gaps (the old "thumbnail small + big gap" look).
// ─────────────────────────────────────────────────────────────────────────────
class _PlayerPage extends StatelessWidget {
  final PlayerProvider player;
  final Song song;
  final VoidCallback onOpenQueue;
  const _PlayerPage({
    required this.player,
    required this.song,
    required this.onOpenQueue,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Artwork zone: fills all remaining height; the square is the largest
        // one that fits both the width (minus side margin) and this height.
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              const double sideMargin = 20.0;
              const double vPad = 10.0;
              final double byWidth = c.maxWidth - sideMargin * 2;
              final double byHeight = c.maxHeight - vPad * 2;
              final double side =
                  (byWidth < byHeight ? byWidth : byHeight)
                      .clamp(0.0, 4000.0)
                      .toDouble();
              return Center(
                // FIX (swipe-down: thumbnail alag neeche jata tha): the
                // Hero here made the artwork fly on its own during the
                // pop/drag, detaching it from the rest of the player.
                // No matching Hero exists on the previous route, so it
                // only ever caused that detached motion. Plain artwork
                // now moves rigidly with the whole player.
                child: PhysicalModel(
                  color: Colors.black,
                  elevation: 20,
                  shadowColor: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                  child: AurumArtwork(
                    url: AurumArtwork.upgradeForFullPlayer(song.artworkUrl),
                    size: side,
                    borderRadius: 8,
                  ),
                ),
              );
            },
          ),
        ),
        _TitleRow(song: song),
        _ControlsBlock(player: player, song: song),
        _IconActionsRow(
          player: player,
          song: song,
          onOpenQueue: onOpenQueue,
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

// Title + artist on the left, like button on the right (reference layout).
class _TitleRow extends StatelessWidget {
  final Song song;
  const _TitleRow({required this.song});

  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesProvider>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
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
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
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
            size: 27,
            likedColor: const Color(0xFF1ED760),
            unlikedColor: Colors.white,
            onTap: () {
              AurumHaptics.light();
              favorites.toggleFavorite(song);
            },
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
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
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
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
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
  static const double _peekHeight = 200.0;

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
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
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
                    // Reference layout: bold "Lyrics" on the left, a
                    // "Show" affordance on the right (no leading icon).
                    const Text(
                      'Lyrics',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
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
                      Text(
                        'Show',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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
                              : Align(
                                  alignment: Alignment.topLeft,
                                  child: Text(
                                    result!.plain!
                                        .split('\n')
                                        .where((l) => l.trim().isNotEmpty)
                                        .take(5)
                                        .join('\n'),
                                    maxLines: 5,
                                    overflow: TextOverflow.fade,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                      height: 1.5,
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
// Live lyrics peek — a real, moving view of the synced lyrics inside the
// card. The active line is bright/bold and glides to a fixed resting spot
// near the top of the viewport as the song plays; already-sung lines dim
// out above it and upcoming lines sit softly below, fading at the bottom
// so it reads as "more below". Driven purely by playback position via
// LyricsResult.activeIndexFor(); the scroll target is computed from a
// fixed per-line extent, so there is no measuring/re-layout jitter.
// Tapping the card still opens the full AurumLyricsPage.
// ─────────────────────────────────────────────────────────────────────────────
class _LivePeekLines extends StatefulWidget {
  final LyricsResult result;
  const _LivePeekLines({required this.result});

  @override
  State<_LivePeekLines> createState() => _LivePeekLinesState();
}

class _LivePeekLinesState extends State<_LivePeekLines> {
  // Fixed slot height per lyric line (single line, ellipsised) — keeps the
  // scroll maths exact and the motion perfectly smooth.
  static const double _lineExtent = 34.0;

  final ScrollController _ctrl = ScrollController();
  int _lastActive = -2;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _glideTo(int active) {
    if (!_ctrl.hasClients) return;
    // Rest the active line one slot below the top edge so a dimmed
    // "previous" line stays visible above it, like the reference.
    final target = ((active - 1) * _lineExtent)
        .clamp(0.0, _ctrl.position.maxScrollExtent)
        .toDouble();
    _ctrl.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final position =
        context.select<PlayerProvider, Duration>((p) => p.position);
    final lines = widget.result.synced!;
    final active = widget.result.activeIndexFor(position);

    if (active != _lastActive) {
      _lastActive = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _glideTo(active < 0 ? 0 : active);
      });
    }

    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.white, Colors.white, Colors.transparent],
        stops: [0.0, 0.7, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _ctrl,
        // The card is a peek, not a scroller: the outer page owns all
        // vertical gestures, so this inner list must never grab them.
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemExtent: _lineExtent,
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final isActive = i == active;
          final isPast = active >= 0 && i < active;
          final text = lines[i].text.trim();
          return Align(
            alignment: Alignment.centerLeft,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              style: TextStyle(
                color: isActive
                    ? Colors.white
                    : Colors.white.withOpacity(isPast ? 0.38 : 0.6),
                fontSize: isActive ? 17 : 15.5,
                fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                height: 1.2,
              ),
              child: Text(
                text.isEmpty ? '♪' : text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
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
            fallbackImageUrl: widget.song.artworkUrl,
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
  // Song's own artwork — shown whenever no real artist photo can be found,
  // so the card is never an empty grey placeholder.
  final String fallbackImageUrl;
  const _SingleArtistCard({
    required this.artistName,
    required this.fallbackImageUrl,
    this.knownArtistId,
  });

  @override
  State<_SingleArtistCard> createState() => _SingleArtistCardState();
}

class _SingleArtistCardState extends State<_SingleArtistCard> {
  bool _loading = true;
  bool _navigating = false;
  String? _resolvedId;
  String? _imageUrl; // real artist photo, when one exists

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _SingleArtistCard old) {
    super.didUpdateWidget(old);
    // Same card widget reused for a different artist (song changed).
    if (old.artistName != widget.artistName ||
        old.knownArtistId != widget.knownArtistId) {
      setState(() {
        _loading = true;
        _resolvedId = null;
        _imageUrl = null;
      });
      _load();
    }
  }

  // ONE fast search call returns BOTH the artist's channel id and their
  // real photo (ApiService.searchArtists → ArtistSimple). The previous
  // version resolved the id, then called the heavy fetchArtist() just to
  // read imageUrl — which pulls a whole artist page (and can chain a
  // second uploads fetch with a very long timeout). That was slow and the
  // main reason artist photos often never showed up.
  Future<void> _load() async {
    final wanted = widget.artistName;
    try {
      final results = await ApiService.searchArtists(wanted, limit: 3)
          .timeout(const Duration(seconds: 8));
      if (!mounted || wanted != widget.artistName) return;

      ArtistSimple? pick;
      final lower = wanted.trim().toLowerCase();
      for (final r in results) {
        if (r.name.trim().toLowerCase() == lower) {
          pick = r;
          break;
        }
      }
      pick ??= results.isNotEmpty ? results.first : null;

      setState(() {
        _resolvedId = widget.knownArtistId ?? pick?.id;
        _imageUrl = (pick != null && pick.imageUrl.isNotEmpty)
            ? pick.imageUrl
            : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _resolvedId = widget.knownArtistId;
          _loading = false;
        });
      }
    }
  }

  // Always lands on the REAL artist page. If the id isn't resolved yet (or
  // the search failed earlier), ArtistScreen is handed just the name and
  // resolves it itself — so a tap never dead-ends.
  Future<void> _open(BuildContext context) async {
    if (_navigating) return;
    AurumHaptics.selection();
    var id = _resolvedId;
    if (id == null) {
      setState(() => _navigating = true);
      try {
        id = await ApiService.resolveArtistId(widget.artistName);
      } catch (_) {}
      if (!mounted) return;
      setState(() => _navigating = false);
    }
    if (!context.mounted) return;
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
                  // Real artist photo when we have one; otherwise (still
                  // loading, or none exists) the song's own thumbnail so the
                  // card always shows a real image instead of grey.
                  if (_imageUrl != null && _imageUrl!.isNotEmpty)
                    AurumArtwork(
                      url: _imageUrl!,
                      size: double.infinity,
                      borderRadius: 0,
                    )
                  else if (widget.fallbackImageUrl.isNotEmpty)
                    AurumArtwork(
                      url: AurumArtwork.upgradeForFullPlayer(
                          widget.fallbackImageUrl),
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
