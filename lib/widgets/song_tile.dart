import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/recently_played_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';

class SongTile extends StatelessWidget {
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

  // Debounce: prevent rapid double-taps from pushing multiple FullPlayerScreens
  static bool _isTapping = false;

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final fav = context.watch<FavoritesProvider>();
    final isCurrentSong = context.select<PlayerProvider, bool>((p) => p.currentSong?.id == song.id);
    final isLiked = fav.isFavorite(song.id);

    return InkWell(
      onTap: () async {
        if (_isTapping) return;
        _isTapping = true;
        context.read<RecentlyPlayedProvider>().addPlay(song);
        player.playSong(song, queue: queue ?? [song], index: index ?? 0);
        await Future.delayed(const Duration(milliseconds: 300));
        _isTapping = false;
      },
      onLongPress: () => _showOptions(context, player, fav),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (showIndex) ...[
              SizedBox(
                width: 28,
                child: isCurrentSong
                    ? const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 18)
                    : Text(
                        '${displayIndex ?? (index ?? 0) + 1}',
                        style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
              ),
              const SizedBox(width: 8),
            ],
            AurumArtwork(url: song.artworkUrl, size: 50, borderRadius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
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
                    song.artist,
                    style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // Heart button
            GestureDetector(
              onTap: () => fav.toggleFavorite(song),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: Icon(
                  isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  key: ValueKey(isLiked),
                  color: isLiked ? const Color(0xFFE1306C) : AurumTheme.textMutedOf(context),
                  size: 18,
                ),
              ),
            ),
            const SizedBox(width: 4),
            if (song.durationString.isNotEmpty)
              Text(song.durationString, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _showOptions(context, player, fav),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.more_vert_rounded, color: AurumTheme.textMutedOf(context), size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext context, PlayerProvider player, FavoritesProvider fav) {
    final rootContext = context;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _SongOptionsSheet(song: song, player: player, fav: fav, rootContext: rootContext),
    );
  }
}

class _SongOptionsSheet extends StatefulWidget {
  final Song song;
  final PlayerProvider player;
  final FavoritesProvider fav;
  final BuildContext rootContext;

  const _SongOptionsSheet({required this.song, required this.player, required this.fav, required this.rootContext});

  @override
  State<_SongOptionsSheet> createState() => _SongOptionsSheetState();
}

class _SongOptionsSheetState extends State<_SongOptionsSheet> {
  void _snack(String msg) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(context),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _comingSoon(String feature) => _snack('$feature coming soon!');

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final player = widget.player;
    final fav = widget.fav;
    final isLiked = fav.isFavorite(song.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Drag handle ──
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // ── Song header ──
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
                // Like button in header
                GestureDetector(
                  onTap: () {
                    fav.toggleFavorite(song);
                    setState(() {});
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: isLiked
                          ? const Color(0xFFE1306C).withOpacity(0.12)
                          : AurumTheme.bgSurfaceOf(context),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      color: isLiked ? const Color(0xFFE1306C) : AurumTheme.textMutedOf(context),
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(color: AurumTheme.dividerOf(context), height: 1),

          // ── Options grid (2 columns) ──
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
                    widget.rootContext.read<RecentlyPlayedProvider>().addPlay(song);
                    player.playSong(song);
                  },
                ),
                _GridOption(
                  icon: Icons.skip_next_rounded,
                  label: 'Play Next',
                  color: AurumTheme.gold,
                  onTap: () {
                    player.playNext(song);
                    _snack('Playing "${song.title}" next');
                  },
                ),
                _GridOption(
                  icon: Icons.queue_music_rounded,
                  label: 'Add to Queue',
                  color: Colors.purpleAccent,
                  onTap: () {
                    player.addToQueue(song);
                    _snack('Added to queue');
                  },
                ),
                _GridOption(
                  icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  label: isLiked ? 'Liked' : 'Like',
                  color: const Color(0xFFE1306C),
                  onTap: () {
                    fav.toggleFavorite(song);
                    _snack(isLiked ? 'Removed from Liked' : 'Added to Liked');
                  },
                ),
                _GridOption(
                  icon: Icons.playlist_add_rounded,
                  label: 'Save to Playlist',
                  color: Colors.blueAccent,
                  onTap: () => _comingSoon('Save to Playlist'),
                ),
                _GridOption(
                  icon: Icons.bookmark_border_rounded,
                  label: 'Save to Library',
                  color: Colors.teal,
                  onTap: () => _comingSoon('Save to Library'),
                ),
                _GridOption(
                  icon: Icons.radio_rounded,
                  label: 'Radio',
                  color: Colors.orange,
                  onTap: () => _comingSoon('Radio'),
                ),
                _GridOption(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  color: Colors.greenAccent,
                  onTap: () => _comingSoon('Share'),
                ),
              ],
            ),
          ),

          // ── Artist / Album chips ──
          if (song.artist.isNotEmpty && song.artist != 'Unknown') ...[
            Divider(color: AurumTheme.dividerOf(context), height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('GO TO', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  // Each artist as a chip
                  ...song.artist.split(',').take(3).map((a) => _ArtistChip(
                    name: a.trim(),
                    onTap: () => _comingSoon('Artist: ${a.trim()}'),
                  )),
                  if (song.album.isNotEmpty)
                    _ArtistChip(
                      name: song.album,
                      icon: Icons.album_rounded,
                      onTap: () => _comingSoon('Album: ${song.album}'),
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

// ── Grid option tile ──────────────────────────────────────────────────────
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

// ── Artist / Album chip ───────────────────────────────────────────────────
class _ArtistChip extends StatelessWidget {
  final String name;
  final IconData icon;
  final VoidCallback onTap;

  const _ArtistChip({
    required this.name,
    required this.onTap,
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
