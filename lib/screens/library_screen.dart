// =============================================================================
// FILE: lib/screens/library_screen.dart
// PROJECT: Astra Music
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
import 'dart:async';
import 'dart:ui';
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../l10n/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../providers/download_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/api_service.dart' show YtPlaylistImportException, YtPlaylistImportError;
import '../providers/premium_provider.dart';
import '../providers/auth_provider.dart';
import '../services/sync_service.dart';
import '../models/download_item.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_stacked_artwork.dart';
import '../widgets/aurum_cover_color.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/mini_player_slot.dart';
import 'full_player_screen.dart';
import '../widgets/premium_gate.dart';
import '../models/song.dart';
import '../utils/aurum_transitions.dart';
import 'settings_screen.dart';
import 'liked_screen.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/followed_albums_provider.dart';
import 'artist_screen.dart';
import 'album_screen.dart';
import 'mix_screen.dart';
import '../widgets/aurum_focus_field.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_motion.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Library Root
// ══════════════════════════════════════════════════════════════════════════════

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // extendBody: true — matches MainShell's outer Scaffold + the same
      // fix in search_screen.dart, so Library also scrolls under the
      // floating glass nav bar instead of stopping at a flat strip.
      extendBody: true,
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
                _buildSectionLabel(context, l10n.libraryCollection),
                const SizedBox(height: 4),
                _buildCollectionList(context),
                const SizedBox(height: 26),
                _buildSectionLabel(context, l10n.libraryRecentlyPlayed),
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
    final l10n = AppLocalizations.of(context)!;
    return SliverAppBar(
      expandedHeight: 90,
      floating: true,
      snap: true,
      backgroundColor: AurumTheme.bgOf(context),
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          icon: Icon(Icons.link_rounded,
              color: AurumTheme.textSecondaryOf(context)),
          tooltip: l10n.libraryImportFromYoutube,
          onPressed: () {
            AurumHaptics.light();
            showDialog(
              context: context,
              builder: (_) => _ImportYtPlaylistDialog(),
            );
          },
        ),
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          // FIX ("liked/local/playlist se bahar aane par jo animation
          // chalta hai, wahi Settings mein bhi chahiye"): Settings used
          // AurumPageRoute — a full iOS-style horizontal slide-in-from-
          // right with parallax on the screen behind. Liked Songs,
          // Downloads, History, Playlist Detail, and Local Files all use
          // AurumDepthRoute instead — the fade + small slide-up transition
          // (with a correctly-animated pop/exit, see that route's own
          // fix comment in aurum_transitions.dart). Switching Settings to
          // AurumDepthRoute makes its push/pop match those screens
          // exactly instead of using a different transition than the
          // rest of Library's own destinations.
          onPressed: () => AurumDepthRoute.to(context, const SettingsScreen()),
        ),
        // Everything Settings opens onto from here (Player/Appearance/
        // Language/Storage/Notifications/Privacy/About/Premium, plus the
        // Profile screen) now also uses AurumDepthRoute — see
        // settings_screen.dart, home_screen.dart, and premium_gate.dart
        // for the matching change, so the whole Settings flow shares one
        // consistent transition end to end, not just the entry point.
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 0, 14),
        title: Text(l10n.navLibrary,
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
    final l10n = AppLocalizations.of(context)!;
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
                    totalTracked == 0 ? l10n.libraryNothingHereYet : l10n.libraryYourCollection,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statLine(l10n, favCount, plCount, followedCount, localCount),
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

  String _statLine(AppLocalizations l10n, int fav, int pl, int artists, int local) {
    final parts = <String>[];
    parts.add(l10n.libraryLikedCount(fav));
    parts.add(l10n.libraryPlaylistCount(pl));
    parts.add(l10n.libraryArtistCount(artists));
    if (local > 0) parts.add(l10n.libraryOnDeviceCount(local));
    return parts.join('  ·  ');
  }

  Widget _buildQuickAccess(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _QuickChip(
            icon: Icons.favorite_rounded,
            label: l10n.libraryLiked,
            color: Colors.pinkAccent,
            onTap: () => AurumDepthRoute.to(context, const LikedScreen()),
          ),
          const SizedBox(width: 8),
          _QuickChip(
            icon: Icons.download_rounded,
            label: l10n.settingsDownloads,
            color: AurumTheme.gold,
            onTap: () => AurumDepthRoute.to(context, const DownloadsScreen()),
          ),
          const SizedBox(width: 8),
          _QuickChip(
            icon: Icons.history_rounded,
            label: l10n.libraryHistory,
            color: Colors.teal,
            onTap: () => AurumDepthRoute.to(context, const _HistoryScreen()),
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
    final l10n = AppLocalizations.of(context)!;
    final favCount = context.watch<FavoritesProvider>().favorites.length;
    final lib = context.watch<LibraryProvider>();
    final plCount = context.watch<PlaylistProvider>().count;
    final followedCount =
        context.watch<FollowedArtistsProvider>().followed.length;
    final followedAlbumsCount =
        context.watch<FollowedAlbumsProvider>().followed.length;

    final items = [
      _CollectionItem(
        icon: Icons.favorite_rounded,
        label: l10n.libraryLikedSongs,
        subtitle: '$favCount',
        color: Colors.pinkAccent,
        onTap: () => AurumDepthRoute.to(context, const LikedScreen()),
      ),
      _CollectionItem(
        icon: Icons.queue_music_rounded,
        label: l10n.libraryPlaylists,
        subtitle: plCount == 0 ? '' : '$plCount',
        color: Colors.purpleAccent,
        onTap: () => AurumDepthRoute.to(context, const PlaylistsScreen()),
      ),
      _CollectionItem(
        icon: Icons.album_rounded,
        label: l10n.libraryAlbums,
        subtitle: followedAlbumsCount == 0 ? '' : '$followedAlbumsCount',
        color: Colors.deepPurple,
        onTap: () => AurumDepthRoute.to(context, const _AlbumsScreen()),
      ),
      _CollectionItem(
        icon: Icons.person_rounded,
        label: l10n.libraryArtists,
        subtitle: followedCount == 0 ? '' : '$followedCount',
        color: Colors.blueAccent,
        onTap: () => AurumDepthRoute.to(context, const _ArtistsScreen()),
      ),
      _CollectionItem(
        icon: Icons.folder_rounded,
        label: l10n.libraryLocalFiles,
        subtitle: lib.hasLoaded ? '${lib.allSongs.length}' : '',
        color: Colors.green,
        onTap: () async {
          if (!lib.hasLoaded) await lib.load();
          if (context.mounted) {
            AurumDepthRoute.to(context, const _LocalFilesScreen());
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
            child: _CollectionRow(item: items[i], chainIndex: i),
          );
        }),
      ),
    );
  }

  Widget _buildRecentlyPlayed(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
              Text(l10n.libraryPlaySomethingToSeeHistory,
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
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SongTile(song: e.value, queue: recent, index: e.key, curatedQueue: true),
              ),
            ),
        if (history.length > 5)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () => AurumDepthRoute.to(context, const _HistoryScreen()),
              child: Text(
                l10n.librarySeeAllSongs(history.length),
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
    final l10n = AppLocalizations.of(context)!;
    return Consumer<PlaylistProvider>(
      builder: (context, pp, _) {
        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
          // matching comment for the full reasoning.
          bottomNavigationBar: const MiniPlayerSlot(),
          // BUGFIX: same "whole app shrinks when keyboard opens" fix as
          // MainShell — the New Playlist dialog is pushed on top of THIS
          // Scaffold, and its default resizeToAvoidBottomInset: true was
          // squeezing the whole playlists list/app-bar upward the moment
          // the dialog's TextField got focus, on top of the dialog's own
          // (correct) keyboard-avoidance. The dialog handles its own
          // resize; this screen doesn't need to.
          resizeToAvoidBottomInset: false,
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
                        child: Text(l10n.libraryPlaylists,
                            style: const TextStyle(
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
                      l10n.libraryPlaylistCount(pp.count),
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
    final l10n = AppLocalizations.of(context)!;
    PremiumGate.guard(
      context,
      feature: l10n.libraryCreatePlaylist,
      description: l10n.libraryLoginToOrganizeDesc,
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
  // ── Multi-select state ─────────────────────────────────────────────────
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  void _enterSelectMode(String firstSongId) {
    AurumHaptics.medium();
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(firstSongId);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String songId) {
    AurumHaptics.selection();
    setState(() {
      if (!_selectedIds.remove(songId)) {
        _selectedIds.add(songId);
      }
      // Nothing left selected -> fall back out of select mode gracefully,
      // same as most stock "select" UIs (Photos, Gmail, etc.).
      if (_selectedIds.isEmpty) _selecting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final pp = context.watch<PlaylistProvider>();
    final pl = pp.getById(widget.playlistId);

    if (pl == null) {
      // FIX (recheck): this is the "playlist not found" state (e.g.
      // deleted from another device mid-view), not a loading state — it
      // can persist on screen, so it needs the same MiniPlayerSlot as the
      // normal loaded Scaffold below, otherwise nav bar/mini player
      // vanish for as long as this state is shown.
      return Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        bottomNavigationBar: const MiniPlayerSlot(),
        body: Center(
          child: Text(l10n.libraryPlaylistNotFound,
              style: TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
      );
    }

    // Guard: if songs were removed elsewhere (e.g. another device sync)
    // while a selection was active, drop ids that no longer exist so the
    // count/app-bar never shows a stale number.
    if (_selecting) {
      final validIds = pl.songs.map((s) => s.id).toSet();
      _selectedIds.removeWhere((id) => !validIds.contains(id));
      if (_selectedIds.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _selecting = false);
        });
      }
    }

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelectMode();
      },
      child: Scaffold(
        backgroundColor: AurumTheme.bgOf(context),
        // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
        // matching comment for the full reasoning.
        bottomNavigationBar: const MiniPlayerSlot(),
        body: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // ── Header / Select-mode app bar ──────────────────────────────
            if (_selecting)
              _SelectModeAppBar(
                selectedCount: _selectedIds.length,
                totalCount: pl.songs.length,
                allSelected: _selectedIds.length == pl.songs.length,
                onClose: _exitSelectMode,
                onToggleSelectAll: () {
                  AurumHaptics.light();
                  setState(() {
                    if (_selectedIds.length == pl.songs.length) {
                      _selectedIds.clear();
                    } else {
                      _selectedIds
                        ..clear()
                        ..addAll(pl.songs.map((s) => s.id));
                    }
                  });
                },
                onRemove: () => _confirmRemoveSelected(context, pl),
              )
            else
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
            if (!_selecting)
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
                        Text(l10n.libraryNoSongsYetInPlaylist,
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(l10n.librarySearchAndAddSongsHere,
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
                  if (_selecting) return; // reorder disabled while selecting
                  context
                      .read<PlaylistProvider>()
                      .reorderSong(pl.id, oldIdx, newIdx);
                },
                // FIX (companion to the reorderSong() timing fix): gives the
                // dragged tile a deliberate, premium lift-and-settle instead
                // of Flutter's default proxyDecorator, which wraps the tile
                // in a plain Material with a hard elevation shadow — visually
                // flat/dated next to the rest of Aurum's motion language, and
                // the specific widget most likely to be left as a stray
                // painted frame if a drag is interrupted (e.g. by a fast
                // back-navigation) before its own drop animation finishes.
                // A short, explicit AnimatedScale + AnimatedContainer shadow
                // keyed off `animation` (which Flutter always drives to 0 on
                // drop/cancel, including interrupted drags) ensures there's
                // always a defined "off" state to settle back to rather than
                // whatever Material's internal elevation happened to be
                // mid-flight.
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final t = Curves.easeOut.transform(animation.value);
                      final scale = 1.0 + (0.03 * t);
                      return Transform.scale(
                        scale: scale,
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          elevation: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: AurumTheme.bgCardOf(context),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.28 * t),
                                  blurRadius: 20 * t,
                                  offset: Offset(0, 6 * t),
                                ),
                              ],
                            ),
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: child,
                  );
                },
                itemBuilder: (context, i) {
                  final song = pl.songs[i];
                  final tile = _PlaylistSongTile(
                    song: song,
                    playlist: pl,
                    index: i,
                    selecting: _selecting,
                    selected: _selectedIds.contains(song.id),
                    onEnterSelectMode: () => _enterSelectMode(song.id),
                    onToggleSelected: () => _toggleSelected(song.id),
                  );
                  // Drag handle only makes sense outside select mode —
                  // reordering while multi-selecting is an awkward,
                  // ambiguous gesture combo most apps avoid entirely.
                  if (_selecting) {
                    return KeyedSubtree(
                      key: ValueKey('${pl.id}_${song.id}_$i'),
                      child: tile,
                    );
                  }
                  // FIX ("playlist reorder galat/sahi se nahi hota"): this
                  // used to wrap the ENTIRE tile in
                  // ReorderableDelayedDragStartListener — but the tile's
                  // own ListTile already has its own onTap (play song) AND
                  // onLongPress (enter select mode), both competing with
                  // the reorder drag's long-press-and-hold in the exact
                  // same touch area/gesture arena. onLongPress in
                  // particular almost always won or interfered, so a
                  // press-and-hold-to-drag anywhere on the row read as
                  // "enter select mode" (or nothing coherent) instead of
                  // actually starting a reorder. Restricting the drag
                  // trigger to ONLY the drag_handle icon inside the tile
                  // (same YouTube Music / Spotify pattern already applied
                  // to Queue screen) removes the ambiguity entirely — tap
                  // and long-press elsewhere on the row behave exactly as
                  // before, and the handle is the sole, unambiguous way to
                  // start a drag.
                  return KeyedSubtree(
                    key: ValueKey('${pl.id}_${song.id}_$i'),
                    child: tile,
                  );
                },
              ),

            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemoveSelected(
      BuildContext context, AurumPlaylist pl) async {
    final l10n = AppLocalizations.of(context)!;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(context),
        title: Text(l10n.libraryRemoveSelectedFromPlaylist,
            style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(l10n.libraryRemoveSelectedConfirm(count),
            style: TextStyle(color: AurumTheme.textMutedOf(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel,
                  style:
                      TextStyle(color: AurumTheme.textMutedOf(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.libraryRemoveSelectedFromPlaylist,
                  style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final ids = Set<String>.from(_selectedIds);
      await context.read<PlaylistProvider>().removeSongs(pl.id, ids);
      if (mounted) {
        setState(() {
          _selecting = false;
          _selectedIds.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.libraryRemovedSongsFromPlaylist(ids.length)),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AurumTheme.bgElevatedOf(context),
          ),
        );
      }
    }
  }

  void _showPlaylistOptions(BuildContext context, AurumPlaylist pl) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    showAurumModalBottomSheet(
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
              title: Text(l10n.libraryRenamePlaylist,
                  style:
                      TextStyle(color: AurumTheme.textPrimaryOf(context))),
              onTap: () {
                Navigator.pop(ctx);
                _showRenameDialog(context, pl);
              },
            ),
            // FEATURE ("playlist details mai download ka option, ekdam
            // fast"): downloads every song in this playlist concurrently
            // through the same DownloadProvider.download() path a single
            // manual download already uses — same quality/WiFi settings,
            // same Downloads screen, same offline playback. Hidden when
            // the playlist is empty or already fully downloaded, same as
            // Play/Shuffle above hiding for an empty playlist.
            if (pl.songs.isNotEmpty)
              Builder(builder: (ctx2) {
                final dl = ctx2.watch<DownloadProvider>();
                final allDownloaded =
                    pl.songs.every((s) => dl.isDownloaded(s.id));
                final downloading = dl.isPlaylistDownloading(pl.id);
                if (allDownloaded) return const SizedBox.shrink();
                return ListTile(
                  leading: downloading
                      ? SizedBox(
                          width: 24, height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: AurumTheme.gold,
                            value: () {
                              final (done, total) =
                                  dl.playlistDownloadProgress(pl.songs);
                              return total == 0 ? null : done / total;
                            }(),
                          ),
                        )
                      : const Icon(Icons.download_rounded,
                          color: AurumTheme.gold),
                  title: Text(
                    downloading
                        ? l10n.libraryDownloadingPlaylist
                        : l10n.libraryDownloadPlaylist,
                    style:
                        TextStyle(color: AurumTheme.textPrimaryOf(context)),
                  ),
                  onTap: downloading
                      ? null
                      : () {
                          Navigator.pop(ctx);
                          context.read<DownloadProvider>().downloadPlaylist(
                                playlistId: pl.id,
                                songs: pl.songs,
                              );
                        },
                );
              }),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent),
              title: Text(l10n.libraryDeletePlaylist,
                  style: const TextStyle(color: Colors.redAccent)),
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
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(context),
        title: Text(l10n.libraryDeletePlaylistConfirm(pl.name),
            style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: Text(l10n.libraryActionCannotBeUndone,
            style: TextStyle(color: AurumTheme.textMutedOf(context))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel,
                  style: TextStyle(
                      color: AurumTheme.textMutedOf(context)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.commonDelete,
                  style: const TextStyle(color: Colors.redAccent))),
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
// Select-mode app bar — replaces the artwork header while multi-selecting
// ══════════════════════════════════════════════════════════════════════════════

class _SelectModeAppBar extends StatelessWidget {
  final int selectedCount;
  final int totalCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final VoidCallback onRemove;

  const _SelectModeAppBar({
    required this.selectedCount,
    required this.totalCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SliverAppBar(
      pinned: true,
      backgroundColor: AurumTheme.bgOf(context),
      elevation: 0,
      leading: IconButton(
        icon: Icon(Icons.close_rounded,
            color: AurumTheme.textSecondaryOf(context), size: 22),
        onPressed: onClose,
      ),
      title: Text(
        l10n.librarySelectedCount(selectedCount),
        style: TextStyle(
          color: AurumTheme.textPrimaryOf(context),
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      actions: [
        TextButton(
          onPressed: onToggleSelectAll,
          child: Text(
            allSelected ? l10n.libraryDeselectAll : l10n.librarySelectAll,
            style: TextStyle(
              color: AurumTheme.gold,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.delete_outline_rounded,
              color: selectedCount == 0
                  ? AurumTheme.textMutedOf(context).withOpacity(0.4)
                  : Colors.redAccent),
          onPressed: selectedCount == 0 ? null : onRemove,
        ),
        const SizedBox(width: 4),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AurumTheme.textMutedOf(context).withOpacity(0.1),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Playlist Header (large artwork + info)
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistHeader extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistHeader({required this.playlist});

  // CHANGE ("ek option daal do playlist mai users kud se gallery se
  // playlist ka wallpaper chose kr sakhe ekdam production level"): opens
  // the gallery via image_picker, hands the picked file off to
  // PlaylistProvider.setCoverImage (which copies it into app storage and
  // persists it), and — if a custom cover is already set — offers Remove
  // as a second option instead of only ever letting you add one. Matches
  // the long-press-free, single-tap-on-the-artwork pattern Spotify uses
  // for playlist cover editing rather than burying it in a menu.
  Future<void> _changeCover(BuildContext context) async {
    final provider = context.read<PlaylistProvider>();
    final l10n = AppLocalizations.of(context)!;

    final action = await showAurumModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgElevatedOf(ctx),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AurumTheme.textMutedOf(ctx).withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(Icons.photo_library_rounded,
                    color: AurumTheme.gold),
                title: Text(l10n.libraryChooseFromGallery,
                    style: TextStyle(
                        color: AurumTheme.textPrimaryOf(ctx),
                        fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx, 'pick'),
              ),
              if (playlist.hasCustomCover)
                ListTile(
                  leading:
                      const Icon(Icons.restore_rounded, color: Colors.redAccent),
                  title: Text(l10n.libraryRemoveCustomCover,
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(ctx),
                          fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(ctx, 'remove'),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (action == 'pick') {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 90,
        // Cap the longest edge — playlist covers only ever render up to
        // 180px in-app; a full 12MP camera photo would just waste disk
        // space and slow the copy for zero visible benefit.
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (picked != null) {
        await provider.setCoverImage(playlist.id, picked.path);
      }
    } else if (action == 'remove') {
      await provider.clearCoverImage(playlist.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasArt = playlist.coverArt != null && playlist.coverArt!.isEmpty == false;

    return GestureDetector(
      onTap: () => _changeCover(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── Layer 1 — full-bleed background, edge to edge ────────────────
          // SimpMusic/YT Music-style: the artwork (or, with no cover set,
          // the automatic artwork-derived gradient) fills the ENTIRE
          // header, not a small floating square centered on flat black.
          // Real photos are scaled up and blurred slightly so they still
          // read as a rich backdrop rather than a sharp, cropped close-up.
          hasArt
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    Transform.scale(
                      scale: 1.15,
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: AurumArtwork(
                          url: playlist.coverArt!,
                          size: double.infinity,
                          borderRadius: 0,
                          fadeIn: false,
                        ),
                      ),
                    ),
                    // Sharp, centered focal copy on top of the blurred fill
                    // — same layered look Full Player uses: soft color
                    // everywhere at the edges, a crisp image where the eye
                    // actually lands.
                    Center(
                      child: Container(
                        width: 190,
                        height: 190,
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 26,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: AurumArtwork(
                            url: playlist.coverArt!,
                            size: 190,
                            borderRadius: 18,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : PlaylistColorCover(
                  artworkUrl:
                      playlist.songs.isNotEmpty ? playlist.songs.first.artworkUrl : '',
                  size: double.infinity,
                  borderRadius: 0,
                  iconSize: 72,
                ),

          // ── Layer 2 — bottom gradient scrim so title/chrome stay
          // readable over any artwork, same handoff MixScreen's header
          // uses (near-opaque black just before the seam so light mode's
          // warm-cream body color never creates a visible jump).
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.05),
                  Colors.black.withOpacity(0.15),
                  Colors.black.withOpacity(0.55),
                  Colors.black.withOpacity(0.90),
                  AurumTheme.bgOf(context),
                ],
                stops: const [0.0, 0.30, 0.68, 0.90, 1.0],
              ),
            ),
          ),

          // ── Edit affordance — small pill, bottom-right, signals the
          // whole header is tappable without needing a hint/tooltip.
          Positioned(
            right: 16,
            bottom: 76,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                shape: BoxShape.circle,
                border:
                    Border.all(color: Colors.white.withOpacity(0.15), width: 1),
              ),
              child: const Icon(Icons.edit_rounded, color: Colors.white, size: 16),
            ),
          ),

          // ── Title + description + summary, stacked at the bottom over
          // the artwork's lower half — matches MixScreen's header exactly.
          Positioned(
            left: 24,
            right: 24,
            bottom: 18,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  playlist.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 10)],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (playlist.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    playlist.description,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.85),
                      fontSize: 13,
                      shadows: const [
                        Shadow(color: Colors.black45, blurRadius: 6),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${playlist.songCount} song${playlist.songCount == 1 ? '' : 's'}'
                  '${playlist.totalDurationString.isNotEmpty ? ' • ${playlist.totalDurationString}' : ''}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    shadows: const [Shadow(color: Colors.black45, blurRadius: 6)],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Mosaic 2×2 cover grid
// ══════════════════════════════════════════════════════════════════════════════
// Action Row (Play All / Shuffle)
// ══════════════════════════════════════════════════════════════════════════════

class _PlaylistActionRow extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistActionRow({required this.playlist});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (playlist.songs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
      Row(
        children: [
          // Play All
          Expanded(
            child: AurumPressable(
              onTap: () {
                context.read<PlayerProvider>().playSong(
                      playlist.songs[0],
                      queue: playlist.songs,
                      index: 0,
                      curatedQueue: true,
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
                    Text(l10n.commonPlay,
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
                      curatedQueue: true,
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
                    Text(l10n.commonShuffle,
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
      // Inline "downloading playlist" progress — visible right under
      // Play/Shuffle without needing to open the overflow menu, same
      // pattern as the Downloads screen's own per-song progress rows.
      Builder(builder: (ctx2) {
        final dl = ctx2.watch<DownloadProvider>();
        if (!dl.isPlaylistDownloading(playlist.id)) {
          return const SizedBox.shrink();
        }
        final (done, total) = dl.playlistDownloadProgress(playlist.songs);
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AurumTheme.gold,
                  value: total == 0 ? null : done / total,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context)!
                    .libraryDownloadPlaylistProgress(done, total),
                style: TextStyle(
                    color: AurumTheme.textMutedOf(context), fontSize: 12),
              ),
            ],
          ),
        );
      }),
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
  final bool selecting;
  final bool selected;
  final VoidCallback? onEnterSelectMode;
  final VoidCallback? onToggleSelected;

  const _PlaylistSongTile({
    required this.song,
    required this.playlist,
    required this.index,
    this.selecting = false,
    this.selected = false,
    this.onEnterSelectMode,
    this.onToggleSelected,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isCurrentSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == song.id,
    );
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Container(
      color: selected ? AurumTheme.gold.withOpacity(0.08) : null,
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: AnimatedSwitcher(
          duration: AurumMotion.durationOrZero(AurumMotion.medium1),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: selecting
              ? SizedBox(
                  key: const ValueKey('checkbox'),
                  width: 48,
                  height: 48,
                  child: Center(
                    child: AnimatedContainer(
                      duration: AurumMotion.durationOrZero(AurumMotion.short2),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: selected ? AurumTheme.goldGradient : null,
                        color: selected
                            ? null
                            : AurumTheme.bgCardOf(context),
                        border: Border.all(
                          color: selected
                              ? Colors.transparent
                              : AurumTheme.textMutedOf(context)
                                  .withOpacity(0.4),
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? Icon(Icons.check_rounded,
                              size: 16, color: AurumTheme.bgOf(context))
                          : null,
                    ),
                  ),
                )
              : ClipRRect(
                  key: const ValueKey('artwork'),
                  borderRadius: BorderRadius.circular(8),
                  child: AurumArtwork(
                      url: song.artworkUrl, size: 48, borderRadius: 8),
                ),
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
        trailing: selecting
            ? null
            : Row(
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
                      } else if (value == 'select') {
                        onEnterSelectMode?.call();
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'select',
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline_rounded,
                                color: AurumTheme.gold, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.libraryEnterSelectMode,
                                style: TextStyle(
                                    color: AurumTheme.textPrimaryOf(context),
                                    fontSize: 14)),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Row(
                          children: [
                            const Icon(Icons.remove_circle_outline_rounded,
                                color: Colors.redAccent, size: 18),
                            const SizedBox(width: 8),
                            Text(l10n.libraryRemoveFromPlaylist,
                                style: TextStyle(
                                    color: AurumTheme.textPrimaryOf(context),
                                    fontSize: 14)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Drag handle
                  selecting
                      ? const SizedBox.shrink()
                      : ReorderableDragStartListener(
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle_rounded,
                                color: AurumTheme.textMutedOf(context)
                                    .withOpacity(0.5),
                                size: 20),
                          ),
                        ),
                ],
              ),
        // FIX (same class as song_tile.dart's InkWell fix — "cold start
        // pe kisi bhi title tap karo, grey/white layer aa jaata hai"):
        // playlist song list's ListTile had no explicit splash/highlight
        // color, same unthemed Material default as the other fixed
        // tiles. Same theme-correct, low-opacity fix closes it here too.
        splashColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.06),
        focusColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.04),
        hoverColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.04),
        onTap: () {
          if (selecting) {
            onToggleSelected?.call();
            return;
          }
          AurumHaptics.light();
          // SPOTIFY-STYLE FIX ("kahi se bhi full player na khule"): tap
          // now only starts playback — mini player is the tap feedback,
          // matching every other song-tapping surface in the app.
          context.read<PlayerProvider>().playSong(
                song,
                queue: playlist.songs,
                index: index,
                curatedQueue: true,
              ).catchError((e) {
            debugPrint('[_PlaylistSongTile] playSong error: $e');
          });
        },
        onLongPress: selecting ? null : onEnterSelectMode,
      ),
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
      onTap: () => AurumDepthRoute.to(
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
                child: playlist.coverArt == null || playlist.coverArt!.isEmpty
                    ? PlaylistColorCover(
                        artworkUrl: playlist.songs.isNotEmpty
                            ? playlist.songs.first.artworkUrl
                            : '',
                        size: 56,
                        borderRadius: 10,
                      )
                    : AurumArtwork(
                        url: playlist.coverArt!,
                        size: 56,
                        borderRadius: 10),
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
    final l10n = AppLocalizations.of(context)!;
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
            Text(l10n.libraryNoPlaylistsYet,
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              l10n.libraryCreateFirstPlaylistDesc,
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
                    Text(l10n.libraryCreatePlaylist,
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
  // Keyboard-focus timing (autofocus-during-dialog-entrance-animation
  // bug) is handled centrally by AurumFocusField now — see that file for
  // the full history. Don't re-add a FocusNode/autofocus here directly.
  bool _creating = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // BUGFIX: "keyboard opens then closes instantly" (playlist create).
      // The focus-timing fix above (waiting for the route's own enter
      // animation before requesting focus) fixed the route-transition
      // race, but this AlertDialog had no scrollable/resize handling at
      // all — unlike the feedback dialog, which absorbs the keyboard via
      // AnimatedPadding + SingleChildScrollView. Without that, the
      // keyboard rising delivered an abrupt, un-animated layout change to
      // the just-focused TextField instead of a smooth one, which could
      // still read as an instant open-then-close. scrollable:true makes
      // AlertDialog wrap its content in a SingleChildScrollView
      // internally, so it resizes smoothly with the keyboard instead of
      // fighting it.
      scrollable: true,
      title: Text(l10n.libraryNewPlaylist,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AurumFocusField(
            builder: (focusNode) => _AurumTextField(
              controller: _nameCtrl,
              focusNode: focusNode,
              label: l10n.libraryPlaylistNameLabel,
            ),
          ),
          const SizedBox(height: 12),
          _AurumTextField(
            controller: _descCtrl,
            label: l10n.libraryDescriptionOptionalLabel,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel,
              style:
                  TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
        AurumPressable(
          onTap: _creating ? null : () => _create(l10n),
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
                : Text(l10n.commonCreate,
                    style: TextStyle(
                        color: AurumTheme.bgOf(context),
                        fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Future<void> _create(AppLocalizations l10n) async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _nameCtrl.text = l10n.libraryDefaultPlaylistName;
    }
    setState(() => _creating = true);
    final pl = await context.read<PlaylistProvider>().createPlaylist(
          name: _nameCtrl.text.trim().isEmpty
              ? l10n.libraryDefaultPlaylistName
              : _nameCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          initialSong: widget.initialSong,
        );
    if (mounted) {
      Navigator.pop(context);
      // Navigate directly to the new playlist
      AurumDepthRoute.to(
        context,
        PlaylistDetailScreen(playlistId: pl.id),
      );
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Import from YouTube Dialog
// ══════════════════════════════════════════════════════════════════════════════
//
// Mirrors _CreatePlaylistDialog's structure/chrome exactly (same
// AlertDialog shape, same gold-gradient action button, same
// AurumFocusField keyboard-timing fix, same scrollable:true for
// keyboard-safe resizing) so this reads as a native part of the app
// rather than a bolted-on feature — the person creating a playlist and
// the person importing one should see the same visual language.
//
// Three states surfaced inline, no separate error dialog/snackbar
// needed for the common case:
//   1. idle        — paste field + Import button
//   2. importing    — button shows the same AurumM3Loader spinner
//                     _CreatePlaylistDialog uses while creating
//   3. error        — inline red helper text under the field explaining
//                     what went wrong (invalid link vs. empty playlist),
//                     field stays editable so the person can just fix
//                     the pasted text and retry without reopening
//                     anything.
class _ImportYtPlaylistDialog extends StatefulWidget {
  const _ImportYtPlaylistDialog();

  @override
  State<_ImportYtPlaylistDialog> createState() =>
      _ImportYtPlaylistDialogState();
}

class _ImportYtPlaylistDialogState extends State<_ImportYtPlaylistDialog> {
  final _linkCtrl = TextEditingController();
  bool _importing = false;
  String? _errorText;

  @override
  void dispose() {
    _linkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      scrollable: true,
      title: Text(l10n.libraryImportFromYoutube,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.libraryImportFromYoutubeDesc,
            style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          AurumFocusField(
            builder: (focusNode) => _AurumTextField(
              controller: _linkCtrl,
              focusNode: focusNode,
              label: l10n.libraryYoutubePlaylistLinkLabel,
            ),
          ),
          if (_errorText != null) ...[
            const SizedBox(height: 8),
            Text(
              _errorText!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel,
              style: TextStyle(color: AurumTheme.textMutedOf(context))),
        ),
        AurumPressable(
          onTap: _importing ? null : () => _import(l10n),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              gradient: AurumTheme.goldGradient,
              borderRadius: BorderRadius.circular(20),
            ),
            child: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: Center(child: AurumM3Loader(width: 16, height: 2)))
                : Text(l10n.commonImport,
                    style: TextStyle(
                        color: AurumTheme.bgOf(context),
                        fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }

  Future<void> _import(AppLocalizations l10n) async {
    final link = _linkCtrl.text.trim();
    if (link.isEmpty) {
      setState(() => _errorText = l10n.libraryYoutubeLinkEmptyError);
      return;
    }
    setState(() {
      _importing = true;
      _errorText = null;
    });
    AurumPlaylist? playlist;
    String errorMessage = l10n.libraryYoutubeImportFailedError;
    try {
      playlist =
          await context.read<PlaylistProvider>().importYtPlaylist(link);
    } on YtPlaylistImportException catch (e) {
      errorMessage = switch (e.reason) {
        YtPlaylistImportError.invalidLink =>
          l10n.libraryYoutubeImportInvalidLinkError,
        YtPlaylistImportError.isMix => l10n.libraryYoutubeImportMixError,
        YtPlaylistImportError.network =>
          l10n.libraryYoutubeImportNetworkError,
        YtPlaylistImportError.empty ||
        YtPlaylistImportError.notFound =>
          l10n.libraryYoutubeImportFailedError,
      };
      playlist = null;
    } catch (_) {
      playlist = null;
    }
    if (!mounted) return;
    if (playlist == null) {
      setState(() {
        _importing = false;
        _errorText = errorMessage;
      });
      return;
    }
    Navigator.pop(context);
    AurumDepthRoute.to(
      context,
      PlaylistDetailScreen(playlistId: playlist.id),
    );
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
  // Keyboard-focus timing (autofocus-during-dialog-entrance-animation
  // bug) is handled centrally by AurumFocusField now — see that file for
  // the full history. Don't re-add a FocusNode/autofocus here directly.

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
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AurumTheme.bgElevatedOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // BUGFIX: same keyboard-jolt fix as _CreatePlaylistDialog above —
      // see the comment there for the full explanation.
      scrollable: true,
      title: Text(l10n.libraryEditPlaylist,
          style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontWeight: FontWeight.w800)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AurumFocusField(
            builder: (focusNode) => _AurumTextField(
              controller: _nameCtrl,
              focusNode: focusNode,
              label: l10n.libraryPlaylistNameLabel,
            ),
          ),
          const SizedBox(height: 12),
          _AurumTextField(
              controller: _descCtrl, label: l10n.libraryDescriptionOptionalLabel),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel,
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
            child: Text(l10n.commonSave,
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
  final l10n = AppLocalizations.of(context)!;

  await showAurumModalBottomSheet(
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
                            Text(l10n.libraryAddToPlaylist,
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
                  title: Text(l10n.libraryNewPlaylistLower,
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontWeight: FontWeight.w600)),
                  onTap: () {
                    PremiumGate.guard(
                      context,
                      feature: l10n.libraryCreatePlaylist,
                      description: l10n.libraryLoginToOrganizeDesc,
                      requiresLoginOnly: true,
                      onAllowed: () {
                        Navigator.pop(ctx);
                        // FIX (root cause of "playlist won't open / keyboard
                        // doesn't open" when creating from this sheet):
                        // popping this bottom sheet and immediately calling
                        // showDialog ran both routes' enter/exit
                        // transitions at the same time. _CreatePlaylistDialog
                        // already waits for its OWN route animation to
                        // complete before requesting focus, but that
                        // detection is far more reliable when there isn't a
                        // second route transition (this sheet closing)
                        // simultaneously in flight on the same Navigator.
                        // A post-frame callback (a real frame-boundary
                        // guarantee, not a timing guess) lets the sheet's
                        // pop fully register first, so the create dialog
                        // opens into a calm navigator stack instead of a
                        // mid-transition one.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!context.mounted) return;
                          showDialog(
                            context: context,
                            builder: (_) =>
                                _CreatePlaylistDialog(initialSong: song),
                          );
                        });
                      },
                    );
                  },
                ),
                // Existing playlists
                Expanded(
                  child: pp.playlists.isEmpty
                      ? Center(
                          child: Text(l10n.libraryNoPlaylistsYet,
                              style: TextStyle(
                                  color: AurumTheme.textMutedOf(context))))
                      : ListView.builder(
                          controller: scrollCtrl,
                          physics: const BouncingScrollPhysics(),
                          // PERF: pop-in fix for the playlist picker list.
                          cacheExtent: 600,
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
                                  child: pl.coverArt == null || pl.coverArt!.isEmpty
                                      ? PlaylistColorCover(
                                          artworkUrl: pl.songs.isNotEmpty
                                              ? pl.songs.first.artworkUrl
                                              : '',
                                          size: 44,
                                          borderRadius: 8,
                                        )
                                      : AurumArtwork(
                                          url: pl.coverArt!,
                                          size: 44,
                                          borderRadius: 8),
                                ),
                              ),
                              title: Text(pl.name,
                                  style: TextStyle(
                                      color: AurumTheme.textPrimaryOf(context),
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text(
                                  l10n.librarySongsCount(pl.songCount),
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
                                              ? l10n.libraryAddedToPlaylist(pl.name)
                                              : l10n.libraryAlreadyInPlaylist(pl.name)),
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
  final FocusNode? focusNode;

  const _AurumTextField({
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
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
      duration: AurumMotion.durationOrZero(AurumMotion.long2),
    )..forward();
    _headerFade = CurvedAnimation(parent: _headerCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    super.dispose();
  }

  // ── Time label helpers ─────────────────────────────────────────────────────
  static String _groupLabel(int index, int total, AppLocalizations l10n) {
    if (index == 0) return l10n.libraryHistoryJustNow;
    if (index < 5) return l10n.libraryHistoryRecent;
    if (index < 15) return l10n.libraryHistoryEarlierToday;
    if (index < 30) return l10n.libraryHistoryYesterday;
    return l10n.libraryHistoryOlder;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<RecentlyPlayedProvider>(
      builder: (context, rp, _) {
        final history = rp.history;

        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
          // matching comment for the full reasoning.
          bottomNavigationBar: const MiniPlayerSlot(),
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
                          tooltip: l10n.commonShuffle,
                          onPressed: () {
                            AurumHaptics.selection();
                            final shuffled = [...history]..shuffle();
                            context.read<PlayerProvider>().playSong(
                                shuffled[0],
                                queue: shuffled,
                                index: 0,
                                curatedQueue: true);
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
                      Text(
                        l10n.libraryRecentlyPlayed,
                        style: const TextStyle(
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
                        Text(l10n.libraryNoHistoryYet,
                            style: TextStyle(
                                color: AurumTheme.textPrimaryOf(context),
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text(l10n.librarySongsYouPlayAppearHere,
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
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Row(children: [
                        Text(
                          l10n.librarySongsCount(history.length),
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
                                index: 0,
                                curatedQueue: true);
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
                              Text(l10n.commonPlayAll,
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
                                title: Text(l10n.libraryClearHistoryTitle,
                                    style: TextStyle(
                                        color:
                                            AurumTheme.textPrimaryOf(context),
                                        fontWeight: FontWeight.w800)),
                                content: Text(
                                    l10n.libraryClearHistoryConfirm(history.length),
                                    style: TextStyle(
                                        color:
                                            AurumTheme.textMutedOf(context))),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text(l10n.commonCancel,
                                          style: TextStyle(
                                              color: AurumTheme
                                                  .textMutedOf(context)))),
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, true),
                                      child: Text(l10n.commonClear,
                                          style: const TextStyle(
                                              color: Colors.redAccent))),
                                ],
                              ),
                            );
                            if (confirmed == true && context.mounted) {
                              await context
                                  .read<RecentlyPlayedProvider>()
                                  .clearHistory();
                              // Also wipe cloud-side, same reasoning as
                              // settings_privacy_screen's Clear History —
                              // otherwise a future sync silently restores
                              // what was just cleared.
                              unawaited(
                                  SyncService.instance.clearRemoteHistory());
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
                              Text(l10n.commonClear,
                                  style: const TextStyle(
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
                      final currentGroup = _groupLabel(i, history.length, l10n);
                      final prevGroup = i > 0
                          ? _groupLabel(i - 1, history.length, l10n)
                          : null;
                      final showHeader = currentGroup != prevGroup;

                      return _AnimatedHistoryItem(
                        index: i,
                        itemKey: song.id,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showHeader)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(20, 20, 20, 6),
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
                                index: i,
                                curatedQueue: true),
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
// FIX (thumbnail appears to jump/re-enter while scrolling): see the
// matching _seenStaggeredItems fix in search_screen.dart — identical
// root cause here. A ListView scrolling a history row off-screen and
// back tears down and rebuilds this State (Flutter disposes off-screen
// list children), re-running initState() and replaying the 0.06-offset
// slide-in from scratch every time. Tracking which items have already
// animated once per session fixes it.
//
// FIX (on top of the above): keyed by song id (itemKey) rather than raw
// list position. History reorders whenever a song is replayed — it jumps
// back to the top of the list, shifting every other item's index down by
// one. With a position-only key, that shift could make an already-seen
// song look "new" at its shifted index (replaying its entrance animation
// for no reason) while a genuinely new item lands on an index some other
// song had already claimed as seen (wrongly skipping its animation).
// Keying by the song's own id avoids both.
final _seenHistoryItems = <String>{};

class _AnimatedHistoryItem extends StatefulWidget {
  final int index;
  final Widget child;
  // Stable identity for the underlying history entry (its song id).
  // Falls back to the raw index if not provided.
  final String? itemKey;
  const _AnimatedHistoryItem({required this.index, required this.child, this.itemKey});

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
      duration: AurumMotion.durationOrZero(AurumMotion.long1),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: AurumMotion.standard));

    final seenKey = widget.itemKey ?? 'idx_${widget.index}';
    if (_seenHistoryItems.contains(seenKey)) {
      _ctrl.value = 1.0;
    } else {
      _seenHistoryItems.add(seenKey);
      Future.delayed(Duration(milliseconds: 30 + cappedIndex * 40), () {
        if (mounted) _ctrl.forward();
      });
    }
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
    final l10n = AppLocalizations.of(context)!;
    final lib = context.watch<LibraryProvider>();
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        title: Text(l10n.libraryLocalFiles,
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
                      Text(l10n.libraryPermissionRequired,
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text(l10n.libraryNeedsPermissionToReadMusic,
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
                          child: Text(l10n.homeGrantPermission,
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
                      child: Text(l10n.libraryNoLocalSongsFound,
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context))))
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 100),
                      // PERF: pop-in fix for the full local-songs list.
                      cacheExtent: 1000,
                      itemCount: lib.allSongs.length,
                      itemExtent: 66,
                      itemBuilder: (_, i) => SongTile(
                          song: lib.allSongs[i],
                          queue: lib.allSongs,
                          index: i,
                          curatedQueue: true),
                    ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Downloads Screen (unchanged, kept public for NavigatorKey usage in main.dart)
// ══════════════════════════════════════════════════════════════════════════════
// PRODUCTION-GRADE PASS ("ekdam Echo Nightly jaisa feel, ekdam lightweight,
// low-end pe makkhan chale"): this screen previously showed a percent as
// plain text and nothing else — no visual progress, no storage summary, no
// transition animation when a download finishes or is removed. Three
// changes below, each picked specifically because it's cheap on a low-end
// device, not just because it looks nicer:
//   1. A thin circular progress RING around the artwork (CustomPainter,
//      one arc draw — costs nothing like a shader/blur would) replaces the
//      flat opacity+spinner combo, same premium-app language as Spotify/
//      YT Music/Echo Nightly's own download indicators.
//   2. A storage-summary header ("12 songs · 84 MB") using fileSizeBytes,
//      which DownloadItem already tracks — zero new state, just a fold
//      over data already being persisted.
//   3. AnimatedSwitcher + AnimatedList-style implicit transitions so a
//      download finishing (moves from "Downloading" to "Downloaded") or a
//      delete doesn't jump-cut the list — a short fade/slide, same 220ms
//      timing already used everywhere else in the app for consistency.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  @override
  void initState() {
    super.initState();
    // Fresh push (or re-push) of this screen — treat this as a brand new
    // "initial build" session. Every _DownloadTileEntrance alive during
    // the upcoming first frame will read true and skip its own fade
    // (AurumDepthRoute's page transition already covers that moment);
    // this flips to false right after that first frame paints, so any
    // row appearing later plays the fade normally. See
    // _DownloadsSessionGate's own comment for the full reasoning.
    _DownloadsSessionGate.isInitialBuild = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _DownloadsSessionGate.isInitialBuild = false;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    return '${(bytes / mb).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final downloads = context.watch<DownloadProvider>();
    final inProgress = downloads.inProgress;
    final completed = downloads.completed;
    final isEmpty = inProgress.isEmpty && completed.isEmpty;
    final totalBytes = completed.fold<int>(
        0, (sum, d) => sum + (d.fileSizeBytes ?? 0));

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
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
                    child: Text(l10n.settingsDownloads,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          // Storage summary strip — only meaningful once something is
          // actually downloaded, so it's skipped entirely on the empty
          // state (no dead "0 songs · 0 MB" row to greet a new user).
          if (completed.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    Icon(Icons.sd_storage_rounded,
                        size: 14, color: AurumTheme.textMutedOf(context)),
                    const SizedBox(width: 6),
                    Text(
                      l10n.libraryDownloadsStorageSummary(
                          completed.length, _formatBytes(totalBytes)),
                      style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
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
                      Text(l10n.libraryNoDownloadsYet,
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(
                        l10n.libraryDownloadFromPlayerDesc,
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
              SliverToBoxAdapter(child: _sectionHeader(context, l10n.libraryDownloadingHeader)),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _DownloadTileEntrance(
                    key: ValueKey('dl_prog_${inProgress[i].song.id}'),
                    child: _DownloadTile(item: inProgress[i]),
                  ),
                  childCount: inProgress.length,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 16)),
            ],
            if (completed.isNotEmpty) ...[
              SliverToBoxAdapter(
                  child: _sectionHeader(
                      context, l10n.libraryDownloadedCountHeader(completed.length))),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _DownloadTileEntrance(
                    key: ValueKey('dl_done_${completed[i].song.id}'),
                    child: _DownloadTile(
                      item: completed[i],
                      queue: completed,
                      queueIndex: i,
                    ),
                  ),
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

// PRODUCTION-GRADE PROGRESS RING ("download songs bhe ekdam top level ka,
// Echo Nightly style"): replaces the old opacity+small-spinner combo with
// a real determinate ring showing actual download progress, same visual
// language as Spotify/YT Music's own download indicators. Deliberately a
// CustomPainter drawing one arc rather than Flutter's own
// CircularProgressIndicator — same visual result, but a single Canvas.drawArc
// call per repaint is cheaper than the animation/paint machinery
// CircularProgressIndicator carries (built for material-spec ripple +
// indeterminate-mode support this use case doesn't need), and it repaints
// only when `progress` actually changes (driven by DownloadProvider's own
// notifyListeners, already throttled to once per whole percent — see
// download_provider.dart) rather than ticking every frame.
class _DownloadProgressRing extends StatelessWidget {
  final String artworkUrl;
  final double progress;
  const _DownloadProgressRing({required this.artworkUrl, required this.progress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Opacity(
              opacity: 0.55,
              child: AurumArtwork(url: artworkUrl, size: 48, borderRadius: 8),
            ),
          ),
          // Soft scrim so the ring reads clearly over busy album art,
          // same purpose as the old Opacity(0.4) wash — just tuned
          // slightly lighter since the ring itself now carries most of
          // the "this is downloading" signal.
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.black.withValues(alpha: 0.18),
            ),
          ),
          CustomPaint(
            size: const Size(30, 30),
            painter: _RingPainter(
              progress: progress.clamp(0.0, 1.0),
              trackColor: Colors.white.withValues(alpha: 0.25),
              progressColor: AurumTheme.gold,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color trackColor;
  final Color progressColor;
  const _RingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - 3) / 2;
    const strokeWidth = 2.6;

    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    if (progress > 0) {
      final progressPaint = Paint()
        ..color = progressColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        progressPaint,
      );
    }
  }

  // Only repaint when the actual progress value changes — not on every
  // rebuild of the parent tile (e.g. theme/locale changes elsewhere in
  // the tree), keeping this genuinely cheap on a long downloading list.
  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.progressColor != progressColor;
}

// LIGHTWEIGHT ENTRANCE ("naya download list mein aaye to smooth aaye, page
// khulte hi sab tiles pe apna alag fade na chale — glitch jaisa lagta
// tha"): the earlier version played this fade/slide on EVERY tile the
// instant it built — including the very first frame the whole screen
// appears on. That collided with AurumDepthRoute's own page-level
// fade+slide-up transition (see aurum_transitions.dart) running at the
// exact same moment: two independent opacity animations stacked on top of
// each other, starting at slightly different instants, reads as a
// glitch/stutter rather than something intentional — this tile-level fade
// was invisible under the page's much bigger fade for most of the
// transition, then popped in abruptly right at the end, which is exactly
// the "animation isn't working / feels off" behavior reported.
//
// Fix: a row present on the very first build of the list (i.e. the screen
// just opened) skips its own animation entirely — the page transition
// already sells that moment, nothing more is needed. A row that appears
// LATER, while you're already sitting on this screen (a download finishing
// and moving from "Downloading" into "Downloaded"), still gets the
// fade/slide-in — which is what this was actually built for.
//
// Deliberately NOT an AnimationController/SingleTickerProviderStateMixin
// either way — that would mean one live ticker per row, real per-frame
// cost on a long list (50+ downloads) for something that only ever needs
// to play once. TweenAnimationBuilder has no persistent vsync subscription
// at all: it runs its 220ms tween once and is fully inert — zero ticker,
// zero rebuild — the moment it completes.
class _DownloadTileEntrance extends StatefulWidget {
  final Widget child;
  const _DownloadTileEntrance({super.key, required this.child});

  @override
  State<_DownloadTileEntrance> createState() => _DownloadTileEntranceState();
}

class _DownloadTileEntranceState extends State<_DownloadTileEntrance> {
  // Captured once, in initState, against DownloadsScreen's own
  // `_isInitialBuild` flag (see that State below) — true for every row
  // still being built during the screen's first frame (skip: page
  // transition already covers it), false for a row created afterward
  // (play the fade: this is a genuinely new arrival mid-session).
  late final bool _skipAnimation;

  @override
  void initState() {
    super.initState();
    _skipAnimation = _DownloadsSessionGate.isInitialBuild;
  }

  @override
  Widget build(BuildContext context) {
    if (_skipAnimation) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AurumMotion.durationOrZero(AurumMotion.medium1),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 12),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

// Tiny frame-identity gate — lets every tile ask "was I born on the same
// frame the screen itself first appeared?" without each row needing its
// own timestamp/comparison plumbing. `screenOpenedFrame` is stamped once
// in DownloadsScreen's build (first call only); `currentFrame` is
// Flutter's own monotonically increasing frame counter, already tracked
// by the engine for every frame regardless of this feature — reading it
// costs nothing extra.
// Session-identity gate — every _DownloadTileEntrance checks
// `isInitialBuild` in its own initState (see that class above) to decide
// whether to skip its fade. `isInitialBuild` starts true and flips to
// false via a single addPostFrameCallback scheduled by DownloadsScreen's
// own State the first (and only the first) time it builds — every tile
// alive during that first frame reads `true` and skips its animation
// (the page-push transition already covers that moment); anything
// created afterward reads `false` and plays the fade normally. Reset to
// true in DownloadsScreen.initState so re-opening the screen (a fresh
// push) is correctly treated as a new "initial build" again, not a
// continuation of whatever session came before.
class _DownloadsSessionGate {
  static bool isInitialBuild = true;
}

class _DownloadTile extends StatelessWidget {
  final DownloadItem item;
  // FIX (Shivam feedback): tapping a downloaded song used to call
  // playSong(offlineSong) with no queue/index, so Up Next stayed empty
  // instead of showing the rest of the downloaded songs, and nothing
  // pushed FullPlayerScreen so the player never opened. `queue` is the
  // full list of completed DownloadItems (passed from DownloadsScreen)
  // and `queueIndex` is this tile's position in it.
  final List<DownloadItem>? queue;
  final int? queueIndex;
  const _DownloadTile({required this.item, this.queue, this.queueIndex});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = item.song;
    final isLight = Theme.of(context).brightness == Brightness.light;

    // Echo Nightly-exact: same live 3-bar equalizer badge every other
    // list (Search, Home, Mix, Library sections, Liked) already shows
    // via SongTile/AurumStackedArtwork — Downloads previously used a
    // bare AurumArtwork here with no now-playing indicator at all, the
    // one place in the app a currently-playing offline song gave no
    // visual feedback that it was the active track.
    final isCurrentSong = context.select<PlayerProvider, bool>(
      (p) => p.currentSong?.id == song.id,
    );
    final isActuallyPlaying = context.select<PlayerProvider, bool>(
      (p) => p.isPlaying,
    );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: item.isDownloading
          ? _DownloadProgressRing(
              artworkUrl: song.artworkUrl,
              progress: item.progress,
            )
          : AurumStackedArtwork(
              url: song.artworkUrl,
              size: 48,
              borderRadius: 8,
              showNowPlaying: isCurrentSong,
              isPlaying: isActuallyPlaying,
            ),
      title: Text(song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: isCurrentSong ? AurumTheme.gold : AurumTheme.textPrimaryOf(context),
              fontSize: 14,
              fontWeight: isCurrentSong ? FontWeight.w700 : FontWeight.w600)),
      subtitle: item.isDownloading
          ? Text(
              l10n.libraryDownloadingPercent((item.progress * 100).toStringAsFixed(0)),
              style: const TextStyle(color: AurumTheme.gold, fontSize: 12))
          : item.isFailed
              ? Text(l10n.libraryDownloadFailedTapRetry,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12))
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
                  PopupMenuItem(value: 'retry', child: Text(l10n.commonRetry)),
                PopupMenuItem(
                    value: 'delete', child: Text(l10n.libraryRemoveDownload)),
              ],
            ),
      // FIX (same class as song_tile.dart/search_screen.dart's InkWell/
      // ListTile fix — "cold start pe kisi bhi title tap karo, grey/white
      // layer aa jaata hai"): Downloads list ListTile had no explicit
      // splash/highlight color, same unthemed Material default as the
      // other fixed tiles. Offline/downloaded songs are exactly the case
      // most likely to resolve near-instantly on tap, giving the least
      // natural time for the ripple to fade normally before the next
      // frame — same theme-correct, low-opacity fix closes it here too.
      splashColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.06),
      focusColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.04),
      hoverColor: (isLight ? Colors.black : Colors.white).withValues(alpha: 0.04),
      onTap: () {
        if (item.isFailed) {
          context.read<DownloadProvider>().retry(song);
        } else if (item.isCompleted) {
          final dl = context.read<DownloadProvider>();
          final offlineSong = dl.offlineSongFor(song.id) ?? song;

          // Build the Up Next queue out of every OTHER downloaded song too,
          // resolving each to its offline version, so playback naturally
          // continues through the rest of the downloads list.
          final offlineQueue = (queue ?? [item])
              .map((d) => dl.offlineSongFor(d.song.id) ?? d.song)
              .toList();
          final resolvedIndex = queueIndex ?? 0;

          // SPOTIFY-STYLE FIX ("kahi se bhi full player na khule"): tap
          // now only starts playback — mini player is the tap feedback.
          context.read<PlayerProvider>().playSong(
                offlineSong,
                queue: offlineQueue,
                index: resolvedIndex,
                curatedQueue: true,
              );
        }
      },
    );
  }
}

// ── Albums screen ──────────────────────────────────────────────────────────

class _AlbumsScreen extends StatelessWidget {
  const _AlbumsScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final followed = context.watch<FollowedAlbumsProvider>().followed;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
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
                  const Icon(Icons.album_rounded,
                      color: Colors.deepPurple, size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) =>
                        AurumTheme.goldGradient.createShader(b),
                    child: Text(l10n.libraryAlbums,
                        style: const TextStyle(
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
                          color: Colors.deepPurple.withOpacity(0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: Colors.deepPurple.withOpacity(0.3)),
                        ),
                        child: const Icon(Icons.album_rounded,
                            color: Colors.deepPurple, size: 36),
                      ),
                      const SizedBox(height: 20),
                      Text(l10n.libraryNoAlbumsSavedYet,
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(l10n.libraryAlbumsYouSaveAppearHere,
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
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.72,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _FollowedAlbumTile(album: followed[i]),
                  childCount: followed.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FollowedAlbumTile extends StatelessWidget {
  final Map<String, dynamic> album;
  const _FollowedAlbumTile({required this.album});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final id = (album['id'] ?? '').toString();
    final name = (album['name'] ?? '').toString();
    final artworkUrl = (album['artworkUrl'] ?? '').toString();
    final isMix = album['isMix'] == true;

    // PERF: see the matching note on SongTile — isolates each grid cell
    // into its own compositor layer so scrolling a long saved-albums grid
    // doesn't repaint neighboring cells unnecessarily. Safe to wrap here:
    // AurumPressable's own tap-scale animation happens inside it, and the
    // Hero transition already snapshots this subtree during flight
    // regardless of any RepaintBoundary around it.
    return RepaintBoundary(
      child: AurumPressable(
      onTap: () {
        if (isMix) {
          final songs =
              context.read<FollowedAlbumsProvider>().songsFor(id);
          AurumDepthRoute.to(
            context,
            MixScreen(
              mixId: id,
              mixName: name,
              artworkUrl: artworkUrl,
              emoji: '', // no-emoji requirement — MixScreen renders an Icon fallback now
              songs: songs,
            ),
          );
        } else {
          AurumDepthRoute.to(
            context,
            AlbumScreen(albumId: id, albumName: name, artworkUrl: artworkUrl),
          );
        }
      },
      onLongPress: () {
        AurumHaptics.medium();
        _showUnsaveSheet(context, id, name, artworkUrl);
      },
      scaleAmount: 0.95,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Hero(
                tag: isMix ? 'mix_art_$id' : 'album_art_$id',
                // FIX (glitch/snap in mix & album grid artwork during
                // navigation): the default Hero flightShuttleBuilder tries
                // to morph BOTH the from-widget and to-widget's own
                // decoration (ClipRRect radius, Material, shadow) across
                // the flight, WHILE AurumPageRoute's page-level
                // SlideTransition is simultaneously moving the whole
                // destination screen underneath it. Those two independent
                // transforms fighting for the same frames is what reads
                // as a snap/glitch right as the flight ends and the
                // artwork hands off to the destination screen's own
                // (still-sliding) layout. A simple ScaleTransition on just
                // the destination widget — same fix already applied to
                // the full player's artwork Hero — sidesteps the double-
                // animation entirely: one clean scale, no decoration morph
                // to fight the page slide.
                flightShuttleBuilder: (context, animation, direction, from, to) {
                  return Material(
                    color: Colors.transparent,
                    child: ScaleTransition(scale: animation, child: to.widget),
                  );
                },
                child: Material(
                  color: Colors.transparent,
                  child: AurumArtwork(url: artworkUrl, size: 300, borderRadius: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.album_rounded,
                  size: 12, color: AurumTheme.gold.withOpacity(0.85)),
              const SizedBox(width: 4),
              Text(
                l10n.libraryAlbumTag,
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }

  void _showUnsaveSheet(
      BuildContext context, String id, String name, String artworkUrl) {
    final rootContext = context;
    final l10n = AppLocalizations.of(context)!;
    showAurumModalBottomSheet(
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: AurumArtwork(url: artworkUrl, size: 44, borderRadius: 8),
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
              leading: const Icon(Icons.bookmark_remove_rounded,
                  color: Colors.redAccent),
              title: Text(l10n.libraryRemoveFromSavedAlbums),
              onTap: () {
                Navigator.pop(sheetContext);
                rootContext.read<FollowedAlbumsProvider>().toggleFollow(
                      albumId: id,
                      name: name,
                      artworkUrl: artworkUrl,
                    );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistsScreen extends StatelessWidget {
  const _ArtistsScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final followed = context.watch<FollowedArtistsProvider>().followed;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
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
                    child: Text(l10n.libraryArtists,
                        style: const TextStyle(
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
                      Text(l10n.libraryNoArtistsSavedYet,
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Text(l10n.libraryArtistsYouFollowAppearHere,
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
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
    final l10n = AppLocalizations.of(context)!;
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
          // FIX (same class as song_tile.dart's InkWell fix — "grey/white
          // layer on tap, cold start"): no explicit splash/highlight
          // color meant Flutter's unthemed Material default, which can
          // read as a stray light flash if cold-start CPU contention
          // delays the ripple's fade-out or lands mid-rebuild.
          splashColor: (Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : Colors.black)
              .withValues(alpha: 0.06),
          highlightColor: (Theme.of(context).brightness == Brightness.dark
                  ? Colors.white
                  : Colors.black)
              .withValues(alpha: 0.04),
          onTap: () {
            AurumHaptics.selection();
            AurumDepthRoute.to(
              context,
              ArtistScreen(artistId: id, artistName: name),
            );
          },
          onLongPress: () {
            AurumHaptics.medium();
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
                            l10n.libraryArtistTag,
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
    final l10n = AppLocalizations.of(context)!;
    showAurumModalBottomSheet(
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
              title: Text(l10n.libraryUnfollowArtist),
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
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER: pushed via Navigator.push
      // from Library, so it needs its own MiniPlayerSlot — see
      // liked_screen.dart's matching comment for the full explanation.
      bottomNavigationBar: const MiniPlayerSlot(),
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
                    Text(l10n.libraryComingSoon,
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
//
// CHAIN ENTRANCE ANIMATION — premium "cascade" open:
//   Each row now plays a one-time entrance animation on first build: it
//   starts slightly below its resting position, scaled down a touch and
//   fully transparent, then springs up into place (slide + fade + scale)
//   with a gentle overshoot. `chainIndex` staggers the start of each row's
//   animation by a fixed offset, so rows fire one after another like a
//   chain/waterfall — Liked Songs first, then Playlists, Albums, Artists,
//   Local Files — instead of all five popping in at once. This only runs
//   once per row's lifetime (triggered from initState), so scrolling the
//   list or provider rebuilds (e.g. counts changing) never re-triggers it.
class _CollectionRow extends StatefulWidget {
  final _CollectionItem item;
  final int chainIndex;
  const _CollectionRow({required this.item, this.chainIndex = 0});

  @override
  State<_CollectionRow> createState() => _CollectionRowState();
}

class _CollectionRowState extends State<_CollectionRow>
    with TickerProviderStateMixin {
  bool _pressed = false;

  // ── Swipe-to-open ─────────────────────────────────────────────────────
  // Per spec: these 5 rows open ONLY via a left swipe — a plain tap does
  // nothing. `_dragDx` tracks live horizontal drag distance so the row
  // visually follows the finger (a lightweight Transform.translate, no
  // extra widgets/layers), giving immediate feedback that a swipe is
  // registering. Crossing `_openThreshold` on release triggers
  // navigation; anything short of it — or a rightward drag — snaps the
  // row back to rest, i.e. treated as a cancelled gesture, no navigation.
  //
  // FAST-USE HARDENING — this row must stay glitch-free even when a user
  // swipes rapidly, repeatedly, or fires a new swipe before the last one
  // has finished animating/navigating:
  //   • `_navigating` guards against a double-fire: without it, a user
  //     swiping twice in very quick succession (second swipe starting
  //     before the pushed screen has actually appeared) could trigger
  //     `onTap` twice, stacking two identical screens on the Navigator —
  //     back would then need two presses to actually leave. Once a swipe
  //     opens a screen, this row ignores all further drag input until
  //     the row is disposed (it's off-screen under the new route by then
  //     anyway) or, if the push is somehow cancelled, is defensively reset
  //     after a short delay.
  //   • Snap-back on a cancelled/incomplete swipe now animates back to
  //     rest (short, cheap AnimatedContainer-level tween on `_dragDx`)
  //     instead of jumping instantly — an instant jump reads as a stutter
  //     when the user immediately starts another swipe right after; the
  //     animated return means overlapping fast gestures always look
  //     continuous instead of snapping around.
  double _dragDx = 0;
  bool _navigating = false;
  static const double _openThreshold = -56.0;
  static const double _maxDragFollow = -84.0;

  // Dedicated controller purely for the "snap back to rest" motion after
  // a drag ends — kept completely separate from the drag itself (which
  // sets _dragDx directly, 1:1 with the finger, no animation involved)
  // so live dragging always has zero lag, while release always animates
  // smoothly regardless of how quickly the user repeats the gesture.
  late final AnimationController _snapBackCtrl;

  void _onDragUpdate(DragUpdateDetails details) {
    if (_navigating) return;
    // A new drag starting mid-snap-back should immediately take over —
    // stop any in-flight return animation so the row doesn't fight the
    // finger (this is what keeps rapid repeated swipes glitch-free).
    if (_snapBackCtrl.isAnimating) _snapBackCtrl.stop();
    setState(() {
      _dragDx += details.delta.dx;
      if (_dragDx > 0) _dragDx = 0; // ignore rightward drag entirely
      if (_dragDx < _maxDragFollow) _dragDx = _maxDragFollow;
    });
  }

  void _onDragEnd(DragEndDetails details) {
    if (_navigating) return;
    final crossedThreshold = _dragDx <= _openThreshold;

    if (crossedThreshold) {
      // Lock immediately so a second, near-simultaneous swipe (finger
      // lifts and comes right back down mid-gesture) can never fire a
      // second navigation while the first is still in flight.
      _navigating = true;
      AurumHaptics.medium();
      _animateSnapBack();
      widget.item.onTap?.call();
      // Defensive reset: if for any reason no navigation actually
      // occurred (e.g. onTap was null), don't leave this row permanently
      // stuck ignoring input.
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _navigating = false;
      });
    } else {
      _animateSnapBack();
    }
  }

  void _animateSnapBack() {
    final start = _dragDx;
    _snapBackCtrl.reset();
    final tween = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _snapBackCtrl, curve: Curves.easeOut),
    );
    void listener() {
      if (!mounted) return;
      setState(() => _dragDx = tween.value);
    }

    tween.addListener(listener);
    _snapBackCtrl.forward().whenCompleteOrCancel(() {
      tween.removeListener(listener);
    });
  }

  late final AnimationController _entranceCtrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  static const _staggerStep = Duration(milliseconds: 90);
  static const _riseDuration = Duration(milliseconds: 520);

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(vsync: this, duration: _riseDuration);
    _snapBackCtrl = AnimationController(
      vsync: this,
      duration: AurumMotion.durationOrZero(AurumMotion.medium1),
    );

    // easeOutCubic gives a confident, slightly-decelerating rise rather
    // than a linear pop — reads as "premium spring" without the bounce
    // overshooting into cartoonish territory.
    final curved =
        CurvedAnimation(parent: _entranceCtrl, curve: AurumMotion.standard);
    _fade = curved;
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(curved);
    _scale = Tween<double>(begin: 0.92, end: 1.0).animate(curved);

    final delay = _staggerStep * widget.chainIndex;
    Future.delayed(delay, () {
      if (mounted) _entranceCtrl.forward();
    });
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _snapBackCtrl.dispose();
    super.dispose();
  }

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isLight = Theme.of(context).brightness == Brightness.light;

    final row = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _setPressed(true),
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: (details) {
        _setPressed(false);
        _onDragEnd(details);
      },
      onHorizontalDragCancel: () {
        _setPressed(false);
        if (!_navigating) _animateSnapBack();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: AurumMotion.durationOrZero(AurumMotion.short2),
        curve: Curves.easeOut,
        // Transform.translate driven directly by _dragDx: during an
        // active drag this is a raw pixel-for-pixel finger-follow (no
        // animation lag at all — the same feel as native swipe-to-open
        // gestures). The snap-back on release is animated separately via
        // _snapBackCtrl (see _onDragEnd) rather than this widget jumping
        // instantly, so rapid back-to-back swipes never look like the
        // row is teleporting between gestures.
        child: Transform.translate(
          offset: Offset(_dragDx, 0),
          child: AnimatedContainer(
            duration: AurumMotion.durationOrZero(AurumMotion.short2),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  item.color
                      .withOpacity(_pressed ? 0.14 : (isLight ? 0.07 : 0.09)),
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
      ),
    );

    return AnimatedBuilder(
      animation: _entranceCtrl,
      builder: (context, child) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: FractionalTranslation(
          translation: _slide.value,
          child: Transform.scale(scale: _scale.value, child: child),
        ),
      ),
      child: row,
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
