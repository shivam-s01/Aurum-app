// =============================================================================
// FILE: lib/screens/mix_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Full-screen "album-style" page for the Home screen's curated
//   playlists (Trending Now, Party Anthems, 90s Bollywood, etc), Spotify-
//   style — big header art, Play + Save row, then the song list.
//
//   Mirrors AlbumScreen's visual design exactly, but takes an already-fetched
//   `songs` list instead of an albumId to fetch by — these are client-side
//   curated queries (see _kCuratedPlaylists / _PlaylistCard in
//   home_screen.dart), not real JioSaavn album IDs, so there's nothing to
//   re-fetch from here.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/saved_mixes_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_save_button.dart';
import '../widgets/song_tile.dart';
import '../l10n/generated/app_localizations.dart';

class MixScreen extends StatelessWidget {
  final String mixId;
  final String mixName;
  final String artworkUrl;
  final String emoji;
  final List<Song> songs;

  const MixScreen({
    super.key,
    required this.mixId,
    required this.mixName,
    required this.artworkUrl,
    required this.emoji,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AurumTheme.bgOf(context),
            iconTheme: const IconThemeData(color: Colors.white),
            expandedHeight: 280,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  artworkUrl.isNotEmpty
                      ? AurumArtwork(url: artworkUrl, size: 600, borderRadius: 0)
                      : Container(color: AurumTheme.bgCardOf(context)),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.1),
                          Colors.black.withOpacity(0.5),
                          AurumTheme.bgOf(context),
                        ],
                        stops: const [0.0, 0.6, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    right: 16,
                    child: Text(emoji,
                        style: const TextStyle(
                          fontSize: 26,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                        )),
                  ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 20,
                    child: Text(
                      mixName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: AurumPressable(
                      scaleAmount: 0.95,
                      onTap: songs.isEmpty
                          ? null
                          : () => player.playSong(songs.first,
                              queue: songs, index: 0),
                      child: Container(
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: songs.isEmpty
                              ? AurumTheme.gold.withOpacity(0.4)
                              : AurumTheme.gold,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.play_arrow_rounded,
                                color: Colors.black),
                            const SizedBox(width: 6),
                            Text(l10n.commonPlay,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                )),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Consumer<SavedMixesProvider>(
                    builder: (context, savedMixes, _) {
                      final saved = savedMixes.isSaved(mixId);
                      return AurumSaveButton(
                        saved: saved,
                        onTap: () => savedMixes.toggleSave(
                          mixId: mixId,
                          name: mixName,
                          artworkUrl: artworkUrl,
                          emoji: emoji,
                          songs: songs,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(l10n.albumNoSongsFound,
                    style:
                        TextStyle(color: AurumTheme.textMutedOf(context))),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => SongTile(
                  song: songs[i],
                  queue: songs,
                  index: i,
                  showIndex: true,
                  displayIndex: i + 1,
                ),
                childCount: songs.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
