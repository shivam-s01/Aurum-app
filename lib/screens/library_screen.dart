import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../widgets/song_tile.dart';
import '../models/song.dart';
import 'settings_screen.dart';
import 'liked_screen.dart';

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
                const SizedBox(height: 8),
                _buildQuickAccess(context),
                const SizedBox(height: 24),
                _buildSectionTitle(context, 'YOUR COLLECTION'),
                _buildCollectionGrid(context),
                const SizedBox(height: 24),
                _buildSectionTitle(context, 'RECENTLY PLAYED'),
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
      expandedHeight: 100,
      floating: true,
      snap: true,
      backgroundColor: AurumTheme.bgOf(context),
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 0, 16),
        title: Text('Library',
            style: TextStyle(
                color: AurumTheme.gold,
                fontSize: 28,
                fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _buildQuickAccess(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _QuickChip(
            icon: Icons.favorite_rounded,
            label: 'Liked',
            color: Colors.pinkAccent,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LikedScreen())),
          ),
          const SizedBox(width: 10),
          _QuickChip(
            icon: Icons.download_rounded,
            label: 'Downloads',
            color: Colors.amber,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const _DownloadsScreen())),
          ),
          const SizedBox(width: 10),
          _QuickChip(
            icon: Icons.history_rounded,
            label: 'History',
            color: Colors.teal,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const _HistoryScreen())),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Text(title,
          style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5)),
    );
  }

  Widget _buildCollectionGrid(BuildContext context) {
    final favCount = context.watch<FavoritesProvider>().favorites.length;
    final lib = context.watch<LibraryProvider>();

    final items = [
      _CollectionItem(
        icon: Icons.favorite_rounded,
        label: 'Liked Songs',
        subtitle: '$favCount songs',
        color: Colors.pinkAccent,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const LikedScreen())),
      ),
      _CollectionItem(
        icon: Icons.queue_music_rounded,
        label: 'Playlists',
        subtitle: 'Your playlists',
        color: Colors.purpleAccent,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const _PlaylistsScreen())),
      ),
      _CollectionItem(
        icon: Icons.album_rounded,
        label: 'Albums',
        subtitle: 'Saved albums',
        color: Colors.deepPurple,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const _AlbumsScreen())),
      ),
      _CollectionItem(
        icon: Icons.person_rounded,
        label: 'Artists',
        subtitle: 'Following',
        color: Colors.blueAccent,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const _ArtistsScreen())),
      ),
      _CollectionItem(
        icon: Icons.folder_rounded,
        label: 'Local Files',
        subtitle:
            lib.hasLoaded ? '${lib.allSongs.length} songs' : 'On this device',
        color: Colors.green,
        onTap: () async {
          if (!lib.hasLoaded) await lib.load();
          if (context.mounted) {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const _LocalFilesScreen()));
          }
        },
      ),
      _CollectionItem(
        icon: Icons.history_rounded,
        label: 'Recently Played',
        subtitle: 'Listen history',
        color: Colors.orange,
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const _HistoryScreen())),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 2.2,
        children: items.map((item) => _CollectionCard(item: item)).toList(),
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
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const _HistoryScreen())),
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

// ── History Screen ─────────────────────────────────────────────────────────
class _HistoryScreen extends StatelessWidget {
  const _HistoryScreen();

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
                      Icon(Icons.history_rounded,
                          color: Colors.teal, size: 22),
                      const SizedBox(width: 8),
                      ShaderMask(
                        shaderCallback: (b) =>
                            AurumTheme.goldGradient.createShader(b),
                        child: const Text('History',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                    ],
                  ),
                ),
              ),
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
                            color: Colors.teal.withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.history_rounded,
                              color: Colors.teal, size: 36),
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
              else
                SliverList(
                  delegate: SliverChildListDelegate([
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Text('${history.length} songs',
                              style: TextStyle(
                                  color: AurumTheme.textMutedOf(context),
                                  fontSize: 13)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              final player = context.read<PlayerProvider>();
                              player.playSong(history[0],
                                  queue: history, index: 0);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 20, vertical: 10),
                              decoration: BoxDecoration(
                                gradient: AurumTheme.goldGradient,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.play_arrow_rounded,
                                        color: AurumTheme.bg, size: 18),
                                    const SizedBox(width: 4),
                                    Text('Play All',
                                        style: TextStyle(
                                            color: AurumTheme.bg,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700)),
                                  ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...history.asMap().entries.map(
                          (e) => SongTile(
                              song: e.value, queue: history, index: e.key),
                        ),
                    const SizedBox(height: 100),
                  ]),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Local Files Screen ─────────────────────────────────────────────────────
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
            icon: Icon(Icons.refresh_rounded, color: AurumTheme.gold),
            onPressed: () => lib.refresh(),
          ),
        ],
      ),
      body: lib.status == LibraryStatus.loading
          ? Center(
              child: CircularProgressIndicator(color: AurumTheme.gold))
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
                      GestureDetector(
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
                      itemBuilder: (_, i) => SongTile(
                          song: lib.allSongs[i],
                          queue: lib.allSongs,
                          index: i),
                    ),
    );
  }
}

// ── Downloads Screen ───────────────────────────────────────────────────────
class _DownloadsScreen extends StatelessWidget {
  const _DownloadsScreen();

  @override
  Widget build(BuildContext context) {
    return _ComingSoonScreen(
      title: 'Downloads',
      icon: Icons.download_rounded,
      color: Colors.amber,
      message: 'Your downloaded songs will appear here.',
    );
  }
}

// ── Playlists Screen ───────────────────────────────────────────────────────
class _PlaylistsScreen extends StatelessWidget {
  const _PlaylistsScreen();

  @override
  Widget build(BuildContext context) {
    return _ComingSoonScreen(
      title: 'Playlists',
      icon: Icons.queue_music_rounded,
      color: Colors.purpleAccent,
      message: 'Create and manage your playlists here.',
    );
  }
}

// ── Albums Screen ──────────────────────────────────────────────────────────
class _AlbumsScreen extends StatelessWidget {
  const _AlbumsScreen();

  @override
  Widget build(BuildContext context) {
    return _ComingSoonScreen(
      title: 'Albums',
      icon: Icons.album_rounded,
      color: Colors.deepPurple,
      message: 'Albums you save will appear here.',
    );
  }
}

// ── Artists Screen ─────────────────────────────────────────────────────────
class _ArtistsScreen extends StatelessWidget {
  const _ArtistsScreen();

  @override
  Widget build(BuildContext context) {
    return _ComingSoonScreen(
      title: 'Artists',
      icon: Icons.person_rounded,
      color: Colors.blueAccent,
      message: 'Artists you follow will appear here.',
    );
  }
}

// ── Coming Soon Base Screen ────────────────────────────────────────────────
class _ComingSoonScreen extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final String message;

  const _ComingSoonScreen({
    required this.title,
    required this.icon,
    required this.color,
    required this.message,
  });

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
                        border: Border.all(color: color.withOpacity(0.3)),
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
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helper Widgets ─────────────────────────────────────────────────────────
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 13, fontWeight: FontWeight.w600)),
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

class _CollectionCard extends StatelessWidget {
  final _CollectionItem item;

  const _CollectionCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: item.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: item.color.withOpacity(0.2), width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: item.color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(item.icon, color: item.color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(item.label,
                      style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(item.subtitle,
                      style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
