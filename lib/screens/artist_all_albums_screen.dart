// =============================================================================
// FILE: lib/screens/artist_all_albums_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Full "all albums" page for an artist — opened from the arrow
// icon next to ArtistScreen's "Albums" header. Shows the artist's complete
// topAlbums list (already fetched by ArtistScreen — nothing is re-fetched
// here) as a proper 2-column grid, same treatment as LibraryScreen's saved
// albums grid, so this reads as a genuine top-level screen rather than a
// cut-down inline row stretched vertically.
// =============================================================================

import 'package:flutter/material.dart';
import '../models/artist.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/mini_player_slot.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_transitions.dart';
import 'package:provider/provider.dart';
import 'album_screen.dart';

class ArtistAllAlbumsScreen extends StatelessWidget {
  final String artistName;
  final String title; // "Albums" or "Singles" — whichever shelf was tapped
  final List<ArtistAlbum> albums;

  const ArtistAllAlbumsScreen({
    super.key,
    required this.artistName,
    required this.title,
    required this.albums,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // Same mini-player-follows-you treatment as every other screen
      // pushed on top of MainShell.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        // PERF: matches artist_screen.dart's _albumGrid cacheExtent
        // reasoning — album art decodes over the network, so a generous
        // cacheExtent keeps a fast fling from showing blank cells.
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
                title,
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
          if (albums.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(
                  title,
                  style:
                      TextStyle(color: AurumTheme.textMutedOf(context)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.72,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _ArtistAlbumGridTile(album: albums[i]),
                  childCount: albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArtistAlbumGridTile extends StatefulWidget {
  final ArtistAlbum album;
  const _ArtistAlbumGridTile({required this.album});

  @override
  State<_ArtistAlbumGridTile> createState() => _ArtistAlbumGridTileState();
}

class _ArtistAlbumGridTileState extends State<_ArtistAlbumGridTile> {
  bool _loading = false;

  // FEATURE ("play button add karo, tap se seedha album play ho" —
  // reference: the screenshot's play-overlay grid): ArtistAlbum only
  // carries header metadata (id/name/artwork/year), never a song list —
  // same reason AlbumScreen itself has to fetch before it can play. Uses
  // the exact same ApiService.fetchAlbumSongsWithArtwork call AlbumScreen
  // already relies on, so this plays from the identical source instead
  // of a second, divergent code path.
  Future<void> _playAlbum() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final result =
          await ApiService.fetchAlbumSongsWithArtwork(widget.album.id);
      if (!mounted) return;
      if (result.songs.isEmpty) {
        AurumSnack.show(context, 'Could not load songs for this album');
        return;
      }
      final player = context.read<PlayerProvider>();
      player.playSong(result.songs.first,
          queue: result.songs, index: 0, curatedQueue: true);
    } catch (_) {
      if (mounted) {
        AurumSnack.show(context, 'Could not load songs for this album');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    // PERF: isolate each grid cell into its own compositor layer — same
    // reasoning as _FollowedAlbumTile on Library and _albumGrid's cards on
    // ArtistScreen, so scrolling a large grid doesn't repaint siblings.
    return RepaintBoundary(
      child: AurumPressable(
        onTap: () {
          AurumHaptics.light();
          AurumDepthRoute.to(
            context,
            AlbumScreen(
              albumId: album.id,
              albumName: album.name,
              artworkUrl: album.artworkUrl,
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AurumArtwork(
                    url: album.artworkUrl,
                    size: 300,
                    borderRadius: 10,
                  ),
                  // Play overlay — matches the reference screenshot's
                  // centered translucent circle exactly. Only the 44x44
                  // circle itself is a separate tap target (not a
                  // fill-the-card InkWell) — the outer AurumPressable is
                  // a GestureDetector, and stacking a full-size second
                  // tap recognizer directly on top of it inside the same
                  // arena is unreliable (both can fire, or the outer one
                  // wins depending on hit-test order). Scoping this
                  // circle to its own bounds means Flutter's hit-testing
                  // naturally resolves it as the innermost, most-specific
                  // target — no arena ambiguity — while everywhere else
                  // on the card still opens AlbumScreen via the outer
                  // AurumPressable as before.
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        AurumHaptics.light();
                        _playAlbum();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black.withOpacity(0.45),
                        ),
                        child: Center(
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 26,
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (album.year != null) ...[
              const SizedBox(height: 2),
              Text(
                album.year!,
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
