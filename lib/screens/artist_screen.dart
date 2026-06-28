// =============================================================================
// FILE: lib/screens/artist_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Artist page — profile header, Top Songs list, Albums/Singles grid.
// =============================================================================

import 'package:aurum/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/song_tile.dart';
import '../utils/aurum_transitions.dart';
import 'album_screen.dart';

class ArtistScreen extends StatefulWidget {
  /// Either pass a known Saavn artistId, or just an artistName to resolve it.
  final String? artistId;
  final String artistName;

  const ArtistScreen({super.key, this.artistId, required this.artistName});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Artist? _artist;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      String? id = widget.artistId;
      id ??= await ApiService.searchArtistByName(widget.artistName);
      if (id == null || id.isEmpty) {
        setState(() {
          _loading = false;
          _failed = true;
        });
        return;
      }
      final artist = await ApiService.fetchArtist(id);
      if (!mounted) return;
      setState(() {
        _artist = artist;
        _loading = false;
        _failed = artist == null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String _formatFollowers(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: _loading
          ? const Center(child: AurumM3Loader())
          : _failed
              ? _buildError(context)
              : _buildContent(context, _artist!),
    );
  }

  Widget _buildError(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 4,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                HapticFeedback.selectionClick();
                Navigator.pop(context);
              },
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_off_rounded,
                  size: 56, color: AurumTheme.textMutedOf(context)),
              const SizedBox(height: 12),
              Text("Couldn't load ${widget.artistName}",
                  style: TextStyle(color: AurumTheme.textSecondaryOf(context))),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _load();
                },
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, Artist artist) {
    final player = context.read<PlayerProvider>();
    final followed = context.watch<FollowedArtistsProvider>();
    final isFollowing = followed.isFollowing(artist.id);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      slivers: [
        SliverAppBar(
          expandedHeight: 400,
          pinned: true,
          backgroundColor: AurumTheme.bgOf(context),
          iconTheme: const IconThemeData(color: Colors.white),
          leading: Padding(
            padding: const EdgeInsets.all(8),
            child: CircleAvatar(
              backgroundColor: Colors.black.withOpacity(0.4),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  Navigator.pop(context);
                },
              ),
            ),
          ),
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                AurumArtwork(url: artist.imageUrl, size: 700, borderRadius: 0),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.05),
                        Colors.black.withOpacity(0.25),
                        Colors.black.withOpacity(0.75),
                        AurumTheme.bgOf(context),
                      ],
                      stops: const [0.0, 0.45, 0.8, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artist.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 38,
                          fontWeight: FontWeight.w800,
                          height: 1.05,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (artist.isVerified) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                color: AurumTheme.gold,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check_rounded,
                                  size: 11, color: Colors.black),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Verified Artist',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Monthly listeners
        if (artist.followerCount > 0)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Text(
                '${_formatFollowers(artist.followerCount)} monthly listeners',
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),

        // Action row: Save · Shuffle · Play
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Row(
              children: [
                OutlinedButton(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    followed.toggleFollow(
                      artistId: artist.id,
                      name: artist.name,
                      imageUrl: artist.imageUrl,
                    );
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: isFollowing
                        ? AurumTheme.gold
                        : AurumTheme.textPrimaryOf(context),
                    side: BorderSide(
                      color: isFollowing
                          ? AurumTheme.gold
                          : AurumTheme.dividerOf(context),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: Text(
                      isFollowing ? 'Saved' : 'Save',
                      key: ValueKey(isFollowing),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13.5),
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.shuffle_rounded),
                  color: AurumTheme.textSecondaryOf(context),
                  onPressed: artist.topSongs.isEmpty
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          final shuffled = List<Song>.from(artist.topSongs)
                            ..shuffle();
                          player.playSong(shuffled.first,
                              queue: shuffled, index: 0);
                        },
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: artist.topSongs.isEmpty
                      ? null
                      : () {
                          HapticFeedback.heavyImpact();
                          player.playSong(artist.topSongs.first,
                              queue: artist.topSongs, index: 0);
                        },
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: AurumTheme.gold,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 30),
                  ),
                ),
              ],
            ),
          ),
        ),


        if (artist.topSongs.isNotEmpty) ...[
          _sectionHeader(context, 'Popular'),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => SongTile(
                song: artist.topSongs[i],
                queue: artist.topSongs,
                index: i,
                showIndex: true,
                displayIndex: i + 1,
              ),
              childCount: artist.topSongs.length,
            ),
          ),
        ],

        if (artist.topAlbums.isNotEmpty) ...[
          _sectionHeader(context, 'Albums'),
          _albumGrid(context, artist.topAlbums),
        ],

        if (artist.singles.isNotEmpty) ...[
          _sectionHeader(context, 'Singles'),
          _albumGrid(context, artist.singles),
        ],

        if (artist.bio.isNotEmpty) ...[
          _sectionHeader(context, 'About'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Text(
                artist.bio,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          title,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _albumGrid(BuildContext context, List<ArtistAlbum> albums) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 190,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: albums.length,
          itemBuilder: (context, i) {
            final a = albums[i];
            return Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  AurumPageRoute.to(
                    context,
                    AlbumScreen(
                      albumId: a.id,
                      albumName: a.name,
                      artworkUrl: a.artworkUrl,
                    ),
                  );
                },
                child: SizedBox(
                  width: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AurumArtwork(url: a.artworkUrl, size: 130, borderRadius: 10),
                      const SizedBox(height: 8),
                      Text(
                        a.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (a.year != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          a.year!,
                          style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
