// =============================================================================
// FILE: lib/screens/album_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Shows the song list inside an album / single — premium,
//   streaming-app-grade layout: centered artwork card with soft shadow,
//   artist avatar chips, meta row, and a floating play FAB over an
//   icon action row (download / save / overflow / shuffle).
// =============================================================================

import 'dart:async';
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/download_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_save_button.dart';
import '../widgets/song_tile.dart';
import 'artist_screen.dart';
import '../l10n/generated/app_localizations.dart';

class AlbumScreen extends StatefulWidget {
  final String albumId;
  final String albumName;
  final String artworkUrl;

  const AlbumScreen({
    super.key,
    required this.albumId,
    required this.albumName,
    required this.artworkUrl,
  });

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<Song> _songs = [];
  bool _loading = true;
  bool _shuffle = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final songs = await ApiService.fetchAlbumSongs(widget.albumId);
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  /// Derives up to 3 distinct artist names across the album's songs —
  /// call sites don't pass artist/year separately, so we build the
  /// "Artist A • Artist B • Artist C" credit line from the loaded songs,
  /// same source SongTile already trusts for per-track artist text.
  List<String> get _creditedArtists {
    final seen = <String>{};
    final out = <String>[];
    for (final s in _songs) {
      final name = s.artist.trim();
      if (name.isEmpty) continue;
      for (final part in name.split(RegExp(r',|&|/'))) {
        final p = part.trim();
        if (p.isEmpty) continue;
        if (seen.add(p)) out.add(p);
        if (out.length >= 3) return out;
      }
    }
    return out;
  }

  String? get _year {
    for (final s in _songs) {
      if (s.year != null && s.year!.trim().isNotEmpty) return s.year;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();
    final artists = _creditedArtists;
    final year = _year;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AurumTheme.bgOf(context),
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            expandedHeight: 400,
            flexibleSpace: FlexibleSpaceBar(
              background: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AurumTheme.gold.withOpacity(0.16),
                      AurumTheme.bgOf(context),
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 56, 32, 0),
                    child: Center(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 30,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: AurumArtwork(
                          url: widget.artworkUrl,
                          size: 220,
                          borderRadius: 10,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    widget.albumName,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 14),
                  if (artists.isNotEmpty) ...[
                    SizedBox(
                      height: 28,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20 + (artists.length - 1) * 14,
                            height: 28,
                            child: Stack(
                              children: [
                                for (var i = 0; i < artists.length; i++)
                                  Positioned(
                                    left: i * 14,
                                    child: CircleAvatar(
                                      radius: 14,
                                      backgroundColor:
                                          AurumTheme.bgOf(context),
                                      child: CircleAvatar(
                                        radius: 12,
                                        backgroundColor:
                                            AurumTheme.bgElevatedOf(context),
                                        child: Text(
                                          artists[i].isNotEmpty
                                              ? artists[i][0].toUpperCase()
                                              : '?',
                                          style: TextStyle(
                                            color: AurumTheme.gold,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              artists.join(' • '),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    [
                      'Album',
                      if (year != null) year,
                    ].join(' • '),
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                children: [
                  Consumer<DownloadProvider>(
                    builder: (context, downloads, _) {
                      return _ActionIcon(
                        icon: Icons.download_outlined,
                        onTap: _songs.isEmpty
                            ? null
                            : () => _downloadAlbum(context, downloads),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  Consumer<FollowedAlbumsProvider>(
                    builder: (context, followedAlbums, _) {
                      final saved = followedAlbums.isFollowing(widget.albumId);
                      return AurumSaveButton(
                        saved: saved,
                        size: 40,
                        onTap: () => followedAlbums.toggleFollow(
                          albumId: widget.albumId,
                          name: widget.albumName,
                          artworkUrl: widget.artworkUrl,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  _ActionIcon(
                    icon: Icons.more_vert_rounded,
                    onTap: () => _showAlbumOptions(context),
                  ),
                  const Spacer(),
                  _ActionIcon(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    onTap: () => setState(() => _shuffle = !_shuffle),
                  ),
                  const SizedBox(width: 12),
                  AurumPressable(
                    scaleAmount: 0.92,
                    onTap: _songs.isEmpty
                        ? null
                        : () {
                            final queue = _shuffle
                                ? (List<Song>.from(_songs)..shuffle())
                                : _songs;
                            player.playSong(queue.first,
                                queue: queue, index: 0);
                          },
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _songs.isEmpty
                            ? AurumTheme.gold.withOpacity(0.4)
                            : AurumTheme.gold,
                        boxShadow: _songs.isEmpty
                            ? null
                            : [
                                BoxShadow(
                                  color: AurumTheme.gold.withOpacity(0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.black,
                        size: 32,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: AurumMorphLoader(size: 56)),
            )
          else if (_songs.isEmpty)
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
                  song: _songs[i],
                  queue: _songs,
                  index: i,
                  showIndex: true,
                  displayIndex: i + 1,
                ),
                childCount: _songs.length,
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(context),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  /// Queues every song in the album for download via DownloadProvider,
  /// skipping ones already downloaded/in-progress. Mirrors the per-song
  /// download flow used elsewhere in the app, just looped across the album.
  Future<void> _downloadAlbum(
      BuildContext context, DownloadProvider downloads) async {
    final toQueue = _songs
        .where((s) => !downloads.isDownloaded(s.id) && !downloads.isDownloading(s.id))
        .toList();
    if (toQueue.isEmpty) {
      _snack(context, 'Already downloaded');
      return;
    }
    _snack(context, 'Downloading ${toQueue.length} song(s)…');
    for (final song in toQueue) {
      unawaited(downloads.download(song));
    }
  }

  void _showAlbumOptions(BuildContext context) {
    final rootContext = context;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _AlbumOptionsSheet(
        albumId: widget.albumId,
        albumName: widget.albumName,
        artworkUrl: widget.artworkUrl,
        songs: _songs,
        artists: _creditedArtists,
        rootContext: rootContext,
      ),
    );
  }
}

/// Premium album-level options sheet — mirrors SongTile's _SongOptionsSheet
/// styling (icon grid + "GO TO" artist chips) so the app feels consistent
/// whether you're opening options from a song row or from an album header.
class _AlbumOptionsSheet extends StatefulWidget {
  final String albumId;
  final String albumName;
  final String artworkUrl;
  final List<Song> songs;
  final List<String> artists;
  final BuildContext rootContext;

  const _AlbumOptionsSheet({
    required this.albumId,
    required this.albumName,
    required this.artworkUrl,
    required this.songs,
    required this.artists,
    required this.rootContext,
  });

  @override
  State<_AlbumOptionsSheet> createState() => _AlbumOptionsSheetState();
}

class _AlbumOptionsSheetState extends State<_AlbumOptionsSheet> {
  void _snack(String msg) {
    ScaffoldMessenger.of(widget.rootContext).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(widget.rootContext),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final downloads = context.watch<DownloadProvider>();
    final followedAlbums = context.watch<FollowedAlbumsProvider>();
    final saved = followedAlbums.isFollowing(widget.albumId);
    final songs = widget.songs;

    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Album header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                AurumArtwork(
                    url: widget.artworkUrl, size: 56, borderRadius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.albumName,
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
                        widget.artists.isNotEmpty
                            ? widget.artists.join(' • ')
                            : 'Album',
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: saved
                        ? AurumTheme.gold.withOpacity(0.12)
                        : AurumTheme.bgSurfaceOf(context),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AurumSaveButton(
                      saved: saved,
                      size: 20,
                      onTap: () => followedAlbums.toggleFollow(
                        albumId: widget.albumId,
                        name: widget.albumName,
                        artworkUrl: widget.artworkUrl,
                      ),
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
                    if (songs.isEmpty) return;
                    Navigator.pop(context);
                    unawaited(
                        player.playSong(songs.first, queue: songs, index: 0));
                  },
                ),
                _GridOption(
                  icon: Icons.shuffle_rounded,
                  label: 'Shuffle Play',
                  color: AurumTheme.gold,
                  onTap: () {
                    if (songs.isEmpty) return;
                    Navigator.pop(context);
                    final shuffled = List<Song>.from(songs)..shuffle();
                    unawaited(player.playSong(shuffled.first,
                        queue: shuffled, index: 0));
                  },
                ),
                _GridOption(
                  icon: Icons.queue_music_rounded,
                  label: 'Add to Queue',
                  color: Colors.purpleAccent,
                  onTap: () {
                    if (songs.isEmpty) return;
                    for (final s in songs) {
                      unawaited(player.addToQueue(s));
                    }
                    _snack('Added ${songs.length} songs to queue');
                  },
                ),
                _GridOption(
                  icon: saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  label: saved ? 'Saved to Library' : 'Add to Library',
                  color: const Color(0xFFE1306C),
                  onTap: () {
                    followedAlbums.toggleFollow(
                      albumId: widget.albumId,
                      name: widget.albumName,
                      artworkUrl: widget.artworkUrl,
                    );
                    _snack(saved ? 'Removed from Library' : 'Added to Library');
                  },
                ),
                _GridOption(
                  icon: Icons.download_outlined,
                  label: 'Download Album',
                  color: Colors.blueAccent,
                  onTap: () {
                    if (songs.isEmpty) return;
                    final toQueue = songs
                        .where((s) =>
                            !downloads.isDownloaded(s.id) &&
                            !downloads.isDownloading(s.id))
                        .toList();
                    if (toQueue.isEmpty) {
                      _snack('Already downloaded');
                      return;
                    }
                    for (final s in toQueue) {
                      unawaited(downloads.download(s));
                    }
                    _snack('Downloading ${toQueue.length} song(s)…');
                  },
                ),
                _GridOption(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  color: Colors.greenAccent,
                  onTap: () {
                    Navigator.pop(context);
                    if (songs.isNotEmpty) {
                      shareSong(context, songs.first);
                    }
                  },
                ),
              ],
            ),
          ),

          // Artist chips — every distinct artist credited across the
          // album's songs, Spotify-style "GO TO" row. Each chip resolves
          // its own artistId by name when tapped (ArtistScreen handles
          // the not-found case with its own empty state), so an artist
          // that isn't in the catalog just shows a friendly message
          // instead of a broken navigation.
          if (widget.artists.isNotEmpty) ...[
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
                  for (final name in widget.artists)
                    _ArtistChip(
                      name: name,
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          widget.rootContext,
                          MaterialPageRoute(
                            builder: (_) => ArtistScreen(artistName: name),
                          ),
                        );
                      },
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

/// Small circular icon button used in the action row (download / overflow /
/// shuffle). Kept separate from AurumSaveButton since these are plain
/// stateless taps, not a persisted toggle with its own animation identity —
/// except shuffle, which gets a tinted "active" state.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  const _ActionIcon({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return AurumPressable(
      scaleAmount: 0.88,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(
          icon,
          size: 22,
          color: disabled
              ? AurumTheme.textMutedOf(context).withOpacity(0.4)
              : active
                  ? AurumTheme.gold
                  : AurumTheme.textSecondaryOf(context),
        ),
      ),
    );
  }
}
