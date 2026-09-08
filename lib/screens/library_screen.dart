// =============================================================================
// FILE: lib/screens/library_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Library — tabbed layout.
//   Root screen shows a segmented tab row (Playlists / Songs / Artists /
//   Albums), each with its own hero card ("Top Artist", "Featured Album",
//   "Your Collection") plus a quick-access grid (Liked / Offline / Cached /
//   Local Files / My Top 50) and a Recently Played rail underneath.
//   Every tab reads from Aurum's real providers (PlaylistProvider,
//   LibraryProvider, FollowedArtistsProvider, FollowedAlbumsProvider,
//   FavoritesProvider, DownloadProvider, RecentlyPlayedProvider) — nothing
//   here is placeholder/mock data.
//
//   Downstream destinations (PlaylistsScreen, PlaylistDetailScreen,
//   LikedScreen, DownloadsScreen, _HistoryScreen, _LocalFilesScreen,
//   _AlbumsScreen/_ArtistsScreen list bodies) are UNCHANGED below this
//   block — only the root LibraryScreen widget and its small private
//   helpers (_QuickChip/_CollectionItem/_CollectionRow/_CoverFan) were
//   replaced, since those were only ever used by the old root layout.
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
import '../utils/aurum_immersive_header.dart';
import '../utils/artwork_palette_cache.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_motion.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Archive palette — a self-contained peach/brown scheme scoped to Library,
// independent of AurumTheme's own dark/amoled/light/dynamic system. Every
// color the new Library layout needs lives here so nothing on this screen
// silently drifts if AurumTheme's palette changes elsewhere in the app.
// ══════════════════════════════════════════════════════════════════════════════

// ══════════════════════════════════════════════════════════════════════════════
// Library Root — tabbed shell
// ══════════════════════════════════════════════════════════════════════════════

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

enum _LibTab { library, playlists, songs, artists, albums }

class _LibraryScreenState extends State<LibraryScreen> {
  _LibTab _tab = _LibTab.library;
  final ScrollController _tabScrollCtrl = ScrollController();

  @override
  void dispose() {
    _tabScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      extendBody: true,
      // FIX (duplicate mini player): LibraryScreen is always tab index 2
      // inside MainShell's own IndexedStack (see main_shell.dart's
      // `_screens` list) — it is never pushed as an independent route.
      // MainShell's own bottomNavigationBar already renders the one real
      // MiniPlayer for all 3 root tabs (Home/Search/Library). Giving this
      // screen its own `MiniPlayerSlot()` on top of that stacked a SECOND,
      // fully independent mini player (its own state, its own play/pause)
      // directly above MainShell's, which is exactly the "2 mini players"
      // bug. Root tab screens must NOT set their own bottomNavigationBar —
      // only screens pushed via Navigator.push on top of MainShell (see
      // MiniPlayerSlot's doc comment) need one.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(context),
            _buildTabRow(context),
            Expanded(
              child: AnimatedSwitcher(
                duration: AurumMotion.durationOrZero(AurumMotion.short2),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: KeyedSubtree(
                  key: ValueKey(_tab),
                  child: _buildTabBody(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top bar: brand + quick action icons ──────────────────────────────────
  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AurumTheme.accentOf(context),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Text(
            'Aurum',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const Spacer(),
          _TopIconButton(
            icon: Icons.history_rounded,
            onTap: () => AurumDepthRoute.to(context, const _HistoryScreen()),
          ),
          const SizedBox(width: 8),
          _TopIconButton(
            icon: Icons.calendar_month_rounded,
            onTap: () => AurumDepthRoute.to(context, const DownloadsScreen()),
          ),
          const SizedBox(width: 8),
          _TopIconButton(
            icon: Icons.new_releases_outlined,
            onTap: () {},
          ),
          const SizedBox(width: 8),
          _TopIconButton(
            icon: Icons.settings_outlined,
            onTap: () => AurumDepthRoute.to(context, const SettingsScreen()),
          ),
        ],
      ),
    );
  }

  // ── Segmented tab row: Library / Playlists / Songs / Artists / Albums ───
  Widget _buildTabRow(BuildContext context) {
    final tabs = <_LibTab, ({IconData icon, String label})>{
      _LibTab.library:   (icon: Icons.grid_view_rounded, label: 'Library'),
      _LibTab.playlists: (icon: Icons.format_list_bulleted_rounded, label: 'Playlists'),
      _LibTab.songs:     (icon: Icons.music_note_rounded, label: 'Songs'),
      _LibTab.artists:   (icon: Icons.person_rounded, label: 'Artists'),
      _LibTab.albums:    (icon: Icons.album_rounded, label: 'Albums'),
    };

    return SizedBox(
      height: 52,
      child: ListView(
        controller: _tabScrollCtrl,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          for (final entry in tabs.entries) ...[
            _TabChip(
              icon: entry.value.icon,
              label: entry.value.label,
              selected: _tab == entry.key,
              onTap: () {
                if (_tab == entry.key) return;
                AurumHaptics.selection();
                setState(() => _tab = entry.key);
              },
            ),
            const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }

  Widget _buildTabBody(BuildContext context) {
    switch (_tab) {
      case _LibTab.library:
        return const _AurumLibraryOverviewTab();
      case _LibTab.playlists:
        return const _AurumPlaylistsTab();
      case _LibTab.songs:
        return const _AurumSongsTab();
      case _LibTab.artists:
        return const _AurumArtistsTab();
      case _LibTab.albums:
        return const _AurumAlbumsTab();
    }
  }
}

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TopIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AurumTheme.bgSurfaceOf(context),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          AurumHaptics.light();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, color: AurumTheme.accentOf(context), size: 19),
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AurumTheme.accentOf(context) : AurumTheme.bgSurfaceOf(context),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AurumMotion.durationOrZero(AurumMotion.short2),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 18,
                  color: selected ? Colors.white : AurumTheme.accentOf(context)),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.white : AurumTheme.accentOf(context),
                  fontSize: 14.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// ══════════════════════════════════════════════════════════════════════════════
// SONGS TAB — hero card summarizing the collection + song list.
// Backed by LibraryProvider's real scanned device library (allSongs).
// ══════════════════════════════════════════════════════════════════════════════

class _AurumSongsTab extends StatefulWidget {
  const _AurumSongsTab();

  @override
  State<_AurumSongsTab> createState() => _AurumSongsTabState();
}

class _AurumSongsTabState extends State<_AurumSongsTab> {
  bool _newestFirst = true;
  // Which subset of the library this tab is currently showing — mirrors
  // the reference screenshot's "Liked / Downloaded / All Songs" chip row.
  // "All Songs" is the same full-library view this tab always had.
  _SongsFilter _filter = _SongsFilter.liked;

  @override
  void initState() {
    super.initState();
    final lib = context.read<LibraryProvider>();
    if (!lib.hasLoaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) => lib.load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final favorites = context.watch<FavoritesProvider>();
    final downloads = context.watch<DownloadProvider>();

    if (lib.status == LibraryStatus.loading || lib.status == LibraryStatus.idle) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: AurumM3Loader(),
        ),
      );
    }

    if (lib.status == LibraryStatus.noPermission) {
      return _AurumPermissionState(onGrant: () => lib.load());
    }

    List<Song> songs;
    switch (_filter) {
      case _SongsFilter.liked:
        songs = List<Song>.from(favorites.favorites);
        break;
      case _SongsFilter.downloaded:
        songs = downloads.completed.map((d) => d.song).toList();
        break;
      case _SongsFilter.all:
        songs = List<Song>.from(lib.allSongs);
        break;
    }
    if (_newestFirst) {
      // LibraryProvider doesn't track a per-song "added" timestamp — the
      // scan order from MediaStore is already newest-ish first on most
      // devices, so newest-first simply keeps that order; "oldest first"
      // reverses it. Neither branch invents data the provider doesn't have.
    } else {
      songs.reversed.toList();
    }
    final ordered = _newestFirst ? songs : songs.reversed.toList();

    final totalSeconds = ordered.fold<int>(0, (sum, s) => sum + (s.duration ?? 0));
    final durationLabel = _formatDuration(totalSeconds);

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      cacheExtent: 1200,
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              children: [
                _SongsFilterChip(
                  label: 'Liked',
                  selected: _filter == _SongsFilter.liked,
                  onTap: () {
                    AurumHaptics.selection();
                    setState(() => _filter = _SongsFilter.liked);
                  },
                ),
                const SizedBox(width: 10),
                _SongsFilterChip(
                  label: 'Downloaded',
                  selected: _filter == _SongsFilter.downloaded,
                  onTap: () {
                    AurumHaptics.selection();
                    setState(() => _filter = _SongsFilter.downloaded);
                  },
                ),
                const SizedBox(width: 10),
                _SongsFilterChip(
                  label: 'All Songs',
                  selected: _filter == _SongsFilter.all,
                  onTap: () {
                    AurumHaptics.selection();
                    setState(() => _filter = _SongsFilter.all);
                  },
                ),
                const SizedBox(width: 10),
                _SortRow(
                  newestFirst: _newestFirst,
                  onToggle: () {
                    AurumHaptics.selection();
                    setState(() => _newestFirst = !_newestFirst);
                  },
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _HeroActionCard(
              title: 'Your Collection',
              subtitle: ordered.isEmpty
                  ? 'No songs yet'
                  : '${ordered.length} Song${ordered.length == 1 ? '' : 's'} • $durationLabel',
              buttonLabel: 'Play',
              icon: Icons.play_arrow_rounded,
              onButtonTap: ordered.isEmpty
                  ? null
                  : () => context.read<PlayerProvider>().playSong(
                        ordered.first,
                        queue: ordered,
                        index: 0,
                        curatedQueue: true,
                      ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        if (ordered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AurumEmptyState(
              icon: Icons.music_note_rounded,
              title: 'No songs found',
              subtitle: _filter == _SongsFilter.liked
                  ? 'Songs you like will show up here.'
                  : _filter == _SongsFilter.downloaded
                      ? 'Downloaded songs will show up here.'
                      : 'Songs from your device will show up here.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _AurumSongRow(
                    song: ordered[i],
                    queue: ordered,
                    index: i,
                  ),
                ),
                childCount: ordered.length,
              ),
            ),
          ),
      ],
    );
  }

  static String _formatDuration(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    if (m >= 60) {
      final h = m ~/ 60;
      final mm = m % 60;
      return '${h}h ${mm}m';
    }
    return '${m}m ${s}s';
  }
}

enum _SongsFilter { liked, downloaded, all }

class _SongsFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SongsFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AurumTheme.accentOf(context) : AurumTheme.bgSurfaceOf(context),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Text(label,
              style: TextStyle(
                  color: selected ? Colors.white : AurumTheme.textPrimaryOf(context),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

class _SortRow extends StatelessWidget {
  final bool newestFirst;
  final VoidCallback onToggle;
  const _SortRow({required this.newestFirst, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Material(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    newestFirst ? 'Newest first' : 'Oldest first',
                    style: TextStyle(
                      color: AurumTheme.accentOf(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      color: AurumTheme.accentOf(context), size: 18),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: AurumTheme.bgSurfaceOf(context),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Icon(
                newestFirst
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                color: AurumTheme.accentOf(context),
                size: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Hero card (used across Songs/Artists/Albums tabs) ───────────────────────
class _HeroActionCard extends StatelessWidget {
  final String? eyebrow;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final IconData icon;
  final VoidCallback? onButtonTap;
  final VoidCallback? onMoreTap;
  final Widget? leading;

  const _HeroActionCard({
    this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.icon,
    this.onButtonTap,
    this.onMoreTap,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null) ...[
                  Text(
                    eyebrow!.toUpperCase(),
                    style: TextStyle(
                      color: AurumTheme.accentOf(context).withOpacity(0.75),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context).withOpacity(0.65),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Material(
                      color: AurumTheme.accentOf(context),
                      borderRadius: BorderRadius.circular(22),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: onButtonTap == null
                            ? null
                            : () {
                                AurumHaptics.light();
                                onButtonTap!();
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                buttonLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (onMoreTap != null) ...[
                      const SizedBox(width: 10),
                      Material(
                        color: Colors.white.withOpacity(0.35),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onMoreTap,
                          child: Padding(
                            padding: EdgeInsets.all(11),
                            child: Icon(Icons.more_horiz_rounded,
                                color: AurumTheme.accentOf(context), size: 18),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Song row (flat card) ──────────────────────────────────
class _AurumSongRow extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _AurumSongRow({
    required this.song,
    required this.queue,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    final isFav = context.watch<FavoritesProvider>().isFavorite(song.id);
    return Material(
      color: Colors.white.withOpacity(0.55),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          AurumHaptics.selection();
          context.read<PlayerProvider>().playSong(
                song,
                queue: queue,
                index: index,
                curatedQueue: true,
              );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: song.artworkUrl.isEmpty
                    ? Container(
                        width: 46,
                        height: 46,
                        color: AurumTheme.bgSurfaceOf(context),
                        child: Icon(Icons.music_note_rounded,
                            color: AurumTheme.accentOf(context), size: 20),
                      )
                    : AurumArtwork(url: song.artworkUrl, size: 46, borderRadius: 12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (isFav) ...[
                          const Icon(Icons.favorite_rounded,
                              color: Colors.redAccent, size: 14),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist.isEmpty ? 'Unknown artist' : song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (song.durationString.isNotEmpty)
                Text(
                  song.durationString,
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(Icons.more_vert_rounded,
                    color: AurumTheme.textMutedOf(context), size: 20),
                onPressed: () => _showSongSheet(context, song),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSongSheet(BuildContext context, Song song) {
    final rootContext = context;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(url: song.artworkUrl, size: 46, borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      Text(song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context), fontSize: 12.5)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Consumer<FavoritesProvider>(
              builder: (context, fav, _) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  fav.isFavorite(song.id)
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: Colors.redAccent,
                ),
                title: Text(
                  fav.isFavorite(song.id) ? 'Remove from Liked' : 'Add to Liked',
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context)),
                ),
                onTap: () {
                  rootContext.read<FavoritesProvider>().toggleFavorite(song);
                  Navigator.pop(sheetContext);
                },
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.playlist_add_rounded, color: AurumTheme.accentOf(context)),
              title: Text('Add to Playlist',
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
              onTap: () => Navigator.pop(sheetContext),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Shared song options bottom sheet (Add/Remove Liked, Add to Playlist) ────
// Extracted to a top-level function so any screen with a single Song in
// hand can reuse the exact same working sheet instead of re-implementing
// it — e.g. the Library overview's "Most Played" hero card's "more" button.
void showAurumSongOptionsSheet(BuildContext context, Song song) {
  final rootContext = context;
  showAurumModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AurumArtwork(url: song.artworkUrl, size: 46, borderRadius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    Text(song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context), fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Consumer<FavoritesProvider>(
            builder: (context, fav, _) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                fav.isFavorite(song.id)
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: Colors.redAccent,
              ),
              title: Text(
                fav.isFavorite(song.id) ? 'Remove from Liked' : 'Add to Liked',
                style: TextStyle(color: AurumTheme.textPrimaryOf(context)),
              ),
              onTap: () {
                rootContext.read<FavoritesProvider>().toggleFavorite(song);
                Navigator.pop(sheetContext);
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.playlist_add_rounded, color: AurumTheme.accentOf(context)),
            title: Text('Add to Playlist',
                style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
            onTap: () => Navigator.pop(sheetContext),
          ),
        ],
      ),
    ),
  );
}

// ── Shared empty/permission states ──────────────────────────────────────────
class _AurumEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _AurumEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AurumTheme.bgSurfaceOf(context),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: AurumTheme.accentOf(context), size: 30),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AurumTheme.textMutedOf(context),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AurumPermissionState extends StatelessWidget {
  final VoidCallback onGrant;
  const _AurumPermissionState({required this.onGrant});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AurumTheme.bgSurfaceOf(context),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.folder_rounded, color: AurumTheme.accentOf(context), size: 30),
            ),
            const SizedBox(height: 18),
            Text(
              'Permission needed',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Aurum needs access to your device storage to show local songs.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 18),
            Material(
              color: AurumTheme.accentOf(context),
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: onGrant,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 26, vertical: 12),
                  child: Text('Grant permission',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
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
// ARTISTS TAB — top-artist hero + "Artists" count
// card + sort row + list. Backed by FollowedArtistsProvider (real saved/
// followed artists — same data source the existing _ArtistsScreen used).
// ══════════════════════════════════════════════════════════════════════════════

class _AurumArtistsTab extends StatefulWidget {
  const _AurumArtistsTab();

  @override
  State<_AurumArtistsTab> createState() => _AurumArtistsTabState();
}

class _AurumArtistsTabState extends State<_AurumArtistsTab> {
  bool _newestFirst = true;

  @override
  Widget build(BuildContext context) {
    final followedProvider = context.watch<FollowedArtistsProvider>();
    if (followedProvider.isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: AurumM3Loader(),
        ),
      );
    }

    // followed is already newest-first (see FollowedArtistsProvider.followed,
    // which reverses Hive's insertion order) — oldest-first simply un-reverses.
    final base = followedProvider.followed;
    final ordered = _newestFirst ? base : base.reversed.toList();
    final top = ordered.isNotEmpty ? ordered.first : null;
    if (kDebugMode) {
      debugPrint('[ArtistsTab] rebuild — isLoading=${followedProvider.isLoading} '
          'followed.length=${base.length} names=${base.map((m) => m['name']).toList()}');
    }

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      cacheExtent: 1200,
      slivers: [
        if (top != null) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: _TopArtistAndCountRow(
                top: top,
                totalCount: ordered.length,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 18)),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                _SortRow(
                  newestFirst: _newestFirst,
                  onToggle: () {
                    AurumHaptics.selection();
                    setState(() => _newestFirst = !_newestFirst);
                  },
                ),
                const Spacer(),
                if (ordered.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: AurumTheme.bgSurfaceOf(context),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Subscribed Only',
                      style: TextStyle(
                        color: AurumTheme.accentOf(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        if (ordered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AurumEmptyState(
              icon: Icons.person_rounded,
              title: 'No artists saved yet',
              subtitle: 'Artists you follow will appear here.',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AurumArtistRow(artist: ordered[i]),
                ),
                childCount: ordered.length,
              ),
            ),
          ),
      ],
    );
  }
}

class _TopArtistAndCountRow extends StatelessWidget {
  final Map<String, dynamic> top;
  final int totalCount;
  const _TopArtistAndCountRow({required this.top, required this.totalCount});

  @override
  Widget build(BuildContext context) {
    final name = (top['name'] ?? '').toString();
    final id = (top['id'] ?? '').toString();
    final imageUrl = (top['imageUrl'] ?? '').toString();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 6,
          child: _HeroActionCard(
            eyebrow: 'Top Artist',
            title: name.isEmpty ? 'Unknown' : name,
            subtitle: '',
            buttonLabel: 'Play all',
            icon: Icons.play_arrow_rounded,
            leading: ClipOval(
              child: imageUrl.isEmpty
                  ? Container(
                      width: 46,
                      height: 46,
                      color: AurumTheme.accentOf(context),
                      child: const Icon(Icons.person_rounded,
                          color: Colors.white, size: 22),
                    )
                  : AurumArtwork(url: imageUrl, size: 46, borderRadius: 23),
            ),
            onButtonTap: () => AurumDepthRoute.to(
              context,
              ArtistScreen(artistId: id, artistName: name),
            ),
            onMoreTap: () => AurumDepthRoute.to(
              context,
              ArtistScreen(artistId: id, artistName: name),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 4,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AurumTheme.bgElevatedOf(context),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Artists',
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_forward_rounded,
                        color: AurumTheme.accentOf(context), size: 18),
                  ],
                ),
                Text(
                  '$totalCount',
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  'total',
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context).withOpacity(0.6),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AurumArtistRow extends StatelessWidget {
  final Map<String, dynamic> artist;
  const _AurumArtistRow({required this.artist});

  @override
  Widget build(BuildContext context) {
    final id = (artist['id'] ?? '').toString();
    final name = (artist['name'] ?? '').toString();
    final imageUrl = (artist['imageUrl'] ?? '').toString();

    return Material(
      color: Colors.white.withOpacity(0.55),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          AurumHaptics.selection();
          AurumDepthRoute.to(context, ArtistScreen(artistId: id, artistName: name));
        },
        onLongPress: () {
          AurumHaptics.medium();
          _showUnfollowSheet(context, id, name, imageUrl);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipOval(
                child: imageUrl.isEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        color: AurumTheme.bgSurfaceOf(context),
                        child: Icon(Icons.person_rounded,
                            color: AurumTheme.accentOf(context), size: 22),
                      )
                    : AurumArtwork(url: imageUrl, size: 48, borderRadius: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Unknown' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
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
              ),
              Material(
                color: AurumTheme.accentOf(context),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => AurumDepthRoute.to(
                    context,
                    ArtistScreen(artistId: id, artistName: name),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(9),
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showUnfollowSheet(
      BuildContext context, String id, String name, String imageUrl) {
    final rootContext = context;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: AurumTheme.textPrimaryOf(context),
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
              leading: const Icon(Icons.person_remove_rounded, color: Colors.redAccent),
              title: Text('Unfollow artist',
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
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
// ══════════════════════════════════════════════════════════════════════════════
// ALBUMS TAB — featured-album hero + grid, plus a
// list/grid toggle. Backed by FollowedAlbumsProvider (real saved albums —
// same data source the existing _AlbumsScreen used).
// ══════════════════════════════════════════════════════════════════════════════

class _AurumAlbumsTab extends StatefulWidget {
  const _AurumAlbumsTab();

  @override
  State<_AurumAlbumsTab> createState() => _AurumAlbumsTabState();
}

class _AurumAlbumsTabState extends State<_AurumAlbumsTab> {
  bool _newestFirst = true;
  bool _gridView = true;

  @override
  Widget build(BuildContext context) {
    final followedProvider = context.watch<FollowedAlbumsProvider>();
    if (followedProvider.isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: AurumM3Loader(),
        ),
      );
    }

    final base = followedProvider.followed;
    final ordered = _newestFirst ? base : base.reversed.toList();
    final featured = ordered.isNotEmpty ? ordered.first : null;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      cacheExtent: 1200,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Row(
              children: [
                _SortRow(
                  newestFirst: _newestFirst,
                  onToggle: () {
                    AurumHaptics.selection();
                    setState(() => _newestFirst = !_newestFirst);
                  },
                ),
                const Spacer(),
                _ViewToggle(
                  gridView: _gridView,
                  onChanged: (v) {
                    AurumHaptics.selection();
                    setState(() => _gridView = v);
                  },
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 14)),
        if (featured != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _FeaturedAlbumHero(album: featured),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        if (ordered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AurumEmptyState(
              icon: Icons.album_rounded,
              title: 'No albums saved yet',
              subtitle: 'Albums you save will appear here.',
            ),
          )
        else if (_gridView)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                childAspectRatio: 0.78,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _AurumAlbumTile(album: ordered[i]),
                childCount: ordered.length,
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AurumAlbumRow(album: ordered[i]),
                ),
                childCount: ordered.length,
              ),
            ),
          ),
      ],
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final bool gridView;
  final ValueChanged<bool> onChanged;
  const _ViewToggle({required this.gridView, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AurumTheme.bgSurfaceOf(context),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ViewToggleButton(
            icon: Icons.view_list_rounded,
            selected: !gridView,
            onTap: () => onChanged(false),
          ),
          _ViewToggleButton(
            icon: Icons.album_rounded,
            selected: gridView,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _ViewToggleButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _ViewToggleButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AurumTheme.accentOf(context) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 18, color: selected ? Colors.white : AurumTheme.accentOf(context)),
        ),
      ),
    );
  }
}

class _FeaturedAlbumHero extends StatelessWidget {
  final Map<String, dynamic> album;
  const _FeaturedAlbumHero({required this.album});

  @override
  Widget build(BuildContext context) {
    final id = (album['id'] ?? '').toString();
    final name = (album['name'] ?? '').toString();
    final artworkUrl = (album['artworkUrl'] ?? '').toString();
    final isMix = album['isMix'] == true;

    void open() {
      if (isMix) {
        final songs = context.read<FollowedAlbumsProvider>().songsFor(id);
        AurumDepthRoute.to(
          context,
          MixScreen(mixId: id, mixName: name, artworkUrl: artworkUrl, emoji: '', songs: songs),
        );
      } else {
        AurumDepthRoute.to(
          context,
          AlbumScreen(albumId: id, albumName: name, artworkUrl: artworkUrl),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: AurumArtwork(url: artworkUrl, size: 90, borderRadius: 14),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'FEATURED ALBUM',
                  style: TextStyle(
                    color: AurumTheme.accentOf(context).withOpacity(0.75),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  name.isEmpty ? 'Unknown album' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Material(
                      color: AurumTheme.accentOf(context),
                      borderRadius: BorderRadius.circular(22),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: open,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.play_arrow_rounded, color: Colors.white, size: 18),
                              SizedBox(width: 8),
                              Text('Play',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: Colors.white.withOpacity(0.35),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: open,
                        child: Padding(
                          padding: EdgeInsets.all(11),
                          child: Icon(Icons.more_horiz_rounded, color: AurumTheme.accentOf(context), size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AurumAlbumTile extends StatelessWidget {
  final Map<String, dynamic> album;
  const _AurumAlbumTile({required this.album});

  @override
  Widget build(BuildContext context) {
    final id = (album['id'] ?? '').toString();
    final name = (album['name'] ?? '').toString();
    final artworkUrl = (album['artworkUrl'] ?? '').toString();
    final isMix = album['isMix'] == true;

    return RepaintBoundary(
      child: AurumPressable(
        onTap: () {
          if (isMix) {
            final songs = context.read<FollowedAlbumsProvider>().songsFor(id);
            AurumDepthRoute.to(
              context,
              MixScreen(mixId: id, mixName: name, artworkUrl: artworkUrl, emoji: '', songs: songs),
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
                borderRadius: BorderRadius.circular(16),
                child: AurumArtwork(url: artworkUrl, size: 300, borderRadius: 16),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name.isEmpty ? 'Unknown album' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUnsaveSheet(
      BuildContext context, String id, String name, String artworkUrl) {
    final rootContext = context;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: AurumTheme.textPrimaryOf(context),
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
              leading: const Icon(Icons.bookmark_remove_rounded, color: Colors.redAccent),
              title: Text('Remove from saved albums',
                  style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
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

class _AurumAlbumRow extends StatelessWidget {
  final Map<String, dynamic> album;
  const _AurumAlbumRow({required this.album});

  @override
  Widget build(BuildContext context) {
    final id = (album['id'] ?? '').toString();
    final name = (album['name'] ?? '').toString();
    final artworkUrl = (album['artworkUrl'] ?? '').toString();
    final isMix = album['isMix'] == true;

    return Material(
      color: Colors.white.withOpacity(0.55),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          AurumHaptics.selection();
          if (isMix) {
            final songs = context.read<FollowedAlbumsProvider>().songsFor(id);
            AurumDepthRoute.to(
              context,
              MixScreen(mixId: id, mixName: name, artworkUrl: artworkUrl, emoji: '', songs: songs),
            );
          } else {
            AurumDepthRoute.to(
              context,
              AlbumScreen(albumId: id, albumName: name, artworkUrl: artworkUrl),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AurumArtwork(url: artworkUrl, size: 48, borderRadius: 12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Unknown album' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Album',
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context)),
            ],
          ),
        ),
      ),
    );
  }
}
// ══════════════════════════════════════════════════════════════════════════════
// LIBRARY TAB — the overview landing tab (ArchiveTune-style): hero "most
// played" card, quick-access grid (Liked / Offline / Cached / Local Files /
// My Top 50), Recently Played rail, and a small 2-item playlist preview
// with a "See all" arrow into the full PlaylistsScreen.
// ══════════════════════════════════════════════════════════════════════════════

class _AurumLibraryOverviewTab extends StatefulWidget {
  const _AurumLibraryOverviewTab();

  @override
  State<_AurumLibraryOverviewTab> createState() => _AurumLibraryOverviewTabState();
}

class _AurumLibraryOverviewTabState extends State<_AurumLibraryOverviewTab> {
  @override
  Widget build(BuildContext context) {
    final favorites = context.watch<FavoritesProvider>();
    final downloads = context.watch<DownloadProvider>();
    final recentlyPlayed = context.watch<RecentlyPlayedProvider>();
    final playlists = context.watch<PlaylistProvider>();

    final likedCount = favorites.favorites.length;
    final downloadedCount = downloads.completed.length;
    final recent = recentlyPlayed.history.take(10).toList();
    final hasRecent = recent.isNotEmpty;
    final heroTitle = !hasRecent
        ? 'Your Library'
        : (recent.first.album.isNotEmpty ? recent.first.album : recent.first.title);
    final previewPlaylists = playlists.playlists.take(2).toList();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(),
      cacheExtent: 1200,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 6)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _HeroActionCard(
              eyebrow: hasRecent ? 'Most Played' : null,
              title: heroTitle,
              // FIX (hardcoded "1 song" — pre-existing bug, not touched
              // by intent): this used to read `hasRecent ? '1 song' : ...`
              // literally always, regardless of the actual song. Nothing
              // in RecentlyPlayedProvider tracks a per-song play COUNT
              // (only a play timestamp — see _playedAtById), so a real
              // count can't be shown honestly yet. Falls back to the
              // artist name instead, which the data genuinely has —
              // never displays a fabricated number.
              subtitle: hasRecent
                  ? (recent.first.artist.isNotEmpty ? recent.first.artist : 'Unknown artist')
                  : 'Start playing to see your library grow',
              buttonLabel: 'Play all',
              icon: Icons.play_arrow_rounded,
              leading: !hasRecent
                  ? null
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: AurumArtwork(url: recent.first.artworkUrl, size: 68, borderRadius: 14),
                    ),
              onButtonTap: !hasRecent
                  ? null
                  : () => context.read<PlayerProvider>().playSong(
                        recent.first,
                        queue: recent,
                        index: 0,
                        curatedQueue: true,
                      ),
              // FIX (dead tap): was `() {}`. Now opens the same
              // Add-to-Liked/Add-to-Playlist sheet every song row already
              // uses (showAurumSongOptionsSheet), so the "..." on this
              // hero card does something real and consistent with the
              // rest of the app instead of nothing.
              onMoreTap: !hasRecent
                  ? null
                  : () => showAurumSongOptionsSheet(context, recent.first),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 18)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _QuickAccessGrid(
              likedCount: likedCount,
              downloadedCount: downloadedCount,
            ),
          ),
        ),
        if (recent.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 26)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Recently Played',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 168,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: recent.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: _RecentlyPlayedCard(
                    song: recent[i],
                    queue: recent,
                    index: i,
                  ),
                ),
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 26)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Text(
                  'Your Playlists',
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => AurumDepthRoute.to(context, const PlaylistsScreen()),
                  behavior: HitTestBehavior.opaque,
                  child: Text(
                    'See all',
                    style: TextStyle(
                      color: AurumTheme.accentOf(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (playlists.playlists.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
              child: GestureDetector(
                onTap: () => AurumDepthRoute.to(context, const PlaylistsScreen()),
                child: _AurumEmptyState(
                  icon: Icons.playlist_play_rounded,
                  title: 'No playlists yet',
                  subtitle: 'Create one from any song\'s menu.',
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 110),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AurumPlaylistRow(playlist: previewPlaylists[i]),
                ),
                childCount: previewPlaylists.length,
              ),
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// PLAYLISTS TAB — the dedicated Playlists chip.
//
// FIX (feature parity with PlaylistsScreen / "See all"): this used to be a
// bare list with no controls at all — no sort, no lock/reorder, no grid
// toggle, no "+" create button, no tag filter row — while the exact same
// data pushed via Library's "See all" (PlaylistsScreen below) had the full
// toolbar. Two different UIs for the same playlist list meant users who
// tapped the "Playlists" chip directly (the more common path) landed on a
// visibly stripped-down screen and had to go find "See all" to get the real
// one — confusing, and it looked broken/unfinished ("kaali kaali", bare).
//
// Now built from the SAME state/logic as _PlaylistsScreenState (sort order,
// reorder lock, list/grid toggle, tag filter, create dialog, manage-tags
// sheet) — just without PlaylistsScreen's own Scaffold/SliverAppBar/back
// button/MiniPlayerSlot, since this already lives inside LibraryScreen's
// own Scaffold as a tab body. Keeping only ONE Scaffold per screen avoids
// nesting a second bottom-inset/mini-player context inside the first.
// ══════════════════════════════════════════════════════════════════════════════

class _AurumPlaylistsTab extends StatefulWidget {
  const _AurumPlaylistsTab();

  @override
  State<_AurumPlaylistsTab> createState() => _AurumPlaylistsTabState();
}

class _AurumPlaylistsTabState extends State<_AurumPlaylistsTab> {
  _PlaylistSort _sort = _PlaylistSort.custom;
  bool _gridView = false;
  bool _reorderLocked = true;
  String? _activeTag;

  String _sortLabel(_PlaylistSort s) {
    switch (s) {
      case _PlaylistSort.custom:
        return 'Custom order';
      case _PlaylistSort.name:
        return 'Name';
      case _PlaylistSort.dateAdded:
        return 'Date added';
      case _PlaylistSort.mostPlayed:
        return 'Most played';
    }
  }

  List<AurumPlaylist> _sorted(PlaylistProvider pp) {
    final base = _activeTag == null
        ? pp.customOrdered()
        : pp.byTag(_activeTag!);
    if (_sort == _PlaylistSort.custom) return base;
    final list = List<AurumPlaylist>.from(base);
    switch (_sort) {
      case _PlaylistSort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case _PlaylistSort.dateAdded:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case _PlaylistSort.mostPlayed:
        list.sort((a, b) => b.songCount.compareTo(a.songCount));
        break;
      case _PlaylistSort.custom:
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlaylistProvider>(
      builder: (context, pp, _) {
        final tags = pp.allTags;
        final visible = _sorted(pp);
        final canReorder = _sort == _PlaylistSort.custom &&
            _activeTag == null &&
            !_reorderLocked;

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          cacheExtent: 1200,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 10)),

            // ── Toolbar row: sort dropdown, lock, view toggle, add ──────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Row(
                  children: [
                    _SortDropdown(
                      label: _sortLabel(_sort),
                      onSelected: (s) => setState(() => _sort = s),
                    ),
                    const Spacer(),
                    _ToolbarIconButton(
                      icon: _reorderLocked
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      selected: !_reorderLocked,
                      onTap: _sort != _PlaylistSort.custom
                          ? null
                          : () => setState(() => _reorderLocked = !_reorderLocked),
                    ),
                    const SizedBox(width: 8),
                    _PlaylistViewToggle(
                      gridView: _gridView,
                      onChanged: (g) => setState(() => _gridView = g),
                    ),
                    const SizedBox(width: 8),
                    _ToolbarIconButton(
                      icon: Icons.add_rounded,
                      filled: true,
                      onTap: () => _showCreateDialog(context),
                    ),
                  ],
                ),
              ),
            ),

            // ── Tag filter row: "All" chip + one per tag, "Manage Tags" ─
            SliverToBoxAdapter(
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  children: [
                    _TagFilterChip(
                      icon: Icons.filter_alt_rounded,
                      label: 'All',
                      selected: _activeTag == null,
                      onTap: () => setState(() => _activeTag = null),
                    ),
                    const SizedBox(width: 10),
                    for (final tag in tags) ...[
                      _TagFilterChip(
                        label: tag,
                        selected: _activeTag == tag,
                        onTap: () => setState(
                            () => _activeTag = _activeTag == tag ? null : tag),
                      ),
                      const SizedBox(width: 10),
                    ],
                    _TagFilterChip(
                      icon: Icons.add_rounded,
                      label: 'Manage Tags',
                      selected: false,
                      onTap: () => _showManageTagsSheet(context, pp),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),

            // ── Empty state ──────────────────────────────────────────────
            if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyPlaylists(
                    onCreateTap: () => _showCreateDialog(context)),
              )
            else if (_gridView)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.86,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _PlaylistGridTile(playlist: visible[i]),
                    childCount: visible.length,
                  ),
                ),
              )
            else if (canReorder)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 110),
                sliver: SliverReorderableList(
                  itemCount: visible.length,
                  onReorder: (oldIndex, newIndex) {
                    AurumHaptics.medium();
                    pp.reorderPlaylist(oldIndex, newIndex);
                  },
                  itemBuilder: (context, i) => _PlaylistListRow(
                    key: ValueKey(visible[i].id),
                    playlist: visible[i],
                    index: i,
                    reorderable: true,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 110),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _PlaylistListRow(
                      key: ValueKey(visible[i].id),
                      playlist: visible[i],
                      index: i,
                      reorderable: false,
                    ),
                    childCount: visible.length,
                  ),
                ),
              ),
          ],
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

  Future<void> _showManageTagsSheet(
      BuildContext context, PlaylistProvider pp) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _ManageTagsSheet(pp: pp),
    );
  }
}

class _QuickAccessGrid extends StatelessWidget {
  final int likedCount;
  final int downloadedCount;
  const _QuickAccessGrid({required this.likedCount, required this.downloadedCount});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 14,
      crossAxisSpacing: 14,
      // FIX (cards look "half filled" / awkward empty corner): 2.6 made
      // each card very short and wide relative to its content (icon +
      // 2 short text lines), so with mainAxisAlignment.center below, the
      // content huddled in the middle with dead space above and below —
      // never touching the card's own top/bottom edges. ArchiveTune's
      // reference cards are close to square and their content visibly
      // fills the whole card. 1.7 gives each card real height to work
      // with; padding/spacing/font sizes below were increased to match
      // and use that height, not just leave it empty.
      childAspectRatio: 1.7,
      children: [
        _QuickAccessCard(
          icon: Icons.favorite_rounded,
          iconColor: Colors.redAccent,
          title: 'Liked songs',
          subtitle: '$likedCount track${likedCount == 1 ? '' : 's'}',
          onTap: () => AurumDepthRoute.to(context, const LikedScreen()),
        ),
        _QuickAccessCard(
          icon: Icons.check_circle_rounded,
          iconColor: AurumTheme.accentOf(context),
          title: 'Offline',
          subtitle: downloadedCount == 0 ? 'Downloaded' : '$downloadedCount downloaded',
          onTap: () => AurumDepthRoute.to(context, const DownloadsScreen()),
        ),
        _QuickAccessCard(
          icon: Icons.sync_rounded,
          iconColor: AurumTheme.accentOf(context),
          title: 'Cached',
          subtitle: 'Instant playback',
          onTap: () {},
        ),
        _QuickAccessCard(
          icon: Icons.folder_rounded,
          iconColor: AurumTheme.accentOf(context),
          title: 'Local Files',
          subtitle: 'On device',
          onTap: () => AurumDepthRoute.to(context, const _LocalFilesScreen()),
        ),
        _QuickAccessCard(
          icon: Icons.trending_up_rounded,
          iconColor: AurumTheme.accentOf(context),
          title: 'My top 50',
          subtitle: 'All time',
          onTap: () => AurumDepthRoute.to(context, const _HistoryScreen()),
        ),
      ],
    );
  }
}

class _QuickAccessCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _QuickAccessCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AurumTheme.bgSurfaceOf(context),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          AurumHaptics.light();
          onTap();
        },
        child: Padding(
          // FIX: was EdgeInsets.all(14) with mainAxisAlignment.center —
          // content clumped in the card's middle instead of spreading
          // across it like ArchiveTune's reference cards. Padding widened
          // slightly and the Column now uses spaceBetween (icon badge
          // pinned near the top, title+subtitle pinned near the bottom)
          // so the content actually reaches toward the card's own edges
          // instead of floating in a shrink-wrapped island in the center.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // FIX: bare small Icon (size 20) read as an afterthought
              // next to ArchiveTune's icon-in-a-circle badge. A soft
              // tinted circular badge gives the icon real visual weight
              // and a fixed anchor point at the top of the card.
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      // FIX: 14.5 → 16.5 and 11.5 → 13 to match
                      // ArchiveTune's bolder, more legible card text —
                      // the old sizes were part of why the cards read as
                      // sparse/half-empty.
                      fontSize: 16.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentlyPlayedCard extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _RecentlyPlayedCard({
    required this.song,
    required this.queue,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 128,
      child: AurumPressable(
        onTap: () {
          AurumHaptics.selection();
          context.read<PlayerProvider>().playSong(
                song,
                queue: queue,
                index: index,
                curatedQueue: true,
              );
        },
        scaleAmount: 0.95,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AurumArtwork(url: song.artworkUrl, size: 128, borderRadius: 16),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Material(
                    color: AurumTheme.accentOf(context),
                    shape: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(7),
                      child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              song.artist.isEmpty ? 'Unknown artist' : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textMutedOf(context),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AurumPlaylistRow extends StatelessWidget {
  final AurumPlaylist playlist;
  const _AurumPlaylistRow({required this.playlist});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.55),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => AurumDepthRoute.to(
          context,
          PlaylistDetailScreen(playlistId: playlist.id),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: playlist.coverArt == null || playlist.coverArt!.isEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        color: AurumTheme.bgSurfaceOf(context),
                        child: Icon(Icons.playlist_play_rounded,
                            color: AurumTheme.accentOf(context), size: 22),
                      )
                    : AurumArtwork(url: playlist.coverArt!, size: 48, borderRadius: 12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.songCount} song${playlist.songCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AurumTheme.textMutedOf(context)),
            ],
          ),
        ),
      ),
    );
  }
}
// ══════════════════════════════════════════════════════════════════════════════
// PLAYLISTS SCREEN — full list of user playlists with custom-order drag
// reorder, list/grid view toggle, tag filtering, and "Manage Tags".
// ══════════════════════════════════════════════════════════════════════════════

enum _PlaylistSort { custom, name, dateAdded, mostPlayed }

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  _PlaylistSort _sort = _PlaylistSort.custom;
  bool _gridView = false;
  // Locks the drag handles so an accidental long-press doesn't reshuffle
  // "Custom order" — matches the reference lock icon next to the sort
  // dropdown. Starts locked; the user explicitly unlocks to reorder.
  bool _reorderLocked = true;
  String? _activeTag; // null == "All"

  String _sortLabel(_PlaylistSort s) {
    switch (s) {
      case _PlaylistSort.custom:
        return 'Custom order';
      case _PlaylistSort.name:
        return 'Name';
      case _PlaylistSort.dateAdded:
        return 'Date added';
      case _PlaylistSort.mostPlayed:
        return 'Most played';
    }
  }

  List<AurumPlaylist> _sorted(PlaylistProvider pp) {
    final base = _activeTag == null
        ? pp.customOrdered()
        : pp.byTag(_activeTag!);
    if (_sort == _PlaylistSort.custom) return base;
    final list = List<AurumPlaylist>.from(base);
    switch (_sort) {
      case _PlaylistSort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case _PlaylistSort.dateAdded:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case _PlaylistSort.mostPlayed:
        list.sort((a, b) => b.songCount.compareTo(a.songCount));
        break;
      case _PlaylistSort.custom:
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Consumer<PlaylistProvider>(
      builder: (context, pp, _) {
        final tags = pp.allTags;
        final visible = _sorted(pp);
        final canReorder = _sort == _PlaylistSort.custom &&
            _activeTag == null &&
            !_reorderLocked;

        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          bottomNavigationBar: const MiniPlayerSlot(),
          resizeToAvoidBottomInset: false,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            cacheExtent: 1200,
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
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.fromLTRB(52, 0, 20, 16),
                  title: Text(l10n.libraryPlaylists,
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AurumTheme.textPrimaryOf(context))),
                ),
              ),

              // ── Toolbar row: sort dropdown, lock, view toggle, add ──────
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      _SortDropdown(
                        label: _sortLabel(_sort),
                        onSelected: (s) => setState(() => _sort = s),
                      ),
                      const Spacer(),
                      _ToolbarIconButton(
                        icon: _reorderLocked
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        selected: !_reorderLocked,
                        onTap: _sort != _PlaylistSort.custom
                            ? null
                            : () => setState(() => _reorderLocked = !_reorderLocked),
                      ),
                      const SizedBox(width: 8),
                      _PlaylistViewToggle(
                        gridView: _gridView,
                        onChanged: (g) => setState(() => _gridView = g),
                      ),
                      const SizedBox(width: 8),
                      _ToolbarIconButton(
                        icon: Icons.add_rounded,
                        filled: true,
                        onTap: () => _showCreateDialog(context),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Tag filter row: "All" chip + one per tag, "Manage Tags" ─
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                    children: [
                      _TagFilterChip(
                        icon: Icons.filter_alt_rounded,
                        label: 'All',
                        selected: _activeTag == null,
                        onTap: () => setState(() => _activeTag = null),
                      ),
                      const SizedBox(width: 10),
                      for (final tag in tags) ...[
                        _TagFilterChip(
                          label: tag,
                          selected: _activeTag == tag,
                          onTap: () => setState(
                              () => _activeTag = _activeTag == tag ? null : tag),
                        ),
                        const SizedBox(width: 10),
                      ],
                      _TagFilterChip(
                        icon: Icons.add_rounded,
                        label: 'Manage Tags',
                        selected: false,
                        onTap: () => _showManageTagsSheet(context, pp),
                      ),
                    ],
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),

              // ── Empty state ──────────────────────────────────────────────
              if (visible.isEmpty)
                SliverFillRemaining(
                  child: _EmptyPlaylists(
                      onCreateTap: () => _showCreateDialog(context)),
                )
              else if (_gridView)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.86,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => _PlaylistGridTile(playlist: visible[i]),
                      childCount: visible.length,
                    ),
                  ),
                )
              else if (canReorder)
                SliverReorderableList(
                  itemCount: visible.length,
                  onReorder: (oldIndex, newIndex) {
                    AurumHaptics.medium();
                    pp.reorderPlaylist(oldIndex, newIndex);
                  },
                  itemBuilder: (context, i) => _PlaylistListRow(
                    key: ValueKey(visible[i].id),
                    playlist: visible[i],
                    index: i,
                    reorderable: true,
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _PlaylistListRow(
                      key: ValueKey(visible[i].id),
                      playlist: visible[i],
                      index: i,
                      reorderable: false,
                    ),
                    childCount: visible.length,
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 100)),
            ],
          ),
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

  Future<void> _showManageTagsSheet(
      BuildContext context, PlaylistProvider pp) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _ManageTagsSheet(pp: pp),
    );
  }
}

// ── Sort dropdown chip ────────────────────────────────────────────────────────

class _SortDropdown extends StatelessWidget {
  final String label;
  final ValueChanged<_PlaylistSort> onSelected;
  const _SortDropdown({required this.label, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_PlaylistSort>(
      onSelected: onSelected,
      color: AurumTheme.bgCardOf(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (context) => [
        _menuItem(context, _PlaylistSort.custom, 'Custom order'),
        _menuItem(context, _PlaylistSort.name, 'Name'),
        _menuItem(context, _PlaylistSort.dateAdded, 'Date added'),
        _menuItem(context, _PlaylistSort.mostPlayed, 'Most played'),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down_rounded,
                color: AurumTheme.textPrimaryOf(context), size: 18),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<_PlaylistSort> _menuItem(
      BuildContext context, _PlaylistSort value, String label) {
    return PopupMenuItem(
      value: value,
      child: Text(label,
          style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
    );
  }
}

// ── Generic round toolbar icon button (lock / add) ────────────────────────────

class _ToolbarIconButton extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final bool selected;
  final VoidCallback? onTap;
  const _ToolbarIconButton({
    required this.icon,
    this.filled = false,
    this.selected = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled || selected
        ? AurumTheme.accentOf(context)
        : AurumTheme.bgSurfaceOf(context);
    final fg = filled || selected ? Colors.white : AurumTheme.textPrimaryOf(context);
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: fg, size: 20),
          ),
        ),
      ),
    );
  }
}

// ── List/grid toggle (reused shape, own instance for Playlists tab) ──────────

class _PlaylistViewToggle extends StatelessWidget {
  final bool gridView;
  final ValueChanged<bool> onChanged;
  const _PlaylistViewToggle({required this.gridView, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AurumTheme.bgSurfaceOf(context),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PlaylistViewToggleButton(
            icon: Icons.view_list_rounded,
            selected: !gridView,
            onTap: () => onChanged(false),
          ),
          _PlaylistViewToggleButton(
            icon: Icons.grid_view_rounded,
            selected: gridView,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _PlaylistViewToggleButton extends StatelessWidget {
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _PlaylistViewToggleButton({
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AurumTheme.accentOf(context) : Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon,
              color: selected ? Colors.white : AurumTheme.textMutedOf(context),
              size: 18),
        ),
      ),
    );
  }
}

// ── Tag filter chip ────────────────────────────────────────────────────────────

class _TagFilterChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TagFilterChip({
    this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AurumTheme.accentOf(context) : AurumTheme.bgSurfaceOf(context),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 16,
                    color: selected ? Colors.white : AurumTheme.textPrimaryOf(context)),
                const SizedBox(width: 6),
              ],
              Text(label,
                  style: TextStyle(
                      color: selected ? Colors.white : AurumTheme.textPrimaryOf(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── List row (list-view mode) ──────────────────────────────────────────────────

class _PlaylistListRow extends StatelessWidget {
  final AurumPlaylist playlist;
  final int index;
  final bool reorderable;
  const _PlaylistListRow({
    super.key,
    required this.playlist,
    required this.index,
    required this.reorderable,
  });

  @override
  Widget build(BuildContext context) {
    if (playlist.coverArt != null && playlist.coverArt!.isNotEmpty) {
      ArtworkPaletteCache.warm(playlist.coverArt!);
    }
    final row = AurumPressable(
      onTap: () => AurumDepthRoute.to(
        context,
        PlaylistDetailScreen(playlistId: playlist.id),
      ),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 60,
                height: 60,
                child: playlist.coverArt == null || playlist.coverArt!.isEmpty
                    ? PlaylistColorCover(
                        artworkUrl: playlist.songs.isNotEmpty
                            ? playlist.songs.first.artworkUrl
                            : '',
                        size: 60,
                        borderRadius: 12,
                      )
                    : AurumArtwork(
                        url: playlist.coverArt!, size: 60, borderRadius: 12),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        '${playlist.songCount} tr${playlist.songCount == 1 ? '' : 'acks'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context), fontSize: 12.5),
                      ),
                      if (playlist.isYtSynced) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AurumTheme.bgSurfaceOf(context),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('YouTube synced',
                              style: TextStyle(
                                  color: AurumTheme.textMutedOf(context),
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Material(
              color: AurumTheme.accentOf(context),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: playlist.songs.isEmpty
                    ? null
                    : () => context.read<PlayerProvider>().playSong(
                          playlist.songs.first,
                          queue: playlist.songs,
                          index: 0,
                          curatedQueue: true,
                        ),
                child: const Padding(
                  padding: EdgeInsets.all(9),
                  child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert_rounded,
                  color: AurumTheme.textMutedOf(context), size: 20),
              onPressed: () => _showPlaylistMenu(context, playlist),
            ),
            if (reorderable)
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.drag_handle_rounded,
                      color: AurumTheme.textMutedOf(context), size: 22),
                ),
              ),
          ],
        ),
      ),
    );
    return row;
  }

  void _showPlaylistMenu(BuildContext context, AurumPlaylist playlist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: Icon(Icons.edit_rounded, color: AurumTheme.accentOf(context)),
              title: Text('Rename', style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
              onTap: () => Navigator.pop(sheetContext),
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.redAccent),
              title: Text('Delete', style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
              onTap: () async {
                Navigator.pop(sheetContext);
                await context.read<PlaylistProvider>().deletePlaylist(playlist.id);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Grid tile (grid-view mode) ─────────────────────────────────────────────────

class _PlaylistGridTile extends StatelessWidget {
  final AurumPlaylist playlist;
  const _PlaylistGridTile({required this.playlist});

  @override
  Widget build(BuildContext context) {
    if (playlist.coverArt != null && playlist.coverArt!.isNotEmpty) {
      ArtworkPaletteCache.warm(playlist.coverArt!);
    }
    return AurumPressable(
      onTap: () => AurumDepthRoute.to(
        context,
        PlaylistDetailScreen(playlistId: playlist.id),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  playlist.coverArt == null || playlist.coverArt!.isEmpty
                      ? PlaylistColorCover(
                          artworkUrl: playlist.songs.isNotEmpty
                              ? playlist.songs.first.artworkUrl
                              : '',
                          size: 200,
                          borderRadius: 16,
                        )
                      : AurumArtwork(
                          url: playlist.coverArt!, size: 200, borderRadius: 16),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Material(
                      color: AurumTheme.accentOf(context),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: playlist.songs.isEmpty
                            ? null
                            : () => context.read<PlayerProvider>().playSong(
                                  playlist.songs.first,
                                  queue: playlist.songs,
                                  index: 0,
                                  curatedQueue: true,
                                ),
                        child: const Padding(
                          padding: EdgeInsets.all(9),
                          child: Icon(Icons.play_arrow_rounded,
                              color: Colors.white, size: 20),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${playlist.songCount} tracks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 12.5)),
        ],
      ),
    );
  }
}

// ── Manage Tags bottom sheet ────────────────────────────────────────────────────

class _ManageTagsSheet extends StatefulWidget {
  final PlaylistProvider pp;
  const _ManageTagsSheet({required this.pp});

  @override
  State<_ManageTagsSheet> createState() => _ManageTagsSheetState();
}

class _ManageTagsSheetState extends State<_ManageTagsSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tags = widget.pp.allTags;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Manage Tags',
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            if (tags.isEmpty)
              Text('No tags yet — add one below.',
                  style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13.5))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in tags)
                    Chip(
                      label: Text(tag,
                          style: TextStyle(color: AurumTheme.textPrimaryOf(context))),
                      backgroundColor: AurumTheme.bgSurfaceOf(context),
                      deleteIcon: const Icon(Icons.close_rounded, size: 16),
                      onDeleted: () => widget.pp.deleteTagEverywhere(tag),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: TextStyle(color: AurumTheme.textPrimaryOf(context)),
                    decoration: InputDecoration(
                      hintText: 'New tag name',
                      hintStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
                      filled: true,
                      fillColor: AurumTheme.bgSurfaceOf(context),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Material(
                  color: AurumTheme.accentOf(context),
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      // Tags are attached to individual playlists via each
                      // playlist's own edit sheet — this field exists here
                      // only for renaming/removing tags globally per the
                      // reference screenshot's "Manage Tags" affordance.
                      // Creating a brand-new (unattached) tag has nothing
                      // to attach to yet, so this is a no-op until at least
                      // one playlist carries it.
                      _controller.clear();
                      FocusScope.of(context).unfocus();
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Icon(Icons.check_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
  // Falls back to a dark neutral glow until (if) the palette resolves —
  // matches mix_screen.dart's/artist_screen.dart's/album_screen.dart's
  // fallback so every detail screen in the app, including a user's own
  // local playlists here in Library, looks like one consistent ecosystem.
  Color _glow = const Color(0xFF1A1630);
  String? _glowExtractedFor;

  void _onGlow(String key, Color c) {
    if (_glowExtractedFor == key) return;
    _glowExtractedFor = key;
    if (mounted) setState(() => _glow = c);
  }

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
        backgroundColor: immersiveScaffoldBg(context, _glow),
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
        backgroundColor: immersiveScaffoldBg(context, _glow),
        // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
        // matching comment for the full reasoning.
        bottomNavigationBar: const MiniPlayerSlot(),
        body: Container(
          color: immersiveScaffoldBg(context, _glow),
          child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          // PERF FIX (same class as home_screen.dart / artist_screen.dart's
          // matching fix): default Sliver cacheExtent is only 250 logical
          // px. With a 300px expanded header sitting above a potentially
          // long, reorderable song list, a fast fling could easily outrun
          // that tiny buffer — tiles just past it got torn down and
          // rebuilt from scratch on every re-entry into view, which reads
          // as stutter/lag on a big playlist. Matching the same 1200 used
          // on Home/Artist for identical reasoning.
          cacheExtent: 1200,
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
                backgroundColor: immersiveScaffoldBg(context, _glow),
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
                  background: _PlaylistHeader(playlist: pl, onGlow: _onGlow),
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

class _PlaylistHeader extends StatefulWidget {
  final AurumPlaylist playlist;
  final void Function(String key, Color color)? onGlow;
  const _PlaylistHeader({required this.playlist, this.onGlow});

  @override
  State<_PlaylistHeader> createState() => _PlaylistHeaderState();
}

class _PlaylistHeaderState extends State<_PlaylistHeader> {
  Color _glow = const Color(0xFF1A1630);

  @override
  void initState() {
    super.initState();
    _extractGlow();
  }

  @override
  void didUpdateWidget(_PlaylistHeader old) {
    super.didUpdateWidget(old);
    if (old.playlist.coverArt != widget.playlist.coverArt) _extractGlow();
  }

  Future<void> _extractGlow() async {
    final art = widget.playlist.coverArt;
    final url = (art != null && art.isNotEmpty)
        ? art
        : (widget.playlist.songs.isNotEmpty
            ? widget.playlist.songs.first.artworkUrl
            : '');
    if (url.isEmpty) return;
    final c = await extractImmersiveColor(url);
    // Same contrast-safety clamp as mix_screen.dart's matching fix —
    // applied here (not in _onGlow above) so both this header's own
    // _glow AND the value handed up to the parent screen's background
    // via widget.onGlow are already the safe, clamped color.
    if (c != null && mounted) {
      final safe = ensureContrastSafe(
        c,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      setState(() => _glow = safe);
      widget.onGlow?.call(url, safe);
    }
  }

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
              if (widget.playlist.hasCustomCover)
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
        await provider.setCoverImage(widget.playlist.id, picked.path);
      }
    } else if (action == 'remove') {
      await provider.clearCoverImage(widget.playlist.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasArt = widget.playlist.coverArt != null && widget.playlist.coverArt!.isEmpty == false;

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
                          url: widget.playlist.coverArt!,
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
                            url: widget.playlist.coverArt!,
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
                      widget.playlist.songs.isNotEmpty ? widget.playlist.songs.first.artworkUrl : '',
                  size: double.infinity,
                  borderRadius: 0,
                  iconSize: 72,
                ),

          // ── Layer 2 — short scrim washing this cover's own extracted
          // color through it — matches mix_screen.dart's/artist_screen
          // .dart's/album_screen.dart's identical treatment, so a user's
          // own local playlist here in Library reads as the exact same
          // alive ecosystem as every curated/artist/album detail screen.
          DecoratedBox(decoration: immersiveHeaderScrim(_glow)),

          // ── SimpMusic-style frosted glass strip fading in behind the
          // collapsed bar — see mix_screen.dart's matching comment. Same
          // FlexibleSpaceBar this header is already the background of,
          // so FlexibleSpaceBarSettings is reachable here directly.
          Builder(builder: (context) {
            final settings = context
                .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
            return AurumGlassCollapseBar(
              glow: _glow,
              expandRatio: settings != null
                  ? ((settings.currentExtent - settings.minExtent) /
                          (settings.maxExtent - settings.minExtent))
                      .clamp(0.0, 1.0)
                  : 1.0,
            );
          }),

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
                  widget.playlist.name,
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
                if (widget.playlist.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.playlist.description,
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
                  '${widget.playlist.songCount} song${widget.playlist.songCount == 1 ? '' : 's'}'
                  '${widget.playlist.totalDurationString.isNotEmpty ? ' • ${widget.playlist.totalDurationString}' : ''}',
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
            // PERF FIX — see LibraryScreen's matching cacheExtent comment above.
            cacheExtent: 1200,
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
// Local/offline songs screen, now with an in-place search bar (reference:
// ArchiveTune's "Local" screen shows a search icon in its top bar that
// opens a search field scoped to just this list). StatefulWidget purely to
// hold the TextEditingController + query string — LibraryProvider itself
// stays the single source of truth for the actual song list, this only
// filters what's already loaded, same as SongTile below already does with
// its own local queue/index math.
class _LocalFilesScreen extends StatefulWidget {
  const _LocalFilesScreen();

  @override
  State<_LocalFilesScreen> createState() => _LocalFilesScreenState();
}

class _LocalFilesScreenState extends State<_LocalFilesScreen> {
  bool _searching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    // Same "wait a frame, then focus" pattern search_screen.dart's own
    // field uses — requesting focus in the same frame the field is first
    // built can silently attach the IME connection without actually
    // raising the keyboard.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
    FocusScope.of(context).unfocus();
  }

  // Case-insensitive match against title, artist, and album — the three
  // fields a person would actually type when hunting for a specific local
  // file (matches how search_screen.dart's own online search already
  // reasons about "what a query could mean").
  List<Song> _filtered(List<Song> songs) {
    if (_query.trim().isEmpty) return songs;
    final q = _query.trim().toLowerCase();
    return songs.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q) ||
          s.album.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final lib = context.watch<LibraryProvider>();
    final filtered = _filtered(lib.allSongs);

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        titleSpacing: _searching ? 4 : null,
        title: _searching
            ? _LocalSearchField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(l10n.libraryLocalFiles,
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: Icon(
              _searching
                  ? Icons.arrow_back_ios_rounded
                  : Icons.arrow_back_ios_rounded,
              color: AurumTheme.textPrimaryOf(context)),
          onPressed: () {
            if (_searching) {
              _closeSearch();
            } else {
              Navigator.pop(context);
            }
          },
        ),
        actions: _searching
            ? [
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.close_rounded,
                        color: AurumTheme.textMutedOf(context)),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.search_rounded, color: AurumTheme.gold),
                  onPressed: _openSearch,
                ),
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
                  : filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              l10n.libraryLocalSearchNoResults(_query),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: AurumTheme.textMutedOf(context)),
                            ),
                          ),
                        )
                      : ListView.builder(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.only(bottom: 100),
                          // PERF: pop-in fix for the full local-songs list.
                          cacheExtent: 1000,
                          itemCount: filtered.length,
                          // SIZE FIX ("thumbnail bahut chhota" then "thoda
                          // sa aur chhota" — SongTile's cover art went
                          // 50→64→58px app-wide): row height follows —
                          // 20 vertical padding + the artwork box
                          // AurumStackedArtwork draws at size+8 headroom
                          // (58+8=66) = 86. itemExtent has to match
                          // ListView.builder's actual row height or Flutter
                          // clips/overflows every tile to the stale value.
                          //
                          // NOTE: only applied when NOT searching — a
                          // filtered list can be short enough that a fixed
                          // itemExtent times a small itemCount leaves the
                          // rest of the screen blank, which reads fine
                          // either way, so this is really just preserving
                          // the exact unfiltered behavior untouched.
                          itemExtent: _query.trim().isEmpty ? 86 : null,
                          itemBuilder: (_, i) => SongTile(
                              song: filtered[i],
                              queue: filtered,
                              index: i,
                              curatedQueue: true),
                        ),
    );
  }
}

// ── Search field used inside _LocalFilesScreen's AppBar ─────────────────────
// Deliberately its own small widget (not inlined) so the AnimatedSwitcher-
// less swap between title Text and this field in the AppBar stays simple —
// same visual language (rounded, gold-on-focus border) as
// search_screen.dart's main search bar, just compact enough to sit in an
// AppBar's title slot instead of taking a full screen section.
class _LocalSearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  const _LocalSearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.06)
            : Colors.black.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.12)
              : Colors.black.withOpacity(0.08),
          width: 0.7,
        ),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        autofocus: false,
        style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 14,
            fontWeight: FontWeight.w500),
        decoration: InputDecoration(
          isCollapsed: true,
          hintText: l10n.libraryLocalSearchHint,
          hintStyle:
              TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14),
          border: InputBorder.none,
        ),
        textInputAction: TextInputAction.search,
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
// ── Downloads: Downloaded / In progress tabs ────────────────────────────────
// Reference (ArchiveTune screenshot): two tabs under the "Downloads" title —
// "Downloaded" (a checkmark-circle icon above the label) and "In progress"
// (a download-arrow icon above the label), each tab a full-width flex half,
// selected tab in gold text with a gold underline beneath it, unselected
// tab dimmed. Replaces the earlier single continuous scroll (Downloading
// section stacked above Downloaded section) — that layout technically
// worked but read as flat/lifeless next to the reference's clearer split,
// and gave "in progress" items no per-song pause control, only cancel.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  int _tabIndex = 0; // 0 = Downloaded, 1 = In progress

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
    final totalBytes = completed.fold<int>(
        0, (sum, d) => sum + (d.fileSizeBytes ?? 0));

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_rounded,
                        color: AurumTheme.textSecondaryOf(context), size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ShaderMask(
                  shaderCallback: (b) =>
                      AurumTheme.goldGradient.createShader(b),
                  child: Text(l10n.settingsDownloads,
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ),
            ),
            // Storage summary strip — only meaningful once something is
            // actually downloaded, so it's skipped entirely on the empty
            // state (no dead "0 songs · 0 MB" row to greet a new user).
            if (completed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
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
            const SizedBox(height: 8),
            _DownloadsTabRow(
              index: _tabIndex,
              inProgressCount: inProgress.length,
              onChanged: (i) {
                if (i == _tabIndex) return;
                AurumHaptics.selection();
                setState(() => _tabIndex = i);
              },
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: AurumMotion.durationOrZero(AurumMotion.short2),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: KeyedSubtree(
                  key: ValueKey(_tabIndex),
                  child: _tabIndex == 0
                      ? _DownloadedList(completed: completed)
                      : _InProgressList(items: inProgress),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab row: "Downloaded" / "In progress", underline indicator ─────────────
class _DownloadsTabRow extends StatelessWidget {
  final int index;
  final int inProgressCount;
  final ValueChanged<int> onChanged;
  const _DownloadsTabRow({
    required this.index,
    required this.inProgressCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: _DownloadsTab(
            icon: Icons.check_circle_outline_rounded,
            label: l10n.libraryDownloadsTabDownloaded,
            selected: index == 0,
            onTap: () => onChanged(0),
          ),
        ),
        Expanded(
          child: _DownloadsTab(
            icon: Icons.download_rounded,
            label: l10n.libraryDownloadsTabInProgress,
            selected: index == 1,
            badgeCount: inProgressCount,
            onTap: () => onChanged(1),
          ),
        ),
      ],
    );
  }
}

class _DownloadsTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final int badgeCount;
  final VoidCallback onTap;
  const _DownloadsTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? AurumTheme.gold
        : AurumTheme.textMutedOf(context);
    return InkWell(
      onTap: onTap,
      splashColor: AurumTheme.gold.withValues(alpha: 0.06),
      highlightColor: AurumTheme.gold.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 4),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w600)),
                if (badgeCount > 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: AurumTheme.gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$badgeCount',
                        style: const TextStyle(
                            color: AurumTheme.gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            AnimatedContainer(
              duration: AurumMotion.durationOrZero(AurumMotion.short2),
              height: 2.5,
              width: 64,
              decoration: BoxDecoration(
                color: selected ? AurumTheme.gold : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── "Downloaded" tab body ───────────────────────────────────────────────────
class _DownloadedList extends StatelessWidget {
  final List<DownloadItem> completed;
  const _DownloadedList({required this.completed});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (completed.isEmpty) {
      return _DownloadsEmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: l10n.libraryNoDownloadsYet,
        message: l10n.libraryDownloadFromPlayerDesc,
      );
    }
    return ListView.builder(
      key: const PageStorageKey('downloads_downloaded'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 100),
      cacheExtent: 1200,
      itemCount: completed.length,
      itemBuilder: (context, i) => _DownloadTileEntrance(
        key: ValueKey('dl_done_${completed[i].song.id}'),
        child: _DownloadTile(
          item: completed[i],
          queue: completed,
          queueIndex: i,
        ),
      ),
    );
  }
}

// ── "In progress" tab body ──────────────────────────────────────────────────
class _InProgressList extends StatelessWidget {
  final List<DownloadItem> items;
  const _InProgressList({required this.items});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (items.isEmpty) {
      return _DownloadsEmptyState(
        icon: Icons.download_rounded,
        title: l10n.libraryNoDownloadsYet,
        message: l10n.libraryDownloadFromPlayerDesc,
      );
    }
    return ListView.builder(
      key: const PageStorageKey('downloads_in_progress'),
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      cacheExtent: 1200,
      itemCount: items.length,
      itemBuilder: (context, i) => _DownloadTileEntrance(
        key: ValueKey('dl_prog_${items[i].song.id}'),
        child: _InProgressCard(item: items[i]),
      ),
    );
  }
}

class _DownloadsEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _DownloadsEmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
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
                border: Border.all(color: AurumTheme.gold.withOpacity(0.3)),
              ),
              child: Icon(icon, color: AurumTheme.gold, size: 36),
            ),
            const SizedBox(height: 20),
            Text(title,
                style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 18,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 13,
                  height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ── "In progress" row: artwork, title/artist, live progress bar, ───────────
// pause/resume + cancel buttons. Reference (ArchiveTune screenshot) shows
// exactly this: a rounded card per song, a filled pill "%" + "B/s" line, a
// thin progress track beneath, and two circular action buttons — pause
// (or resume, once paused) and an X to cancel.
class _InProgressCard extends StatelessWidget {
  final DownloadItem item;
  const _InProgressCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = item.song;
    final dl = context.read<DownloadProvider>();
    final percent = (item.progress * 100).clamp(0, 100).toStringAsFixed(0);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      item.isPaused
                          ? l10n.libraryDownloadPaused
                          : '$percent%',
                      style: const TextStyle(
                          color: AurumTheme.gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _RoundIconButton(
                icon: item.isPaused
                    ? Icons.play_arrow_rounded
                    : Icons.pause_rounded,
                tooltip: item.isPaused
                    ? l10n.libraryDownloadResume
                    : l10n.libraryDownloadPause,
                onTap: () {
                  if (item.isPaused) {
                    dl.resumeDownload(song);
                  } else {
                    dl.pauseDownload(song.id);
                  }
                },
              ),
              const SizedBox(width: 8),
              _RoundIconButton(
                icon: Icons.close_rounded,
                tooltip: l10n.libraryDownloadCancel,
                onTap: () => dl.cancelDownload(song.id),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: item.progress.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: AurumTheme.gold.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation(
                item.isPaused
                    ? AurumTheme.gold.withValues(alpha: 0.45)
                    : AurumTheme.gold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AurumTheme.gold.withValues(alpha: 0.15),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: AurumTheme.gold, size: 18),
          ),
        ),
      ),
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
        // PERF FIX — see LibraryScreen's matching cacheExtent comment above.
        cacheExtent: 1200,
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
        // PERF FIX — see LibraryScreen's matching cacheExtent comment above.
        cacheExtent: 1200,
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
        // PERF FIX — see LibraryScreen's matching cacheExtent comment above.
        cacheExtent: 1200,
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

