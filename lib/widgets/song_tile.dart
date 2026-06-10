import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
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

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final fav = context.watch<FavoritesProvider>();
    final isCurrentSong = player.currentSong?.id == song.id;
    final isLiked = fav.isFavorite(song.id);

    return InkWell(
      onTap: () => player.playSong(song, queue: queue ?? [song], index: index ?? 0),
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
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SongOptionsSheet(song: song, player: player, fav: fav),
    );
  }
}

class _SongOptionsSheet extends StatelessWidget {
  final Song song;
  final PlayerProvider player;
  final FavoritesProvider fav;

  const _SongOptionsSheet({required this.song, required this.player, required this.fav});

  @override
  Widget build(BuildContext context) {
    final isLiked = fav.isFavorite(song.id);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: AurumTheme.bgSurfaceOf(context), borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                AurumArtwork(url: song.artworkUrl, size: 48, borderRadius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontWeight: FontWeight.w600, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(song.artist, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AurumTheme.dividerOf(context), height: 16),
          _option(context, isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            isLiked ? 'Remove from Liked' : 'Add to Liked',
            isLiked ? const Color(0xFFE1306C) : null,
            () { fav.toggleFavorite(song); Navigator.pop(context); }),
          _option(context, Icons.queue_music_rounded, 'Add to Queue', null, () {
            player.addToQueue(song);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Added "${song.title}" to queue'),
              backgroundColor: AurumTheme.bgElevatedOf(context),
              duration: const Duration(seconds: 2),
            ));
          }),
          _option(context, Icons.skip_next_rounded, 'Play Next', null, () {
            player.playNext(song);
            Navigator.pop(context);
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _option(BuildContext context, IconData icon, String label, Color? iconColor, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AurumTheme.gold, size: 22),
      title: Text(label, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14)),
      onTap: onTap,
      dense: true,
    );
  }
}
