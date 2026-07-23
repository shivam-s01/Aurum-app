import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../theme/aurum_theme.dart';
import '../screens/library_screen.dart' show showAddToPlaylistSheet;
import '../screens/full_player_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/album_screen.dart';
import '../services/api_service.dart';
import 'aurum_artwork.dart';
import 'aurum_like_button.dart';
import 'aurum_equalizer_bars.dart';

class SongTile extends StatefulWidget {
  final Song song;
  final List<Song>? queue;
  final int? index;
  final bool showIndex;
  final int? displayIndex;

  const SongTile({
    super.key,
    required this.song,
    this.queue,
    this.index,
    this.showIndex = false,
    this.displayIndex,
  });

  @override
  State<SongTile> createState() => _SongTileState();
}

class _SongTileState extends State<SongTile> {
  // FIX: per-instance debounce (was static — one tile blocked ALL tiles)
  bool _isTapping = false;

  Future<void> _handleTap(BuildContext context) async {
    if (_isTapping) return;
    _isTapping = true;
    HapticFeedback.lightImpact();
    try {
      // History save moved to PlayerProvider._onSongChanged — fires only
      // once the native engine confirms this song actually started
      // playing, instead of on every tap regardless of stream success.
      context.read<PlayerProvider>().playSong(
            widget.song,
            queue: widget.queue ?? [widget.song],
            index: widget.index ?? 0,
          ).catchError((e) {
        debugPrint('[SongTile] playSong error: $e');
      });
      if (mounted) {
        Navigator.of(context).push(
          PageRouteBuilder(
            // FIX: opaque:false told Flutter that SearchScreen (or whatever
            // screen this tile lives on — Home, Library, Search results,
            // live search) might still be partially visible underneath,
            // so Flutter stopped fully repainting it while FullPlayerScreen
            // was open. On pop, the screen's last (stale) frame stayed
            // frozen on screen — showing as a blank white/black page until
            // some unrelated state change forced a rebuild. This is the
            // exact bug that made the search screen go blank after tapping
            // a live/normal search result. FullPlayerScreen already paints
            // its own full opaque background (_BgLayer in
            // full_player_screen.dart), so opaque:true changes nothing
            // visually and fully fixes the freeze.
            opaque: true,
            pageBuilder: (_, __, ___) => const FullPlayerScreen(),
            transitionsBuilder: (_, anim, __, child) => SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                  .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: child,
            ),
            transitionDuration: const Duration(milliseconds: 380),
            // FIX ("back feels stuck/not smooth"): matched to the forward
            // duration above — was 300ms vs 380ms open.
            reverseTransitionDuration: const Duration(milliseconds: 380),
          ),
        );
      }
    } finally {
      await Future.delayed(const Duration(milliseconds: 800));
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
    return RepaintBoundary(
      child: InkWell(
      onTap: () => _handleTap(context),
      onLongPress: () => _showOptions(context),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (widget.showIndex) ...[
              SizedBox(
                width: 28,
                child: isCurrentSong
                    ? AurumEqualizerBars(
                        playing: isActuallyPlaying,
                        color: AurumTheme.gold,
                        size: 18,
                      )
                    : Text(
                        '${widget.displayIndex ?? (widget.index ?? 0) + 1}',
                        style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
              ),
              const SizedBox(width: 8),
            ],
            AurumArtwork(url: widget.song.artworkUrl, size: 50, borderRadius: 8),
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
    showModalBottomSheet(
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
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isLiked
                        ? const Color(0xFFE1306C).withOpacity(0.12)
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
                  ...song.artist.split(',').take(3).map((a) => _ArtistChip(
                        name: a.trim(),
                        onTap: () {
                          Navigator.pop(context);
                          Navigator.push(
                            widget.rootContext,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ArtistScreen(artistName: a.trim()),
                            ),
                          );
                        },
                      )),
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
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.18), width: 0.8),
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
      final albumId = await ApiService.searchAlbumByName(widget.albumName);
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
        MaterialPageRoute(
          builder: (_) => AlbumScreen(
            albumId: albumId,
            albumName: widget.albumName,
            artworkUrl: '',
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
