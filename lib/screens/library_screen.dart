// =============================================================================
// FILE: lib/screens/library_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Library with full Spotify-style Playlists feature.
//   ✅ Create / rename / delete playlists
//   ✅ Add songs from player or search via "Add to Playlist" sheet
//   ✅ Drag-to-reorder songs inside playlist
//   ✅ Mosaic / single cover art
//   ✅ Play All / Shuffle inside playlist
//   ✅ Zero feature removal — all existing screens intact
//
// v2 CHANGES (this pass):
//   • _CoverFan empty state: replaced the sparkle/"AI-generated" glyph
//     (Icons.auto_awesome_rounded) with a plain white music-note icon —
//     matches the app's own logo mark instead of reading as a generic
//     AI-tool placeholder.
//   • Identity header card gets an actual glass surface (gradient +
//     border + soft shadow) instead of floating flat on the page
//     background, so "Your collection" reads as a designed module, not
//     a stray row of text.
//   • Collection rows: replaced the flat text-on-transparent list with
//     tonal glass cards (subtle gradient fill, hairline border, soft
//     shadow) — same information density, more depth so it reads like a
//     shelf of premium tiles rather than a plain settings-style list.
// =============================================================================

import 'dart:math' as math;
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/download_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/premium_provider.dart';
import '../providers/auth_provider.dart';
import '../models/download_item.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/premium_gate.dart';
import '../models/song.dart';
import '../utils/aurum_transitions.dart';
import 'settings_screen.dart';
import 'liked_screen.dart';
import '../providers/followed_artists_provider.dart';
import 'artist_screen.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Library Root
// ══════════════════════════════════════════════════════════════════════════════

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          _buildAppBar(context),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildIdentityHeader(context),
                const SizedBox(height: 18),
                _buildQuickAccess(context),
                const SizedBox(height: 20),
                _buildSectionLabel(context, 'Collection'),
                const SizedBox(height: 4),
                _buildCollectionList(context),
                const SizedBox(height: 26),
                _buildSectionLabel(context, 'Recently Played'),
                _buildRecentlyPlayed(context),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 90,
      floating: true,
      snap: true,
      backgroundColor: AurumTheme.bgOf(context),
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => AurumPageRoute.to(context, const SettingsScreen()),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 0, 14),
        title: Text('Library',
            style: TextStyle(
                color: AurumTheme.gold,
                fontSize: 25,
                fontWeight: FontWeight.w800)),
      ),
    );
  }

  // ── Identity header ──────────────────────────────────────────────────────
  // A small fanned-out collage of the last few played covers, sitting on
  // a proper glass surface (gradient fill + hairline border + soft
  // shadow) beside a single inline stat line. Wrapping this in an actual
  // "card" — instead of letting the cover fan + text float directly on
  // the page background — is what makes this read as a designed module
  // rather than a stray header row.
  Widget _buildIdentityHeader(BuildContext context) {
    final history = context.watch<RecentlyPlayedProvider>().history;
    final favCount = context.watch<FavoritesProvider>().favorites.length;
    final lib = context.watch<LibraryProvider>();
    final plCount = context.watch<PlaylistProvider>().count;
    final followedCount =
        context.watch<FollowedArtistsProvider>().followed.length;
    final localCount = lib.hasLoaded ? lib.allSongs.length : 0;

    final totalTracked = favCount + localCount + history.length;
    final covers = history.take(4).toList();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isLight
                ? [
                    AurumTheme.gold.withOpacity(0.10),
                    Colors.purpleAccent.withOpacity(0.05),
                  ]
                : [
                    AurumTheme.gold.withOpacity(0.08),
                    Colors.purpleAccent.withOpacity(0.06),
                  ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AurumTheme.gold.withOpacity(isLight ? 0.16 : 0.14),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isLight ? 0.04 : 0.18),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _CoverFan(covers: covers),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    totalTracked == 0 ? 'Nothing here yet' : 'Your collection',
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statLine(favCount, plCount, followedCount, localCount),
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statLine(int fav, int pl, int artists, int local) {
    final parts = <String>[];
    parts.add('$fav liked');
    parts.add('$pl ${pl == 1 ? 'playlist' : 'playlists'}');
    parts.add('$artists ${artists == 1 ? 'artist' : 'artists'}');
    if (local > 0) parts.add('$local on device');
    return parts.join('  ·  ');
  }

  Widget _buildQuickAccess(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _QuickChip(
            icon: Icons.favorite_rounded,
            label: 'Liked',
            color: Colors.pinkAccent,
            onTap: () => AurumPageRoute.to(context, const LikedScreen()),
          ),
          const SizedBox(width: 8),
          _QuickChip(
            icon: Icons.download_rounded,
            label: 'Downloads',
            color: AurumTheme.gold,
            onTap: () => AurumPageRoute.to(context, const DownloadsScreen()),
          ),
          const SizedBox(width: 8),
          _QuickChip(
            icon: Icons.history_rounded,
            label: 'History',
            color: Colors.teal,
            onTap: () => AurumPageRoute.to(context, const _HistoryScreen()),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Text(title,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3)),
    );
  }

  // ── Collection list ──────────────────────────────────────────────────────
  // Tonal glass cards instead of a flat text-on-transparent list — each
  // row is its own subtle surface (gradient wash in the row's accent
  // colour + hairline border + soft shadow), so this reads like a shelf
  // of premium tiles rather than a plain settings-style list.
  Widget _buildCollectionList(BuildContext context) {
    final favCount = context.watch<FavoritesProvider>().favorites.length;
    final lib = context.watch<LibraryProvider>();
    final plCount = context.watch<PlaylistProvider>().count;
    final followedCount =
        context.watch<FollowedArtistsProvider>().followed.length;

    final items = [
      _CollectionItem(
        icon: Icons.favorite_rounded,
        label: 'Liked Songs',
        subtitle: '$favCount',
        color: Colors.pinkAccent,
        onTap: () => AurumPageRoute.to(context, const LikedScreen()),
      ),
      _CollectionItem(
        icon: Icons.queue_music_rounded,
        label: 'Playlists',
        subtitle: plCount == 0 ? '' : '$plCount',
        color: Colors.purpleAccent,
        onTap: () => AurumPageRoute.to(context, const PlaylistsScreen()),
      ),
      _CollectionItem(
        icon: Icons.album_rounded,
        label: 'Albums',
        subtitle: '',
        color: Colors.deepPurple,
        onTap: () => AurumPageRoute.to(context, const _AlbumsScreen()),
      ),
      _CollectionItem(
        icon: Icons.person_rounded,
        label: 'Artists',
        subtitle: followedCount == 0 ? '' : '$followedCount',
        color: Colors.blueAccent,
        onTap: () => AurumPageRoute.to(context, const _ArtistsScreen()),
      ),
      _CollectionItem(
        icon: Icons.folder_rounded,
        label: 'Local Files',
        subtitle: lib.hasLoaded ? '${lib.allSongs.length}' : '',
        color: Colors.green,
        onTap: () async {
          if (!lib.hasLoaded) await lib.load();
          if (context.mounted) {
            AurumPageRoute.to(context, const _LocalFilesScreen());
          }
        },
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: List.generate(items.length, (i) {
          return Padding(
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 10),
            child: _CollectionRow(item: items[i]),
          );
        }),
      ),
    );
  }

  Widget _buildRecentlyPlayed(BuildContext context) {
    final history = context.watch<RecentlyPlayedProvider>().history;

    if (history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            children: [
              Icon(Icons.music_note_rounded,
                  size: 40,
                  color: AurumTheme.textMutedOf(context).withOpacity(0.3)),
              const SizedBox(height: 8),
              Text('Play something to see history',
                  style: TextStyle(
                      color: AurumTheme.textMutedOf(context), fontSize: 13)),
            ],
          ),
        ),
      );
    }

    final recent = history.take(5).toList();
    return Column(
      children: [
        ...recent.asMap().entries.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SongTile(song: e.value, queue: recent, index: e.key),
              ),
            ),
        if (history.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () => AurumPageRoute.to(context, const _HistoryScreen()),
              child: Text(
                'See all ${history.length} songs',
                style: TextStyle(
                    color: AurumTheme.gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PLAYLISTS SCREEN  — Spotify-style list of user playlists
// ══════════════════════════════════════════════════════════════════════════════

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlaylistProvider>(
      builder: (context, pp, _) {
        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── App Bar ─────────────────────────────────────────────────
              SliverAppBar(
                expandedHeight: 110,
                floating: true,
                snap: true,
                backgroundColor: AurumTheme.bgOf(context),
                leading: IconButton(
                  icon: Icon(Icons.arrow_back_ios_rounded,
                      color: AurumTheme.textSecondaryOf(context), size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.add_rounded,
                        color: AurumTheme.gold, size: 26),
                    onPressed: () => _showCreateDialog(context),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.fromLTRB(52, 0, 60, 16),
                  title: Row(
                    children: [
                      const Icon(Icons.queue_music_rounded,
                          color: Colors.purpleAccent, size: 22),
                      const SizedBox(width: 8),
                      ShaderMask(
                        shaderCallback: (b) =>
                            AurumTheme.goldGradient.createShader(b),
                        child: const Text('Playlists',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Empty State ─────────────────────────────────────────────
              if (pp.playlists.isEmpty)
                SliverFillRemaining(
                  child: _EmptyPlaylists(
                      onCreateTap: () => _showCreateDialog(context)),
                )
              else ...[
                // ── Header row ────────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Text(
                      '${pp.count} playlist${pp.count == 1 ? '' : 's'}',
                      style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 12),
                    ),
                  ),
                ),
                // ── Playlist Cards ────────────────────────────────────────
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final pl = pp.playlists[i];
                      return _PlaylistCard(playlist: pl);
                    },
                    childCount: pp.playlists.length,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ],
          ),
          // ── FAB ─────────────────────────────────────────────────────────
          floatingActionButton: pp.playlists.isNotEmpty
              ? FloatingActionButton(
                  backgroundColor: AurumTheme.gold,
                  onPressed: () => _showCreateDialog(context),
                  child: Icon(Icons.add_rounded, color: AurumTheme.bgOf(context)),
                )
              : null,
        );
      },
    );
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    PremiumGate.guard(
      context,
      feature: 'Create Playlist',
      description: 'Sign in with Google to organize your music into playlists.',
      requiresLoginOnly: true,
      onAllowed: () async {
        await showDialog(
          context: context,
          builder: (_) => _CreatePlaylistDialog(),
        );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PLAYLIST DETAIL SCREEN
// ══════════════════════════════════════════════════════════════════════════════

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final pp = context.watch<PlaylistProvider>();
    final pl = pp.getById(widget.playlistId);

    if (pl == null) {
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        body: Center(
          child: Text('Playlist not found',
              style: TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── Header ──────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            backgroundColor: AurumTheme.bgOf(context),
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded,
                  color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            actions: [
              IconButton(
                icon: Icon(Icons.more_vert_rounded,
                    color: AurumTheme.textSecondaryOf(context)),
                onPressed: () => _showPlaylistOptions(context, pl),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: _PlaylistHeader(playlist: pl),
              collapseMode: CollapseMode.pin,
            ),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(0),
              child: Container(
                height: 1,
                color: AurumTheme.textMutedOf(context).withOpacity(0.1),
              ),
            ),
          ),

          // ── Action Row ──────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: _PlaylistActionRow(playlist: pl),
          ),

          // ── Songs ────────────────────────────────────────────────────────
          if (pl.songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withOpacity(0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Colors.purpleAccent.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.music_note_rounded,
                            color: Colors.purpleAccent, size: 36),
                      ),
                      const SizedBox(height: 20),
                      Text('No songs yet',
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text('Search for songs and add them here',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 13,
                              height: 1.5)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverReorderableList(
              itemCount: pl.songs.length,
              onReorder: (oldIdx, newIdx) {
                context
                    .read<PlaylistProvider>()
                    .reorderSong(pl.id, oldIdx, newIdx);
              },
              itemBuilder: (context, i) {
                final song = pl.songs[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey('${pl.id}_${song.id}_$i'),
                  index: i,
                  child: _PlaylistSongTile(
                    song: song,
                    playlist: pl,
                    index: i,
                  ),
                );
              },
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  void _showPlaylistOptions(BuildContext context, AurumPlaylist pl) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      backgroundColor:
          isLight ? AurumTheme.lightBgCard : AurumTheme.darkBgElevated,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              decoration: BoxDecoration(
                color: AurumTheme.textMutedOf(context).withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading:
                  const Icon(Icons.edit_rounded, color: AurumTheme.gold),
              title: Text('Rename playlist',
                  style:
                      TextStyle(color: AurumTheme.textPrimaryOf(context))),
              onTap: () {
                Navigator.pop(ctx);
                _showRenameDialog(context, pl);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent),
              title: const Text('Delete playlist',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, pl);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(BuildContext context, AurumPlaylist pl) async {
    await showDialog(
      context: context,
      builder: (_) => _RenamePlaylistDialog(playlist: pl),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AurumPlaylist pl) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(context),
        title: Text('Delete "${pl.name}"?',
            style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text('This cannot be undone.',
            style: TextStyle(color: AurumTheme.textMutedOf(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel',
                  style: TextStyle(
                      color: AurumTheme.textMutedOf(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await context
          .read<PlaylistProvider>()
          .deletePlaylist(pl.id);
      if (context.mounted) Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Playlist Header (large artwork + info)
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistHeader extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistHeader({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AurumTheme.bgOf(context),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // ── Cover Art ───────────────────────────────────────────────────
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(0.2),
                  blurRadius: 30,
                  spreadRadius: 2,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: playlist.mosaicArts.isEmpty
                  ? Container(
                      color: Colors.purpleAccent.withOpacity(0.15),
                      child: const Icon(Icons.queue_music_rounded,
                          color: Colors.purpleAccent, size: 72),
                    )
                  : playlist.mosaicArts.length < 4
                      ? AurumArtwork(
                          url: playlist.mosaicArts.first,
                          size: 180,
                          borderRadius: 16)
                      : _MosaicCover(arts: playlist.mosaicArts),
            ),
          ),
          const SizedBox(height: 20),
          // ── Title ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              playlist.name,
              style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 22,
                  fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (playlist.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                playlist.description,
                style: TextStyle(
                    color: AurumTheme.textMutedOf(context), fontSize: 13),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${playlist.songCount} song${playlist.songCount == 1 ? '' : 's'}'
            '${playlist.totalDurationString.isNotEmpty ? ' • ${playlist.totalDurationString}' : ''}',
            style: TextStyle(
                color: AurumTheme.textMutedOf(context), fontSize: 12),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Mosaic 2×2 cover grid
// ══════════════════════════════════════════════════════════════════════════════

class _MosaicCover extends StatelessWidget {
  final List<String> arts;
  const _MosaicCover({required this.arts});

  @override
  Widget build(BuildContext context) {
    final cells = arts.take(4).toList();
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 1,
      crossAxisSpacing: 1,
      children: cells
          .map((url) => AurumArtwork(url: url, size: 89, borderRadius: 0))
          .toList(),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Action Row (Play All / Shuffle)
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistActionRow extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistActionRow({required this.playlist});

  @override
  Widget build(BuildContext context) {
    if (playlist.songs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          // Play All
          Expanded(
            child: AurumPressable(
              onTap: () {
                context.read<PlayerProvider>().playSong(
                      playlist.songs[0],
                      queue: playlist.songs,
                      index: 0,
                    );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient: AurumTheme.goldGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_arrow_rounded,
                        color: AurumTheme.bgOf(context), size: 22),
                    const SizedBox(width: 6),
                    Text('Play',
                        style: TextStyle(
                            color: AurumTheme.bgOf(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Shuffle
          Expanded(
            child: AurumPressable(
              onTap: () {
                final shuffled = List<Song>.from(playlist.songs)..shuffle();
                context.read<PlayerProvider>().playSong(
                      shuffled[0],
                      queue: shuffled,
                      index: 0,
                    );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color:
                      Colors.purpleAccent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: Colors.purpleAccent.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.shuffle_rounded,
                        color: Colors.purpleAccent, size: 20),
                    const SizedBox(width: 6),
                    Text('Shuffle',
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Song tile inside playlist (with remove option)
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistSongTile extends StatelessWidget {
  final Song song;
  final AurumPlaylist playlist;
  final int index;

  const _PlaylistSongTile({
    required this.song,
    required this.playlist,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final isCurrentSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == song.id,
    );
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: AurumArtwork(url: song.artworkUrl, size: 48, borderRadius: 8),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isCurrentSong
              ? AurumTheme.gold
              : AurumTheme.textPrimaryOf(context),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            color: AurumTheme.textMutedOf(context), fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Options menu
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded,
                color: AurumTheme.textMutedOf(context), size: 20),
            color: isLight
                ? AurumTheme.lightBgCard
                : AurumTheme.darkBgElevated,
            onSelected: (value) {
              if (value == 'remove') {
                context
                    .read<PlaylistProvider>()
                    .removeSong(playlist.id, song.id);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'remove',
                child: Row(
                  children: [
                    const Icon(Icons.remove_circle_outline_rounded,
                        color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Text('Remove from playlist',
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          // Drag handle
          Icon(Icons.drag_handle_rounded,
              color: AurumTheme.textMutedOf(context).withOpacity(0.5),
              size: 20),
        ],
      ),
      onTap: () {
        HapticFeedback.lightImpact();
        context.read<PlayerProvider>().playSong(
              song,
              queue: playlist.songs,
              index: index,
            );
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Playlist Card in list
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistCard extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: () => AurumPageRoute.to(
        context,
        PlaylistDetailScreen(playlistId: playlist.id),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: Colors.purpleAccent.withOpacity(0.12), width: 0.8),
        ),
        child: Row(
          children: [
            // ── Cover ──────────────────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: playlist.mosaicArts.isEmpty
                    ? Container(
                        color: Colors.purpleAccent.withOpacity(0.15),
                        child: const Icon(Icons.queue_music_rounded,
                            color: Colors.purpleAccent, size: 28),
                      )
                    : playlist.mosaicArts.length < 4
                        ? AurumArtwork(
                            url: playlist.mosaicArts.first,
                            size: 56,
                            borderRadius: 10)
                        : _MosaicCover(arts: playlist.mosaicArts),
              ),
            ),
            const SizedBox(width: 14),
            // ── Info ───────────────────────────────────────────────────
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                    '${playlist.songCount} song${playlist.songCount == 1 ? '' : 's'}'
                    '${playlist.totalDurationString.isNotEmpty ? ' • ${playlist.totalDurationString}' : ''}',
                    style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            // ── Chevron ────────────────────────────────────────────────
            Icon(Icons.chevron_right_rounded,
                color: AurumTheme.textMutedOf(context).withOpacity(0.5)),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Empty Playlists state
// ══════════════════════════════════════════════════════════════════════════════

class _EmptyPlaylists extends StatelessWidget {
  final VoidCallback onCreateTap;
  const _EmptyPlaylists({required this.onCreateTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.purpleAccent.withOpacity(0.15),
                    AurumTheme.gold.withOpacity(0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.purpleAccent.withOpacity(0.25), width: 1.5),
              ),
              child: const Icon(Icons.queue_music_rounded,
                  color: Colors.purpleAccent, size: 48),
            ),
            const SizedBox(height: 24),
            Text('No playlists yet',
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              'Create your first playlist and\nstart curating your music.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 14,
                  height: 1.6),
            ),
            const SizedBox(height: 32),
            AurumPressable(
              onTap: onCreateTap,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 36, vertical: 15),
                decoration: BoxDecoration(
                  gradient: AurumTheme.goldGradient,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: AurumTheme.gold.withOpacity(0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded,
                        color: AurumTheme.bgOf(context), size: 20),
                    const SizedBox(width: 8),
                    Text('Create Playlist',
                        style: TextStyle(
                            color: AurumTheme.bgOf(context),
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Create Playlist Dialog
// ══════════════════════════════════════════════════════════════════════════════

class _CreatePlaylistDialog extends StatefulWidget {
  final Song? initialSong;
  const _CreatePlaylistDialog({this.initialSong});

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('New Playlist',
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AurumTextField(
            controller: _nameCtrl,
            label: 'Playlist name',
            autofocus: true,
          ),
          const SizedBox(height: 12),
          _AurumTextField(
            controller: _descCtrl,
            label: 'Description (optional)',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style:
                  TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
        AurumPressable(
          onTap: _creating ? null : _create,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              gradient: AurumTheme.goldGradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: _creating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: Center(child: AurumM3Loader(width: 16, height: 2)))
                : Text('Create',
                    style: TextStyle(
                        color: AurumTheme.bgOf(context),
                        fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _nameCtrl.text = 'My Playlist';
    }
    setState(() => _creating = true);
    final pl = await context.read<PlaylistProvider>().createPlaylist(
          name: _nameCtrl.text.trim().isEmpty
              ? 'My Playlist'
              : _nameCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          initialSong: widget.initialSong,
        );
    if (mounted) {
      Navigator.pop(context);
      // Navigate directly to the new playlist
      AurumPageRoute.to(
        context,
        PlaylistDetailScreen(playlistId: pl.id),
      );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Rename Dialog
// ══════════════════════════════════════════════════════════════════════════════

class _RenamePlaylistDialog extends StatefulWidget {
  final AurumPlaylist playlist;
  const _RenamePlaylistDialog({required this.playlist});

  @override
  State<_RenamePlaylistDialog> createState() => _RenamePlaylistDialogState();
}

class _RenamePlaylistDialogState extends State<_RenamePlaylistDialog> {
  late TextEditingController _nameCtrl;
  late TextEditingController _descCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.playlist.name);
    _descCtrl = TextEditingController(text: widget.playlist.description);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text('Edit Playlist',
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AurumTextField(controller: _nameCtrl, label: 'Playlist name'),
          const SizedBox(height: 12),
          _AurumTextField(
              controller: _descCtrl, label: 'Description (optional)'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel',
              style:
                  TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
        AurumPressable(
          onTap: () async {
            await context.read<PlaylistProvider>().renamePlaylist(
                  widget.playlist.id,
                  _nameCtrl.text,
                  newDescription: _descCtrl.text,
                );
            if (mounted) Navigator.pop(context);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              gradient: AurumTheme.goldGradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('Save',
                style: TextStyle(
                    color: AurumTheme.bgOf(context),
                    fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// "Add to Playlist" bottom sheet — call this from anywhere (player, search, etc)
// ══════════════════════════════════════════════════════════════════════════════

/// Call this from player 3-dot menu or SongTile long-press.
Future<void> showAddToPlaylistSheet(BuildContext context, Song song) async {
  final pp = context.read<PlaylistProvider>();
  final isLight = Theme.of(context).brightness == Brightness.light;

  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor:
        isLight ? AurumTheme.lightBgCard : AurumTheme.darkBgElevated,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      return Consumer<PlaylistProvider>(
        builder: (context, pp, _) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.55,
            minChildSize: 0.35,
            maxChildSize: 0.85,
            builder: (_, scrollCtrl) => Column(
              children: [
                // Handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Title
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      AurumArtwork(
                          url: song.artworkUrl, size: 44, borderRadius: 8),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Add to playlist',
                                style: TextStyle(
                                    color:
                                        AurumTheme.textPrimaryOf(context),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            Text(song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color:
                                        AurumTheme.textMutedOf(context),
                                    fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(
                    color: AurumTheme.textMutedOf(context).withOpacity(0.1),
                    height: 1),
                // New playlist button
                ListTile(
                  leading: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AurumTheme.gold.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AurumTheme.gold.withOpacity(0.3)),
                    ),
                    child: const Icon(Icons.add_rounded,
                        color: AurumTheme.gold, size: 22),
                  ),
                  title: Text('New playlist',
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontWeight: FontWeight.w600)),
                  onTap: () {
                    PremiumGate.guard(
                      context,
                      feature: 'Create Playlist',
                      description: 'Sign in with Google to organize your music into playlists.',
                      requiresLoginOnly: true,
                      onAllowed: () {
                        Navigator.pop(ctx);
                        showDialog(
                          context: context,
                          builder: (_) =>
                              _CreatePlaylistDialog(initialSong: song),
                        );
                      },
                    );
                  },
                ),
                // Existing playlists
                Expanded(
                  child: pp.playlists.isEmpty
                      ? Center(
                          child: Text('No playlists yet',
                              style: TextStyle(
                                  color: AurumTheme.textMutedOf(context))))
                      : ListView.builder(
                          controller: scrollCtrl,
                          physics: const BouncingScrollPhysics(),
                          itemCount: pp.playlists.length,
                          itemExtent: 72,
                          itemBuilder: (_, i) {
                            final pl = pp.playlists[i];
                            final alreadyIn = pp.isSongInPlaylist(pl.id, song.id);
                            return ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: pl.mosaicArts.isEmpty
                                      ? Container(
                                          color: Colors.purpleAccent
                                              .withOpacity(0.15),
                                          child: const Icon(
                                              Icons.queue_music_rounded,
                                              color: Colors.purpleAccent,
                                              size: 20))
                                      : AurumArtwork(
                                          url: pl.mosaicArts.first,
                                          size: 44,
                                          borderRadius: 8),
                                ),
                              ),
                              title: Text(pl.name,
                                  style: TextStyle(
                                      color: AurumTheme.textPrimaryOf(context),
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                  '${pl.songCount} song${pl.songCount == 1 ? '' : 's'}',
                                  style: TextStyle(
                                      color: AurumTheme.textMutedOf(context),
                                      fontSize: 12)),
                              trailing: alreadyIn
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AurumTheme.gold, size: 22)
                                  : null,
                              onTap: alreadyIn
                                  ? null
                                  : () async {
                                      final added = await context
                                          .read<PlaylistProvider>()
                                          .addSong(pl.id, song);
                                      if (context.mounted) {
                                        Navigator.pop(ctx);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                          content: Text(added
                                              ? 'Added to "${pl.name}"'
                                              : 'Already in "${pl.name}"'),
                                          backgroundColor:
                                              added ? AurumTheme.gold : null,
                                          behavior: SnackBarBehavior.floating,
                                          duration:
                                              const Duration(seconds: 2),
                                        ));
                                      }
                                    },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      );
    },
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// Reusable text field
// ══════════════════════════════════════════════════════════════════════════════

class _AurumTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool autofocus;

  const _AurumTextField({
    required this.controller,
    required this.label,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      style: TextStyle(color: AurumTheme.textPrimaryOf(context)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle:
            TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
        filled: true,
        fillColor: AurumTheme.bgOf(context).withOpacity(0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: AurumTheme.textMutedOf(context).withOpacity(0.2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
              color: AurumTheme.textMutedOf(context).withOpacity(0.2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AurumTheme.gold, width: 1.5),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════════════════════
// History Screen — time-grouped, animated, play all / shuffle
// ══════════════════════════════════════════════════════════════════════════════

class _HistoryScreen extends StatefulWidget {
  const _HistoryScreen();
  @override
  State<_HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<_HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _headerCtrl;
  late final Animation<double> _headerFade;

  @override
  void initState() {
    super.initState();
    _headerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _headerFade = CurvedAnimation(parent: _headerCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    super.dispose();
  }

  // ── Time label helpers ─────────────────────────────────────────────────────
  static String _timeLabel(Song song) {
    // Songs don't store timestamp, so we group by position in list:
    // provider stores newest-first, so index 0 = most recent
    return '';
  }

  static String _groupLabel(int index, int total) {
    if (index == 0) return 'Just now';
    if (index < 5) return 'Recent';
    if (index < 15) return 'Earlier today';
    if (index < 30) return 'Yesterday';
    return 'Older';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RecentlyPlayedProvider>(
      builder: (context, rp, _) {
        final history = rp.history;

        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // ── App Bar ──
              SliverAppBar(
                expandedHeight: 120,
                floating: false,
                pinned: true,
                backgroundColor: AurumTheme.bgOf(context),
                leading: IconButton(
                  icon: Icon(Icons.arrow_back_ios_new_rounded,
                      color: AurumTheme.textPrimaryOf(context), size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
                actions: history.isNotEmpty
                    ? [
                        IconButton(
                          icon: Icon(Icons.shuffle_rounded,
                              color: AurumTheme.gold, size: 22),
                          tooltip: 'Shuffle',
                          onPressed: () {
                            HapticFeedback.selectionClick();
                            final shuffled = [...history]..shuffle();
                            context.read<PlayerProvider>().playSong(
                                shuffled[0],
                                queue: shuffled,
                                index: 0);
                          },
                        ),
                        const SizedBox(width: 4),
                      ]
                    : null,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
                  title: FadeTransition(
                    opacity: _headerFade,
                    child: Row(children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AurumTheme.gold.withOpacity(0.15),
                        ),
                        child: const Icon(Icons.history_rounded,
                            color: AurumTheme.gold, size: 16),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Recently Played',
                        style: TextStyle(
                          color: AurumTheme.gold,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ]),
                  ),
                ),
              ),

              // ── Empty state ──
              if (history.isEmpty)
                SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: AurumTheme.gold.withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.history_rounded,
                              color: AurumTheme.gold.withOpacity(0.5),
                              size: 36),
                        ),
                        const SizedBox(height: 20),
                        Text('No history yet',
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text('Songs you play will appear here',
                            style: TextStyle(
                                color: AurumTheme.textMutedOf(context),
                                fontSize: 13)),
                      ],
                    ),
                  ),
                )
              else ...[
                // ── Stats + action bar ──
                SliverToBoxAdapter(
                  child: FadeTransition(
                    opacity: _headerFade,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Row(children: [
                        Text(
                          '${history.length} songs',
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 13),
                        ),
                        const Spacer(),
                        // Play All
                        AurumPressable(
                          onTap: () {
                            context.read<PlayerProvider>().playSong(
                                history[0],
                                queue: history,
                                index: 0);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              gradient: AurumTheme.goldGradient,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: AurumTheme.gold.withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                )
                              ],
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.play_arrow_rounded,
                                  color: AurumTheme.bg, size: 16),
                              const SizedBox(width: 4),
                              Text('Play All',
                                  style: TextStyle(
                                      color: AurumTheme.bg,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Clear
                        AurumPressable(
                          onTap: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor:
                                    AurumTheme.bgElevatedOf(context),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20)),
                                title: Text('Clear History?',
                                    style: TextStyle(
                                        color:
                                            AurumTheme.textPrimaryOf(context),
                                        fontWeight: FontWeight.w800)),
                                content: Text(
                                    'All ${history.length} songs will be removed.',
                                    style: TextStyle(
                                        color:
                                            AurumTheme.textMutedOf(context))),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text('Cancel',
                                          style: TextStyle(
                                              color: AurumTheme
                                                  .textMutedOf(context)))),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: const Text('Clear',
                                          style: TextStyle(
                                              color: Colors.redAccent))),
                                ],
                              ),
                            );
                            if (confirmed == true && context.mounted) {
                              await context
                                  .read<RecentlyPlayedProvider>()
                                  .clearHistory();
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: Colors.redAccent.withOpacity(0.3)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.delete_outline_rounded,
                                  color: Colors.redAccent, size: 15),
                              const SizedBox(width: 4),
                              const Text('Clear',
                                  style: TextStyle(
                                      color: Colors.redAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                            ]),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),

                // ── Grouped song list ──
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final song = history[i];
                      final currentGroup = _groupLabel(i, history.length);
                      final prevGroup = i > 0
                          ? _groupLabel(i - 1, history.length)
                          : null;
                      final showHeader = currentGroup != prevGroup;

                      return _AnimatedHistoryItem(
                        index: i,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showHeader)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 20, 16, 6),
                                child: Text(
                                  currentGroup,
                                  style: TextStyle(
                                    color: AurumTheme.textMutedOf(context),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            SongTile(
                                song: song,
                                queue: history,
                                index: i),
                          ],
                        ),
                      );
                    },
                    childCount: history.length,
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 100)),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ── Animated history list item ─────────────────────────────────────────────────
class _AnimatedHistoryItem extends StatefulWidget {
  final int index;
  final Widget child;
  const _AnimatedHistoryItem({required this.index, required this.child});

  @override
  State<_AnimatedHistoryItem> createState() => _AnimatedHistoryItemState();
}

class _AnimatedHistoryItemState extends State<_AnimatedHistoryItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    final cappedIndex = widget.index.clamp(0, 15);
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    Future.delayed(Duration(milliseconds: 30 + cappedIndex * 40), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Local Files Screen (unchanged)
// ══════════════════════════════════════════════════════════════════════════════
class _LocalFilesScreen extends StatelessWidget {
  const _LocalFilesScreen();

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        title: Text('Local Files',
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded,
              color: AurumTheme.textPrimaryOf(context)),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AurumTheme.gold),
            onPressed: () => lib.refresh(),
          ),
        ],
      ),
      body: lib.status == LibraryStatus.loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: AurumM3Loader()))
          : lib.status == LibraryStatus.noPermission
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AurumTheme.bgElevatedOf(context),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AurumTheme.gold.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.folder_rounded,
                            color: AurumTheme.gold, size: 32),
                      ),
                      const SizedBox(height: 20),
                      Text('Permission Required',
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('Aurum needs permission to read your music.',
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 13)),
                      const SizedBox(height: 20),
                      AurumPressable(
                        onTap: () => lib.load(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 12),
                          decoration: BoxDecoration(
                            gradient: AurumTheme.goldGradient,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Text('Grant Permission',
                              style: TextStyle(
                                  color: AurumTheme.bg,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                )
              : lib.allSongs.isEmpty
                  ? Center(
                      child: Text('No local songs found',
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context))))
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 100),
                      itemCount: lib.allSongs.length,
                      itemExtent: 66,
                      itemBuilder: (_, i) => SongTile(
                          song: lib.allSongs[i],
                          queue: lib.allSongs,
                          index: i),
                    ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Downloads Screen (unchanged, kept public for NavigatorKey usage in main.dart)
// ══════════════════════════════════════════════════════════════════════════════
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadProvider>();
    final inProgress = downloads.inProgress;
    final completed = downloads.completed;
    final isEmpty = inProgress.isEmpty && completed.isEmpty;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded,
                  color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: Row(
                children: [
                  const Icon(Icons.download_rounded,
                      color: AurumTheme.gold, size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) =>
                        AurumTheme.goldGradient.createShader(b),
                    child: const Text('Downloads',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          if (isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: AurumTheme.gold.withOpacity(0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: AurumTheme.gold.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.download_rounded,
                            color: AurumTheme.gold, size: 36),
                      ),
                      const SizedBox(height: 20),
                      Text('No downloads yet',
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                        'Download a song from the player to listen offline.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 13,
                            height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            if (inProgress.isNotEmpty) ...[
              SliverToBoxAdapter(child: _sectionHeader(context, 'DOWNLOADING')),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _DownloadTile(item: inProgress[i]),
                  childCount: inProgress.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
            if (completed.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _sectionHeader(
                      context, '${completed.length} DOWNLOADED')),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _DownloadTile(item: completed[i]),
                  childCount: completed.length,
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(title,
          style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5)),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  const _DownloadTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final song = item.song;
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: item.isDownloading ? 0.4 : 1.0,
              child: AurumArtwork(url: song.artworkUrl, size: 48, borderRadius: 8),
            ),
            if (item.isDownloading)
              SizedBox(
                width: 22,
                height: 22,
                child: Center(
                  child: AurumM3Loader(
                    width: 22,
                    height: 2.5,
                  ),
                ),
              ),
          ],
        ),
      ),
      title: Text(song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 14,
              fontWeight: FontWeight.w600)),
      subtitle: item.isDownloading
          ? Text(
              'Downloading • ${(item.progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: AurumTheme.gold, fontSize: 12))
          : item.isFailed
              ? const Text('Failed — tap to retry',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12))
              : Text(song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AurumTheme.textMutedOf(context), fontSize: 12)),
      trailing: item.isDownloading
          ? IconButton(
              icon: Icon(Icons.close_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onPressed: () =>
                  context.read<DownloadProvider>().cancelDownload(song.id),
            )
          : PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              color:
                  isLight ? AurumTheme.lightBgCard : AurumTheme.darkBgCard,
              onSelected: (value) {
                final dl = context.read<DownloadProvider>();
                if (value == 'delete') {
                  dl.deleteDownload(song.id);
                } else if (value == 'retry') {
                  dl.retry(song);
                }
              },
              itemBuilder: (_) => [
                if (item.isFailed)
                  const PopupMenuItem(value: 'retry', child: Text('Retry')),
                const PopupMenuItem(
                    value: 'delete', child: Text('Remove download')),
              ],
            ),
      onTap: () {
        if (item.isFailed) {
          context.read<DownloadProvider>().retry(song);
        } else if (item.isCompleted) {
          final offlineSong =
              context.read<DownloadProvider>().offlineSongFor(song.id) ?? song;
          context.read<PlayerProvider>().playSong(offlineSong);
        }
      },
    );
  }
}

// ── Coming-soon stubs (Albums / Artists) ──────────────────────────────────────

class _AlbumsScreen extends StatelessWidget {
  const _AlbumsScreen();
  @override
  Widget build(BuildContext context) => _ComingSoonScreen(
        title: 'Albums',
        icon: Icons.album_rounded,
        color: Colors.deepPurple,
        message: 'Albums you save will appear here.',
      );
}

class _ArtistsScreen extends StatelessWidget {
  const _ArtistsScreen();

  @override
  Widget build(BuildContext context) {
    final followed = context.watch<FollowedArtistsProvider>().followed;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded,
                  color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: Row(
                children: [
                  const Icon(Icons.person_rounded,
                      color: Colors.blueAccent, size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) =>
                        AurumTheme.goldGradient.createShader(b),
                    child: const Text('Artists',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          if (followed.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: Colors.blueAccent.withOpacity(0.1),
                          shape: BoxShape.circle,
                          border:
                              Border.all(color: Colors.blueAccent.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.person_rounded,
                            color: Colors.blueAccent, size: 36),
                      ),
                      const SizedBox(height: 20),
                      Text('No artists saved yet',
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text('Artists you follow will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 13,
                              height: 1.5)),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _FollowedArtistTile(artist: followed[i]),
                  childCount: followed.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FollowedArtistTile extends StatelessWidget {
  final Map<String, dynamic> artist;
  const _FollowedArtistTile({required this.artist});

  @override
  Widget build(BuildContext context) {
    final id = (artist['id'] ?? '').toString();
    final name = (artist['name'] ?? '').toString();
    final imageUrl = (artist['imageUrl'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            HapticFeedback.selectionClick();
            AurumPageRoute.to(
              context,
              ArtistScreen(artistId: id, artistName: name),
            );
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            _showUnfollowSheet(context, id, name, imageUrl);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AurumTheme.goldGradient,
                  ),
                  child: ClipOval(
                    child: AurumArtwork(url: imageUrl, size: 54, borderRadius: 27),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.check_circle_rounded,
                              size: 13, color: AurumTheme.gold.withOpacity(0.85)),
                          const SizedBox(width: 4),
                          Text(
                            'Artist',
                            style: TextStyle(
                              color: AurumTheme.textMutedOf(context),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.more_vert_rounded,
                      color: AurumTheme.textMutedOf(context)),
                  onPressed: () => _showUnfollowSheet(context, id, name, imageUrl),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showUnfollowSheet(
      BuildContext context, String id, String name, String imageUrl) {
    final rootContext = context;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgElevatedOf(rootContext),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipOval(
                  child: AurumArtwork(url: imageUrl, size: 44, borderRadius: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(rootContext),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_remove_rounded,
                  color: Colors.redAccent),
              title: const Text('Unfollow artist'),
              onTap: () {
                Navigator.pop(sheetContext);
                rootContext.read<FollowedArtistsProvider>().toggleFollow(
                      artistId: id,
                      name: name,
                      imageUrl: imageUrl,
                    );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonScreen extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String message;
  const _ComingSoonScreen(
      {required this.title,
      required this.icon,
      required this.color,
      required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            leading: IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded,
                  color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: Row(
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) =>
                        AurumTheme.goldGradient.createShader(b),
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          SliverFillRemaining(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: color.withOpacity(0.3)),
                      ),
                      child: Icon(icon, color: color, size: 36),
                    ),
                    const SizedBox(height: 20),
                    Text('Coming Soon',
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context),
                            fontSize: 13,
                            height: 1.5)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────────────────────────

class _QuickChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _QuickChip(
      {required this.icon,
      required this.label,
      required this.color,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: color.withOpacity(0.11),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _CollectionItem {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _CollectionItem(
      {required this.icon,
      required this.label,
      required this.subtitle,
      required this.color,
      this.onTap});
}

// Tonal glass card — each collection row now sits on its own subtle
// surface (gradient wash in the item's accent colour, hairline border,
// soft shadow) rather than sitting flat on the page background with only
// a divider line beneath it. This is what gives the "shelf of premium
// tiles" feel instead of a plain settings list.
class _CollectionRow extends StatefulWidget {
  final _CollectionItem item;
  const _CollectionRow({required this.item});

  @override
  State<_CollectionRow> createState() => _CollectionRowState();
}

class _CollectionRowState extends State<_CollectionRow> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isLight = Theme.of(context).brightness == Brightness.light;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: () {
        HapticFeedback.selectionClick();
        item.onTap?.call();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                item.color.withOpacity(_pressed ? 0.14 : (isLight ? 0.07 : 0.09)),
                item.color.withOpacity(_pressed ? 0.05 : 0.02),
              ],
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: item.color.withOpacity(isLight ? 0.14 : 0.16),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isLight ? 0.03 : 0.14),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: item.color.withOpacity(isLight ? 0.14 : 0.16),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(item.icon, color: item.color, size: 19),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(item.label,
                    style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (item.subtitle.isNotEmpty) ...[
                Text(item.subtitle,
                    style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
              ],
              Icon(Icons.chevron_right_rounded,
                  color: AurumTheme.textMutedOf(context).withOpacity(0.5),
                  size: 19),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Cover fan ────────────────────────────────────────────────────────────
// Small fanned stack of the last few played covers — the one deliberately
// "alive" element on this screen. Each tile is rotated a few degrees off
// the last so it reads as a loosely-thrown handful of records, not a
// perfectly stacked app icon.
//
// Empty state: previously used Icons.auto_awesome_rounded (a sparkle
// glyph), which reads as a generic "AI-generated content" placeholder —
// exactly the look we don't want. Replaced with a plain white
// Icons.music_note_rounded, matching Aurum's own logo mark, so a brand-
// new user with no history yet still sees something that looks like it
// belongs to this app specifically, not a stock AI-tool icon.
class _CoverFan extends StatelessWidget {
  final List<Song> covers;
  const _CoverFan({required this.covers});

  static const List<double> _angles = [-10, 6, -4, 9];

  @override
  Widget build(BuildContext context) {
    const double size = 62;
    if (covers.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AurumTheme.gold.withOpacity(0.22),
              Colors.purpleAccent.withOpacity(0.18),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.music_note_rounded,
            color: Colors.white, size: 26),
      );
    }

    return SizedBox(
      width: size + 14,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: List.generate(covers.length, (i) {
          final depth = covers.length - 1 - i; // draw back-to-front
          final angle = _angles[depth % _angles.length] * (math.pi / 180);
          return Positioned(
            left: depth * 4.5,
            top: 0,
            child: Transform.rotate(
              angle: angle,
              alignment: Alignment.bottomLeft,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.22),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: AurumArtwork(
                  url: covers[depth].artworkUrl,
                  size: size - 6,
                  borderRadius: 12,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
