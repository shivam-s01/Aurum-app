import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../models/song.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_artwork.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _LibraryView();
  }
}

class _LibraryView extends StatefulWidget {
  const _LibraryView();

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  static const _tabs = [
    'Recents',
    'Favourites',
    'Local',
    'Downloads',
    'Playlists',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lib = context.read<LibraryProvider>();
      if (!lib.hasLocalLoaded) lib.loadLocalMusic();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(child: _buildHeader(context)),
        ],
        body: Column(
          children: [
            _buildTabBar(context),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _RecentlyPlayedTab(),
                  _FavouritesTab(),
                  _LocalSongsTab(),
                  _DownloadsTab(),
                  _PlaylistsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 16, 20, 0),
      child: Row(
        children: [
          ShaderMask(
            shaderCallback: (b) =>
                AurumTheme.goldGradient.createShader(b),
            child: const Text(
              'Library',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const Spacer(),
          _IconBtn(
            icon: Icons.settings_outlined,
            onTap: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      height: 36,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        labelPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        indicator: BoxDecoration(
          color: AurumTheme.gold.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: AurumTheme.gold.withValues(alpha: 0.4), width: 0.8),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: AurumTheme.gold,
        unselectedLabelColor: AurumTheme.textMutedOf(context),
        labelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w400),
        tabs: _tabs.map((t) => Tab(text: t, height: 36)).toList(),
      ),
    );
  }
}

// ── Recently Played Tab ───────────────────────────────────────────────────────

class _RecentlyPlayedTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final songs = lib.recentlyPlayed;

    if (songs.isEmpty) {
      return _EmptyState(
        icon: Icons.history_rounded,
        title: 'No recent plays',
        subtitle: 'Songs you listen to will appear here',
      );
    }

    return _SongListView(
      songs: songs,
      trailing: songs.isNotEmpty
          ? TextButton(
              onPressed: () {},
              child: const Text('Clear',
                  style: TextStyle(
                      color: AurumTheme.gold, fontSize: 12)),
            )
          : null,
    );
  }
}

// ── Favourites Tab ────────────────────────────────────────────────────────────

class _FavouritesTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final songs = lib.favorites;

    if (songs.isEmpty) {
      return _EmptyState(
        icon: Icons.favorite_outline_rounded,
        title: 'No favourites yet',
        subtitle: 'Tap ♥ on any song to add it here',
      );
    }

    return _SongListView(songs: songs);
  }
}

// ── Local Songs Tab ───────────────────────────────────────────────────────────

class _LocalSongsTab extends StatefulWidget {
  @override
  State<_LocalSongsTab> createState() => _LocalSongsTabState();
}

class _LocalSongsTabState extends State<_LocalSongsTab> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();

    return Column(
      children: [
        if (_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _SearchField(
              controller: _searchCtrl,
              onChanged: lib.setLocalSearch,
              onClear: () {
                _searchCtrl.clear();
                lib.clearLocalSearch();
              },
            ),
          ),
        Expanded(child: _buildBody(context, lib)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, LibraryProvider lib) {
    switch (lib.localStatus) {
      case LibraryStatus.idle:
      case LibraryStatus.loading:
        return const Center(
          child: CircularProgressIndicator(
              color: AurumTheme.gold, strokeWidth: 2),
        );

      case LibraryStatus.noPermission:
        return _PermissionPrompt(onGrant: lib.loadLocalMusic);

      case LibraryStatus.empty:
        return _EmptyState(
          icon: Icons.folder_open_rounded,
          title: 'No local music found',
          subtitle: 'Add MP3, FLAC or M4A files to your device',
        );

      case LibraryStatus.loaded:
        final songs = _searching
            ? lib.filteredLocalSongs
            : lib.localSongs;

        if (songs.isEmpty) {
          return _EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No results',
            subtitle: 'Try a different search term',
          );
        }

        return Column(
          children: [
            _LocalHeader(
              count: songs.length,
              searching: _searching,
              onToggleSearch: () {
                setState(() => _searching = !_searching);
                if (!_searching) {
                  _searchCtrl.clear();
                  lib.clearLocalSearch();
                }
              },
              onRefresh: lib.refreshLocalMusic,
            ),
            Expanded(child: _SongListView(songs: songs)),
          ],
        );
    }
  }
}

class _LocalHeader extends StatelessWidget {
  final int count;
  final bool searching;
  final VoidCallback onToggleSearch;
  final VoidCallback onRefresh;

  const _LocalHeader({
    required this.count,
    required this.searching,
    required this.onToggleSearch,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: [
          Text(
            '$count songs',
            style: TextStyle(
                color: AurumTheme.textMutedOf(context), fontSize: 12),
          ),
          const Spacer(),
          IconButton(
            icon: Icon(
              searching
                  ? Icons.search_off_rounded
                  : Icons.search_rounded,
              color: searching
                  ? AurumTheme.gold
                  : AurumTheme.textMutedOf(context),
              size: 20,
            ),
            onPressed: onToggleSearch,
            splashRadius: 20,
          ),
          IconButton(
            icon: Icon(Icons.refresh_rounded,
                color: AurumTheme.textMutedOf(context), size: 20),
            onPressed: onRefresh,
            splashRadius: 20,
          ),
        ],
      ),
    );
  }
}

// ── Downloads Tab ─────────────────────────────────────────────────────────────

class _DownloadsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final songs = lib.downloads;

    if (songs.isEmpty) {
      return _EmptyState(
        icon: Icons.download_outlined,
        title: 'No downloads yet',
        subtitle: 'Downloaded songs play offline',
      );
    }

    return _SongListView(songs: songs);
  }
}

// ── Playlists Tab ─────────────────────────────────────────────────────────────

class _PlaylistsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final playlists = lib.playlists;

    if (playlists.isEmpty) {
      return _EmptyState(
        icon: Icons.queue_music_outlined,
        title: 'No playlists',
        subtitle: 'Create playlists to organise your music',
        action: TextButton.icon(
          onPressed: () => _showCreateDialog(context, lib),
          icon: const Icon(Icons.add_rounded,
              color: AurumTheme.gold, size: 18),
          label: const Text('Create Playlist',
              style:
                  TextStyle(color: AurumTheme.gold, fontSize: 13)),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Text(
                '${playlists.length} playlists',
                style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_rounded,
                    color: AurumTheme.gold, size: 22),
                onPressed: () => _showCreateDialog(context, lib),
                splashRadius: 20,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: playlists.keys.length,
            itemBuilder: (context, i) {
              final name = playlists.keys.elementAt(i);
              final songs = playlists[name]!;
              return _PlaylistTile(
                name: name,
                songs: songs,
                onDelete: () => lib.deletePlaylist(name),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showCreateDialog(BuildContext context, LibraryProvider lib) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AurumTheme.bgElevatedOf(context),
        title: Text('New Playlist',
            style:
                TextStyle(color: AurumTheme.textPrimaryOf(context))),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style:
              TextStyle(color: AurumTheme.textPrimaryOf(context)),
          decoration: InputDecoration(
            hintText: 'Playlist name',
            hintStyle:
                TextStyle(color: AurumTheme.textMutedOf(context)),
            border: UnderlineInputBorder(
              borderSide:
                  BorderSide(color: AurumTheme.dividerOf(context)),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AurumTheme.gold),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel',
                style: TextStyle(
                    color: AurumTheme.textMutedOf(context))),
          ),
          TextButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                lib.createPlaylist(ctrl.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Create',
                style: TextStyle(color: AurumTheme.gold)),
          ),
        ],
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final String name;
  final List<Song> songs;
  final VoidCallback onDelete;

  const _PlaylistTile({
    required this.name,
    required this.songs,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AurumTheme.bgElevatedOf(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AurumTheme.dividerOf(context), width: 0.5),
        ),
        child: songs.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AurumArtwork(
                  url: songs.first.artworkUrl,
                  size: 52,
                  borderRadius: 10,
                ),
              )
            : Icon(Icons.queue_music_rounded,
                color: AurumTheme.textMutedOf(context), size: 24),
      ),
      title: Text(
        name,
        style: TextStyle(
          color: AurumTheme.textPrimaryOf(context),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${songs.length} songs',
        style: TextStyle(
            color: AurumTheme.textMutedOf(context), fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert_rounded,
            color: AurumTheme.textMutedOf(context), size: 18),
        color: AurumTheme.bgElevatedOf(context),
        onSelected: (val) {
          if (val == 'delete') onDelete();
          if (val == 'play' && songs.isNotEmpty) {
            player.playSong(songs.first, queue: songs, index: 0);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'play',
            child: Row(children: [
              const Icon(Icons.play_arrow_rounded,
                  color: AurumTheme.gold, size: 18),
              const SizedBox(width: 10),
              Text('Play',
                  style: TextStyle(
                      color: AurumTheme.textPrimaryOf(context),
                      fontSize: 13)),
            ]),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete_outline_rounded,
                  color: Colors.redAccent.withValues(alpha: 0.8),
                  size: 18),
              const SizedBox(width: 10),
              const Text('Delete',
                  style: TextStyle(
                      color: Colors.redAccent, fontSize: 13)),
            ]),
          ),
        ],
      ),
      onTap: songs.isNotEmpty
          ? () => player.playSong(songs.first,
              queue: songs, index: 0)
          : null,
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _SongListView extends StatelessWidget {
  final List<Song> songs;
  final Widget? trailing;

  const _SongListView({required this.songs, this.trailing});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 120, top: 8),
      itemCount: songs.length + (trailing != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (trailing != null && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [trailing!],
            ),
          );
        }
        final idx = trailing != null ? i - 1 : i;
        return SongTile(
          song: songs[idx],
          queue: songs,
          index: idx,
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AurumTheme.bgElevatedOf(context),
                shape: BoxShape.circle,
              ),
              child: Icon(icon,
                  color:
                      AurumTheme.gold.withValues(alpha: 0.4),
                  size: 32),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(
                color: AurumTheme.textMutedOf(context),
                fontSize: 13,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionPrompt extends StatelessWidget {
  final VoidCallback onGrant;
  const _PermissionPrompt({required this.onGrant});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AurumTheme.bgElevatedOf(context),
                shape: BoxShape.circle,
                border: Border.all(
                    color:
                        AurumTheme.gold.withValues(alpha: 0.3)),
              ),
              child: const Icon(Icons.folder_rounded,
                  color: AurumTheme.gold, size: 36),
            ),
            const SizedBox(height: 24),
            Text(
              'Music Access Needed',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Allow Aurum to read your music files to play local songs.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: onGrant,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 36, vertical: 14),
                decoration: BoxDecoration(
                  gradient: AurumTheme.goldGradient,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Text(
                  'Grant Permission',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        onChanged: onChanged,
        style: TextStyle(
            color: AurumTheme.textPrimaryOf(context), fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search local songs...',
          hintStyle: TextStyle(
              color: AurumTheme.textMutedOf(context), fontSize: 14),
          prefixIcon: Icon(Icons.search_rounded,
              color: AurumTheme.textMutedOf(context), size: 20),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close_rounded,
                      color: AurumTheme.textMutedOf(context),
                      size: 18),
                  onPressed: onClear,
                )
              : null,
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AurumTheme.bgElevatedOf(context),
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            color: AurumTheme.textSecondaryOf(context), size: 18),
      ),
    );
  }
}
