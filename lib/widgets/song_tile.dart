import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
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
    final lib = context.watch<LibraryProvider>();
    final isCurrentSong =
        player.currentSong?.id == song.id;
    final isFav = lib.isFavorite(song.id);

    return InkWell(
      onTap: () {
        player.playSong(
          song,
          queue: queue ?? [song],
          index: index ?? 0,
        );
        // Track recently played
        lib.addToRecentlyPlayed(song);
      },
      onLongPress: () =>
          _showOptions(context, player, lib, isFav),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Index or equalizer
            if (showIndex) ...[
              SizedBox(
                width: 28,
                child: isCurrentSong
                    ? const Icon(Icons.equalizer_rounded,
                        color: AurumTheme.gold, size: 18)
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
            // Artwork
            AurumArtwork(
                url: song.artworkUrl,
                size: 50,
                borderRadius: 10),
            const SizedBox(width: 12),
            // Title + Artist
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      color: isCurrentSong
                          ? AurumTheme.gold
                          : AurumTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: isCurrentSong
                          ? FontWeight.w600
                          : FontWeight.w500,
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
            // Duration
            if (song.durationString.isNotEmpty)
              Text(
                song.durationString,
                style: const TextStyle(
                    color: AurumTheme.textMuted,
                    fontSize: 12),
              ),
            const SizedBox(width: 4),
            // Favorite indicator
            if (isFav) ...[
              const Icon(Icons.favorite_rounded,
                  color: Colors.redAccent, size: 14),
              const SizedBox(width: 4),
            ],
            // More options
            GestureDetector(
              onTap: () => _showOptions(
                  context, player, lib, isFav),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.more_vert_rounded,
                    color: AurumTheme.textMuted, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext context,
      PlayerProvider player, LibraryProvider lib,
      bool isFav) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SongOptionsSheet(
        song: song,
        player: player,
        lib: lib,
        isFav: isFav,
      ),
    );
  }
}

class _SongOptionsSheet extends StatelessWidget {
  final Song song;
  final PlayerProvider player;
  final LibraryProvider lib;
  final bool isFav;

  const _SongOptionsSheet({
    required this.song,
    required this.player,
    required this.lib,
    required this.isFav,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AurumTheme.bgSurface,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Song info header
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(
                      url: song.artworkUrl,
                      size: 52,
                      borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: const TextStyle(
                          color: AurumTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        song.artist,
                        style: const TextStyle(
                            color:
                                AurumTheme.textSecondary,
                            fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(
              color: AurumTheme.divider, height: 16),
          // Options
          _option(
            context,
            isFav
                ? Icons.favorite_rounded
                : Icons.favorite_outline_rounded,
            isFav
                ? 'Remove from Favourites'
                : 'Add to Favourites',
            iconColor: isFav ? Colors.redAccent : null,
            () {
              lib.toggleFavorite(song);
              Navigator.pop(context);
            },
          ),
          _option(context, Icons.queue_music_rounded,
              'Add to Queue', () {
            player.addToQueue(song);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:
                    Text('Added "${song.title}" to queue'),
                backgroundColor: AurumTheme.bgElevated,
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(10)),
              ),
            );
          }),
          _option(context, Icons.skip_next_rounded,
              'Play Next', () {
            player.playNext(song);
            Navigator.pop(context);
          }),
          _option(context, Icons.playlist_add_rounded,
              'Add to Playlist', () {
            Navigator.pop(context);
            _showPlaylistPicker(context, lib);
          }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _option(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? iconColor,
  }) {
    return ListTile(
      leading: Icon(icon,
          color: iconColor ?? AurumTheme.gold, size: 22),
      title: Text(
        label,
        style: const TextStyle(
            color: AurumTheme.textPrimary, fontSize: 14),
      ),
      onTap: onTap,
      dense: true,
    );
  }

  void _showPlaylistPicker(
      BuildContext context, LibraryProvider lib) {
    final playlists = lib.playlists;
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AurumTheme.bgSurface,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Add to Playlist',
            style: TextStyle(
              color: AurumTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No playlists yet. Create one in Library.',
                style: TextStyle(
                    color: AurumTheme.textMuted,
                    fontSize: 13),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...playlists.keys.map(
              (name) => ListTile(
                leading: const Icon(
                    Icons.queue_music_rounded,
                    color: AurumTheme.gold,
                    size: 20),
                title: Text(
                  name,
                  style: const TextStyle(
                      color: AurumTheme.textPrimary,
                      fontSize: 14),
                ),
                onTap: () {
                  lib.addToPlaylist(name, song);
                  Navigator.pop(context);
                },
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
