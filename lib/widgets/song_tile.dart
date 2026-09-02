import 'dart:async';
import '../utils/aurum_transitions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../theme/aurum_theme.dart';
import '../screens/library_screen.dart' show showAddToPlaylistSheet;
import '../screens/full_player_screen.dart' show shareSong;
import '../screens/artist_screen.dart';
import '../screens/album_screen.dart';
import '../services/api_service.dart';
import 'aurum_artwork.dart';
import 'aurum_like_button.dart';
import 'aurum_stacked_artwork.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_motion.dart';

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

  const SongTile({
    super.key,
    required this.song,
    this.queue,
    this.index,
    this.showIndex = false,
    this.displayIndex,
    this.curatedQueue = false,
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
      onLongPress: () => _showOptions(context),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
            AurumStackedArtwork(
              url: widget.song.artworkUrl,
              size: 50,
              borderRadius: 8,
              showNowPlaying: isCurrentSong,
              isPlaying: isActuallyPlaying,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.title,
                    style: TextStyle(
                      color: isCurrentSong ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
                      fontSize: 14,
                      fontWeight: isCurrentSong ? FontWeight.w600 : FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.song.artist,
                    style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Heart button — pop + sparkle burst on like, wobble on unlike
            AurumLikeButton(
              isLiked: isLiked,
              size: 18,
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
    // FIX: capture rootContext BEFORE sheet opens (sheet has its own context)
    final rootContext = context;
    // FIX: routed through showAurumModalBottomSheet (lib/utils/aurum_sheet.dart)
    // so the scrim always has an explicit barrierColor.
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      // FIX: don't pass stale player/fav — sheet reads providers itself
      builder: (_) => _SongOptionsSheet(song: widget.song, rootContext: rootContext),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _SongOptionsSheet extends StatefulWidget {
  final Song song;
  final BuildContext rootContext;

  // FIX: removed stale player/fav args — sheet reads live from providers
  const _SongOptionsSheet({required this.song, required this.rootContext});

  @override
  State<_SongOptionsSheet> createState() => _SongOptionsSheetState();
}

class _SongOptionsSheetState extends State<_SongOptionsSheet> {
  // FIX: use rootContext for snack so post-dismiss context is never stale
  void _snack(String msg) {
    Navigator.pop(context);
    ScaffoldMessenger.of(widget.rootContext).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(widget.rootContext),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    // FIX: read live providers inside build — not stale snapshots from parent
    final player = context.read<PlayerProvider>();
    final fav = context.watch<FavoritesProvider>();
    final isLiked = fav.isFavorite(song.id);

    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Song header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                AurumArtwork(url: song.artworkUrl, size: 56, borderRadius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song.artist,
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (song.album.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          song.album,
                          style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                // Like button in header — pop + sparkle burst on like
                AnimatedContainer(
                  duration: AurumMotion.durationOrZero(AurumMotion.medium1),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isLiked
                        ? const Color(0xFFE1306C).withValues(alpha: 0.12)
                        : AurumTheme.bgSurfaceOf(context),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AurumLikeButton(
                      isLiked: isLiked,
                      size: 20,
                      unlikedColor: AurumTheme.textMutedOf(context),
                      onTap: () => fav.toggleFavorite(song),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(color: AurumTheme.dividerOf(context), height: 1),

          // Options grid
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.8,
              children: [
                _GridOption(
                  icon: Icons.play_arrow_rounded,
                  label: 'Play',
                  color: AurumTheme.gold,
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(player.playSong(song));
                  },
                ),
                _GridOption(
                  icon: Icons.skip_next_rounded,
                  label: 'Play Next',
                  color: AurumTheme.gold,
                  onTap: () {
                    unawaited(player.playNext(song));
                    _snack('Playing "${song.title}" next');
                  },
                ),
                _GridOption(
                  icon: Icons.queue_music_rounded,
                  label: 'Add to Queue',
                  color: Colors.purpleAccent,
                  onTap: () {
                    unawaited(player.addToQueue(song));
                    _snack('Added to queue');
                  },
                ),
                _GridOption(
                  icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  label: isLiked ? 'Liked' : 'Like',
                  color: const Color(0xFFE1306C),
                  onTap: () {
                    // FIX: toggle first, THEN check updated state for correct message
                    fav.toggleFavorite(song);
                    final nowLiked = fav.isFavorite(song.id);
                    _snack(nowLiked ? 'Added to Liked' : 'Removed from Liked');
                  },
                ),
                _GridOption(
                  icon: Icons.playlist_add_rounded,
                  label: 'Save to Playlist',
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(context);
                    showAddToPlaylistSheet(widget.rootContext, song);
                  },
                ),
                _GridOption(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  color: Colors.greenAccent,
                  onTap: () {
                    Navigator.pop(context);
                    shareSong(context, song);
                  },
                ),
              ],
            ),
          ),

          // Artist / Album chips
          if (song.artist.isNotEmpty && song.artist != 'Unknown') ...[
            Divider(color: AurumTheme.dividerOf(context), height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('GO TO',
                    style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4)),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  ...song.artist.split(',').take(3).map((a) {
                    final trimmed = a.trim();
                    // FIX ("search mein song ka artist bhi aana chahiye, tap
                    // karne layak"): when this song already carries a known
                    // YouTube artist channelId (set by _searchYtMusicDirect's
                    // browseEndpoint parse), pass it straight through as a
                    // pre-resolved 'yt_<channelId>' id — ArtistScreen opens
                    // the real channel immediately, zero extra name-search
                    // round-trip. Only the FIRST chip (the song's primary
                    // artist) gets this fast path, since artistChannelId is
                    // only ever populated for the primary artist; any
                    // additional featured-artist chips still resolve by name
                    // through the normal yt-then-saavn fallback.
                    final isPrimary = song.artist.split(',').first.trim() == trimmed;
                    final fastId = (isPrimary && song.artistChannelId != null)
                        ? 'yt_${song.artistChannelId}'
                        : null;
                    return _ArtistChip(
                      name: trimmed,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          widget.rootContext,
                          AurumDepthRoute(
                            builder: (_) => ArtistScreen(
                              artistId: fastId,
                              artistName: trimmed,
                            ),
                          ),
                        );
                      },
                    );
                  }),
                  if (song.album.isNotEmpty)
                    _AlbumChip(
                      albumName: song.album,
                      rootContext: widget.rootContext,
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

// ── Grid option tile ──────────────────────────────────────────────────────────
class _GridOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GridOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.18), width: 0.8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 19),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Artist / Album chip ───────────────────────────────────────────────────────
class _AlbumChip extends StatefulWidget {
  final String albumName;
  final BuildContext rootContext;
  const _AlbumChip({required this.albumName, required this.rootContext});

  @override
  State<_AlbumChip> createState() => _AlbumChipState();
}

class _AlbumChipState extends State<_AlbumChip> {
  bool _resolving = false;

  Future<void> _open() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      // FIX ("YouTube se play kiya to album/artist chip work nahi karta"):
      // searchAlbumByName only ever hit Saavn's search endpoint, so a song
      // streamed from YouTube — whose album name usually isn't in Saavn's
      // catalog at all — always failed to resolve, even with network up.
      // searchAlbums() already races Saavn AND YT Music and returns
      // BrowseAlbum.collectionId (MPRE-prefixed for YT, bare id for Saavn),
      // exactly the shape fetchAlbumSongs()/AlbumScreen already know how to
      // route by prefix — so just reuse it and pick the closest name match.
      final lower = widget.albumName.trim().toLowerCase();
      final results = await ApiService.searchAlbums(widget.albumName, limit: 5);
      final match = results.isEmpty
          ? null
          : results.firstWhere(
              (a) => a.name.trim().toLowerCase() == lower,
              orElse: () => results.first,
            );
      final albumId = match?.collectionId;
      if (!mounted) return;
      if (albumId == null || albumId.isEmpty) {
        setState(() => _resolving = false);
        ScaffoldMessenger.of(widget.rootContext).showSnackBar(SnackBar(
          content: Text('Couldn\'t find "${widget.albumName}"'),
          backgroundColor: AurumTheme.bgElevatedOf(widget.rootContext),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));
        return;
      }
      Navigator.pop(context);
      Navigator.push(
        widget.rootContext,
        AurumDepthRoute(
          builder: (_) => AlbumScreen(
            albumId: albumId,
            albumName: widget.albumName,
            artworkUrl: match?.artworkUrl ?? '',
          ),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _resolving
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: AurumTheme.gold,
                  ),
                )
              : Icon(Icons.album_rounded, size: 14, color: AurumTheme.gold),
          const SizedBox(width: 6),
          Text(
            widget.albumName,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }
}

class _ArtistChip extends StatelessWidget {
  final String name;
  final IconData icon;
  final VoidCallback? onTap;

  const _ArtistChip({
    required this.name,
    this.onTap,
    this.icon = Icons.person_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: AurumTheme.gold),
          const SizedBox(width: 6),
          Text(
            name,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }
}
