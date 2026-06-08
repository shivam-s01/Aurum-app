import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
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
    final isCurrentSong = player.currentSong?.id == song.id;

    return InkWell(
      onTap: () {
        player.playSong(
          song,
          queue: queue ?? [song],
          index: index ?? 0,
        );
      },
      onLongPress: () => _showOptions(context, player),
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
                        style: const TextStyle(
                          color: AurumTheme.textMuted,
                          fontSize: 13,
                        ),
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
                      color: isCurrentSong ? AurumTheme.gold : AurumTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: isCurrentSong ? FontWeight.w600 : FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    style: const TextStyle(
                      color: AurumTheme.textSecondary,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (song.durationString.isNotEmpty)
              Text(
                song.durationString,
                style: const TextStyle(
                  color: AurumTheme.textMuted,
                  fontSize: 12,
                ),
              ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _showOptions(context, player),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.more_vert_rounded, color: AurumTheme.textMuted, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext context, PlayerProvider player) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SongOptionsSheet(song: song, player: player),
    );
  }
}

class _SongOptionsSheet extends StatelessWidget {
  final Song song;
  final PlayerProvider player;

  const _SongOptionsSheet({required this.song, required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AurumTheme.bgSurface,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AurumArtwork(url: song.artworkUrl, size: 48, borderRadius: 8),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title,
                        style: const TextStyle(
                          color: AurumTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(song.artist,
                        style: const TextStyle(color: AurumTheme.textSecondary, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AurumTheme.divider, height: 16),
          _option(context, Icons.queue_music_rounded, 'Add to Queue', () {
            player.addToQueue(song);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Added "${song.title}" to queue'),
                backgroundColor: AurumTheme.bgElevated,
                duration: const Duration(seconds: 2),
              ),
            );
          }),
          _option(context, Icons.skip_next_rounded, 'Play Next', () {
            player.playNext(song);
            Navigator.pop(context);
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _option(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: AurumTheme.gold, size: 22),
      title: Text(label, style: const TextStyle(color: AurumTheme.textPrimary, fontSize: 14)),
      onTap: onTap,
      dense: true,
    );
  }
}
