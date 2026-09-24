import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../theme/aurum_theme.dart';
import '../services/api_service.dart';
import 'aurum_like_button.dart';
import 'aurum_stacked_artwork.dart';
import '../utils/aurum_haptics.dart';
import 'aurum_song_options_sheet.dart';

class SongTile extends StatefulWidget {
  final Song song;
  final List<Song>? queue;
  final int? index;
  final bool showIndex;
  final int? displayIndex;
  // FIX ("Up Next doesn't contain the rest of my liked songs/playlist"):
  // tells PlayerProvider.playSong() whether `queue` is a real, user-picked
  // list (Liked Songs, a playlist, an album, a mix, a library section,
  // Recently Played) that should be played exactly as given, vs. a loose
  // "whatever else was on screen" list (search results) that should still
  // get trimmed and rebuilt from real recommendations. Screens that show a
  // genuine saved list pass true; search passes false (the default).
  final bool curatedQueue;

  // MULTI-SELECT LONG-PRESS FIX ("long press krne pe kuch hota hi nahi" on
  // Liked Songs): screens that need to enter a multi-select mode used to
  // wrap SongTile in their own outer GestureDetector(onLongPress: ...).
  // That never worked — SongTile's own InkWell(onLongPress: _showOptions)
  // is registered on a descendant in the same gesture arena, and Flutter
  // resolves a long-press conflict in favor of the inner recognizer, so
  // the outer callback never fired and only the options sheet ever
  // triggered. Passing a callback here lets the tile itself swap its
  // long-press target to the caller's handler (e.g. entering select mode)
  // instead of racing a second recognizer against its own — no arena
  // conflict, because there's only ever one long-press recognizer.
  final VoidCallback? onLongPressOverride;

  const SongTile({
    super.key,
    required this.song,
    this.queue,
    this.index,
    this.showIndex = false,
    this.displayIndex,
    this.curatedQueue = false,
    this.onLongPressOverride,
  });

  @override
  State<SongTile> createState() => _SongTileState();
}

class _SongTileState extends State<SongTile> {
  // FIX: per-instance debounce (was static — one tile blocked ALL tiles)
  bool _isTapping = false;

  // SCROLL LAG FIX (100-song mixes/playlists — "scroll pe lag ekdam jyada"):
  // this tile used to fire its prewarm HTTP call straight from initState
  // with NO way to cancel it and NO dispose() at all. That's harmless for
  // a short, mostly-static list, but SliverList/ListView.builder
  // continuously builds AND DESTROYS tiles as they pass through the
  // viewport + cacheExtent during a fast scroll/fling — so on a 100-song
  // mix, flinging through the list could build dozens of tiles in a
  // couple hundred ms, each one firing its own fire-and-forget HTTP
  // request+timer that then had no way to be cancelled even after the
  // tile scrolled away and was disposed. That's a burst of live network
  // calls competing for CPU/main-thread time on exactly the frames that
  // need to stay smooth. Holding the timer here and cancelling it in
  // dispose() means a tile that only flashed past during a fling never
  // fires its request at all — only tiles the user actually stays on
  // long enough to see (past the small stagger delay) still prewarm,
  // which is all this optimization was ever meant to cover.
  Timer? _prewarmTimer;

  @override
  void initState() {
    super.initState();
    // PERF FIX ("first YT song tap always takes 2-8s"): prewarmYtStream()
    // already existed but only ever fired for the next 3-5 songs in an
    // ACTIVE queue — a song sitting on Home/Search/Library that the user
    // hasn't tapped yet got zero head start. ListView/SliverList builders
    // only construct tiles that are actually near-visible (visible +
    // cacheExtent), so this tile's own initState firing is already a
    // reliable, zero-extra-dependency signal that it's about to be seen —
    // no need for a separate VisibilityDetector package.
    //
    // This calls the Worker's /api/prewarm endpoint, which resolves the
    // YouTube stream URL and caches it server-side (KV) — the actual CPU-
    // heavy work (InnerTube page fetch + cipher/nsig deobfuscation) runs
    // on Cloudflare's infra, NOT on-device. So this costs the phone
    // nothing but one fire-and-forget HTTP call — zero local CPU, zero
    // heat contribution — while still turning a cold tap-to-play resolve
    // into a fast KV-HIT by the time the user actually taps.
    //
    // Staggered by a small per-tile delay so a fast scroll through many
    // tiles doesn't fire a burst of simultaneous Worker requests in the
    // same frame — the delay only spaces out the fire-and-forget HTTP
    // calls, no extra work happens on-device either way.
    if (widget.song.source == SongSource.youtube) {
      final delayMs = 120 + (widget.song.id.hashCode.abs() % 280);
      _prewarmTimer = Timer(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        ApiService.prewarmYtStream(widget.song);
      });
    }
  }

  @override
  void dispose() {
    // Cancel any pending prewarm call — if this tile scrolled out of view
    // (and got destroyed by the list's builder) before its stagger delay
    // fired, the request never goes out at all. See _prewarmTimer doc
    // comment above.
    _prewarmTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleTap(BuildContext context) async {
    if (_isTapping) return;
    _isTapping = true;
    AurumHaptics.light();
    try {
      // SPOTIFY-STYLE FIX ("kahi se bhi full player na khule, tap se sirf
      // mini player aaye, user chahe to khud full player khole"): tapping
      // a song now only starts playback — the mini player appearing IS
      // the tap feedback. pushFullPlayer(context) call removed from here
      // entirely; opening the full player is now exclusively a deliberate
      // action (tapping the mini player itself, in mini_player.dart).
      // History save moved to PlayerProvider._onSongChanged — fires only
      // once the native engine confirms this song actually started
      // playing, instead of on every tap regardless of stream success.
      context.read<PlayerProvider>().playSong(
            widget.song,
            queue: widget.queue ?? [widget.song],
            index: widget.index ?? 0,
            curatedQueue: widget.curatedQueue,
          ).catchError((e) {
        debugPrint('[SongTile] playSong error: $e');
      });
    } finally {
      // FIX (premium-feel latency) — this used to be a flat 800ms before
      // the tile could be tapped again, on every single tap, regardless
      // of how quickly navigation actually completed. playSong() itself
      // is fire-and-forget here (not awaited — see .catchError above), so
      // this delay had no relationship to how long the actual song
      // resolve takes; it was purely an arbitrary number blocking re-taps
      // on THIS tile. The real "don't let a stale tap's background work
      // clobber a newer one" protection already lives in
      // PlayerProvider._uiPlaySession (see player_provider.dart), so this
      // only ever needed to be long enough to swallow an accidental
      // double-tap/double-fire from the same physical touch — 250ms is
      // comfortably above that and far below the old 800ms, so rapid
      // deliberate browsing across different tiles no longer feels sticky.
      await Future.delayed(const Duration(milliseconds: 250));
      if (mounted) _isTapping = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // FIX: use select instead of watch — only rebuilds THIS tile when ITS
    // song's liked state changes, not when any favorite changes anywhere.
    final isLiked = context.select<FavoritesProvider, bool>(
      (fav) => fav.isFavorite(widget.song.id),
    );
    final isCurrentSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == widget.song.id,
    );
    final isActuallyPlaying = context.select<PlayerProvider, bool>(
      (p) => p.isPlaying,
    );

    // PERF: RepaintBoundary isolates each tile into its own compositor
    // layer. Without it, every tile in a ListView shares a paint layer
    // with its siblings — so even though context.select() above already
    // limits which tiles *rebuild*, Flutter can still end up re-painting
    // a wider region than just the one tile that changed (e.g. during
    // fast scroll, or when a neighboring tile's like-button animates).
    // A dedicated layer per tile keeps each row's paint cost isolated to
    // itself, which matters most exactly where the CPU/GPU is weakest —
    // long lists on lower-end devices.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: InkWell(
      onTap: () => _handleTap(context),
      onLongPress: widget.onLongPressOverride ?? () => _showOptions(context),
      borderRadius: BorderRadius.circular(8),
      // FIX ("song tap pe ek grey/white layer ban jaata hai, cold start
      // pe zyada dikhta hai" — Library/Recently Played, confirmed via
      // screenshot): InkWell had no explicit splash/highlight color, so
      // it fell back to Flutter's unthemed Material default — a flat
      // grey/white overlay unrelated to the app's actual dark/light
      // theme. On a normal tap that's a quick, barely-noticeable ripple,
      // but on a slow cold start (song resolve + provider rebuilds all
      // competing for the same frame budget), the fade-out can visibly
      // linger or the tile can rebuild mid-splash — reading exactly like
      // the reported "grey/white layer stuck over the tile." Explicit,
      // low-opacity, theme-correct colors mean even a lingering splash
      // can never read as a stray wrong-colored wash.
      splashColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
      highlightColor: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.04),
      child: Padding(
        // SPACING FIX ("thumbnail bahut chhota dikhta hai" — reference:
        // the artist "Top songs" list, where each row's cover art reads
        // as noticeably bigger/more premium than a compact 50px chip):
        // opened vertical padding 8→10 so the bigger 64px cover below
        // doesn't feel cramped between rows.
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (widget.showIndex) ...[
              SizedBox(
                width: 28,
                child: isCurrentSong
                    ? const SizedBox.shrink()
                    : Text(
                        '${widget.displayIndex ?? (widget.index ?? 0) + 1}',
                        style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
              ),
              const SizedBox(width: 8),
            ],
            // Echo Nightly-style depth stack behind the cover, with the
            // live 3-bar equalizer badge centered on top when this tile
            // is the currently-playing song (replaces the old bare-index-
            // column wave — the badge now lives directly on the artwork,
            // same as Echo's isPlaying overlay on item_shelf_media_cover).
            // SIZE FIX ("thumbnail bahut chhota dikhta hai" then later
            // "bs thoda sa aur chhota, jyada bada ho gaya tha" — two
            // rounds of feedback): first bumped 50→64, then dialed back
            // slightly to 58 once 64 read as a bit too large in practice.
            // Still a clearly premium-sized cover everywhere this tile is
            // used (Liked Songs, Library, Search, Artist page, Mix
            // screen), just not oversized.
            AurumStackedArtwork(
              url: widget.song.artworkUrl,
              size: 58,
              borderRadius: 10,
              showNowPlaying: isCurrentSong,
              isPlaying: isActuallyPlaying,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.title,
                    style: TextStyle(
                      color: isCurrentSong ? AurumTheme.accentOf(context) : AurumTheme.textPrimaryOf(context),
                      fontSize: 16,
                      fontWeight: isCurrentSong ? FontWeight.w700 : FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.song.artist,
                    style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Heart button — pop + sparkle burst on like, wobble on unlike
            AurumLikeButton(
              isLiked: isLiked,
              size: 19,
              unlikedColor: AurumTheme.textMutedOf(context),
              onTap: () => context.read<FavoritesProvider>().toggleFavorite(widget.song),
            ),
            const SizedBox(width: 4),
            if (widget.song.durationString.isNotEmpty)
              Text(
                widget.song.durationString,
                style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12),
              ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _showOptions(context),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.more_vert_rounded, color: AurumTheme.textMutedOf(context), size: 18),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _showOptions(BuildContext context) {
    // Shared SimpMusic-style sheet (lib/widgets/aurum_song_options_sheet.dart)
    showAurumSongOptions(context, widget.song);
  }
}
