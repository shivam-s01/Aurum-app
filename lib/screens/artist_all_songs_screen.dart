// =============================================================================
// FILE: lib/screens/artist_all_songs_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Full "all songs" page for an artist — opened from the arrow
// icon next to ArtistScreen's "Popular" header. Shows the artist's complete
// topSongs list (already fetched by ArtistScreen — nothing is re-fetched
// here), no 1/2/3 index numbers, no artificial preview cap. Same
// scaffold/SliverAppBar/MiniPlayerSlot/cacheExtent treatment as every other
// top-level list screen in the app (LikedScreen, LibraryScreen) so this
// reads as a first-class screen, not a stripped-down afterthought.
// =============================================================================

import 'package:flutter/material.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

class ArtistAllSongsScreen extends StatelessWidget {
  final String artistName;
  final List<Song> songs;

  const ArtistAllSongsScreen({
    super.key,
    required this.artistName,
    required this.songs,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — same reasoning as every
      // other screen pushed on top of MainShell (LikedScreen, ArtistScreen
      // itself): without this the mini player would vanish the moment the
      // user opens this list.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        // PERF (matches artist_screen.dart/home_screen.dart's identical
        // fix): default Sliver cacheExtent (250px) is too small once this
        // list can run into the hundreds of tracks — a fast fling would
        // tear down and rebuild tiles just outside that tiny buffer,
        // showing blank/jank frames. 1200 keeps scrolling smooth even on
        // an artist with a huge catalog.
        cacheExtent: 1200,
        slivers: [
          SliverAppBar(
            expandedHeight: 96,
            floating: true,
            snap: true,
            pinned: true,
            backgroundColor: AurumTheme.bgOf(context),
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded,
                  color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () {
                AurumHaptics.light();
                Navigator.pop(context);
              },
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 20, 16),
              title: Text(
                artistName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  l10n.asPopular,
                  style:
                      TextStyle(color: AurumTheme.textMutedOf(context)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  // No showIndex/displayIndex — plain artwork + title/
                  // artist rows only, exactly like every other bare song
                  // list in the app (Liked Songs, playlists).
                  (context, i) => SongTile(
                    song: songs[i],
                    queue: songs,
                    index: i,
                    curatedQueue: true,
                  ),
                  childCount: songs.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
