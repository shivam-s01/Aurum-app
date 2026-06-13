import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/favorites_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/song_tile.dart';
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
          icon: Icon(Icons.settings_outlined, color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(20, 0, 0, 16),
        title: Text('Library', style: TextStyle(color: AurumTheme.gold, fontSize: 28, fontWeight: FontWeight.w800)),
      ),
    );
  }

  Widget _buildQuickAccess(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _QuickChip(icon: Icons.favorite_rounded, label: 'Liked', color: Colors.pinkAccent,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LikedScreen()))),
          const SizedBox(width: 10),
          _QuickChip(icon: Icons.download_rounded, label: 'Downloads', color: Colors.amber),
          const SizedBox(width: 10),
          _QuickChip(icon: Icons.history_rounded, label: 'History', color: Colors.teal),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Text(title, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
    );
  }

  Widget _buildCollectionGrid(BuildContext context) {
    final favCount = context.watch<FavoritesProvider>().favorites.length;
    final lib = context.watch<LibraryProvider>();

    final items = [
      _CollectionItem(icon: Icons.favorite_rounded, label: 'Liked Songs', subtitle: '$favCount songs', color: Colors.pinkAccent,
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LikedScreen()))),
      _CollectionItem(icon: Icons.queue_music_rounded, label: 'Playlists', subtitle: 'Your playlists', color: Colors.purpleAccent),
      _CollectionItem(icon: Icons.album_rounded, label: 'Albums', subtitle: 'Saved albums', color: Colors.deepPurple),
      _CollectionItem(icon: Icons.person_rounded, label: 'Artists', subtitle: 'Following', color: Colors.blueAccent),
      _CollectionItem(
        icon: Icons.folder_rounded,
        label: 'Local Files',
        subtitle: lib.hasLoaded ? '${lib.allSongs.length} songs' : 'On this device',
        color: Colors.green,
        onTap: () async {
          if (!lib.hasLoaded) await lib.load();
          if (context.mounted) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => const _LocalFilesScreen(),
            ));
          }
        },
      ),
      _CollectionItem(icon: Icons.history_rounded, label: 'Recently Played', subtitle: 'Listen history', color: Colors.orange),
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
              Icon(Icons.music_note_rounded, size: 40, color: AurumTheme.textMutedOf(context).withOpacity(0.3)),
              const SizedBox(height: 8),
              Text('Play something to see history', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (int i = 0; i < history.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: SongTile(song: history[i], queue: history, index: i),
          ),
      ],
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
        title: Text('Local Files', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontWeight: FontWeight.w700)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, color: AurumTheme.textPrimaryOf(context)),
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
          ? Center(child: CircularProgressIndicator(color: AurumTheme.gold))
          : lib.status == LibraryStatus.noPermission
              ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.lock_rounded, size: 48, color: AurumTheme.textMutedOf(context)),
                  const SizedBox(height: 12),
                  Text('Permission required', style: TextStyle(color: AurumTheme.textMutedOf(context))),
                  const SizedBox(height: 16),
                  ElevatedButton(onPressed: () => lib.load(), child: const Text('Grant Permission')),
                ]))
              : lib.allSongs.isEmpty
                  ? Center(child: Text('No local songs found', style: TextStyle(color: AurumTheme.textMutedOf(context))))
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      itemCount: lib.allSongs.length,
                      itemBuilder: (_, i) => SongTile(song: lib.allSongs[i], queue: lib.allSongs, index: i),
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
  const _QuickChip({required this.icon, required this.label, required this.color, this.onTap});

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
          Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
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
  const _CollectionItem({required this.icon, required this.label, required this.subtitle, required this.color, this.onTap});
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
          border: Border.all(color: item.color.withOpacity(0.2), width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: item.color.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(item.icon, color: item.color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(item.label, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(item.subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
          ]),
        ),
      ),
    );
  }
}
