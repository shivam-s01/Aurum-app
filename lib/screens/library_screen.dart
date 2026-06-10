import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/player_provider.dart';
import '../widgets/aurum_artwork.dart';
import 'settings_screen.dart';

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
        const SizedBox(width: 4),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: ShaderMask(
          shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
          child: const Text('Library', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.5)),
        ),
      ),
    );
  }

  Widget _buildQuickAccess(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _QuickChip(icon: Icons.favorite_rounded, label: 'Liked', color: const Color(0xFFE1306C), onTap: () {}),
          const SizedBox(width: 10),
          _QuickChip(icon: Icons.download_rounded, label: 'Downloads', color: AurumTheme.gold, onTap: () {}),
          const SizedBox(width: 10),
          _QuickChip(icon: Icons.history_rounded, label: 'History', color: const Color(0xFF4CAF50), onTap: () {}),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Text(title, style: const TextStyle(color: AurumTheme.gold, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
    );
  }

  Widget _buildCollectionGrid(BuildContext context) {
    final items = [
      _CollectionItem(icon: Icons.favorite_rounded, title: 'Liked Songs', subtitle: 'Your favorites', color: const Color(0xFFE1306C)),
      _CollectionItem(icon: Icons.queue_music_rounded, title: 'Playlists', subtitle: 'Your playlists', color: AurumTheme.gold),
      _CollectionItem(icon: Icons.album_rounded, title: 'Albums', subtitle: 'Saved albums', color: const Color(0xFF9C27B0)),
      _CollectionItem(icon: Icons.person_rounded, title: 'Artists', subtitle: 'Following', color: const Color(0xFF2196F3)),
      _CollectionItem(icon: Icons.folder_rounded, title: 'Local Files', subtitle: 'On this device', color: const Color(0xFF4CAF50)),
      _CollectionItem(icon: Icons.history_rounded, title: 'Recently Played', subtitle: 'Listen history', color: const Color(0xFFFF9800)),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.6,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _CollectionCard(item: items[i]),
      ),
    );
  }

  Widget _buildRecentlyPlayed(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.hasSong) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Column(children: [
                Icon(Icons.music_note_rounded, color: AurumTheme.gold.withOpacity(0.2), size: 48),
                const SizedBox(height: 12),
                Text('Play something to see history', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
              ]),
            ),
          );
        }
        final queue = player.queue;
        return SizedBox(
          height: 155,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final song = queue[i];
              final isCurrent = i == player.currentIndex;
              return GestureDetector(
                onTap: () => player.skipToIndex(i),
                child: Container(
                  width: 110,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(children: [
                        AurumArtwork(url: song.artworkUrl, size: 110, borderRadius: 12),
                        if (isCurrent)
                          Container(
                            width: 110, height: 110,
                            decoration: BoxDecoration(color: Colors.black.withOpacity(0.4), borderRadius: BorderRadius.circular(12)),
                            child: const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 28),
                          ),
                      ]),
                      const SizedBox(height: 6),
                      Text(song.title, style: TextStyle(color: isCurrent ? AurumTheme.gold : AurumTheme.textPrimaryOf(context), fontSize: 11, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(song.artist, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _QuickChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickChip({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.25), width: 0.8),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}

class _CollectionItem {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  const _CollectionItem({required this.icon, required this.title, required this.subtitle, required this.color});
}

class _CollectionCard extends StatelessWidget {
  final _CollectionItem item;
  const _CollectionCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
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
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(item.title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 13, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(item.subtitle, style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            )),
          ]),
        ),
      ),
    );
  }
}
