import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';

class LikedScreen extends StatelessWidget {
  const LikedScreen({super.key});

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
              icon: Icon(Icons.arrow_back_ios_rounded, color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: Row(
                children: [
                  const Icon(Icons.favorite_rounded, color: Color(0xFFE1306C), size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
                    child: const Text('Liked Songs', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          Consumer<FavoritesProvider>(
            builder: (context, fav, _) {
              if (fav.isLoading) {
                return SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator(color: AurumTheme.gold)),
                );
              }

              if (fav.favorites.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 80, height: 80,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE1306C).withOpacity(0.1),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.favorite_border_rounded, color: Color(0xFFE1306C), size: 36),
                        ),
                        const SizedBox(height: 20),
                        Text('No liked songs yet', style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text('Tap ♥ on any song to save it here', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
                      ],
                    ),
                  ),
                );
              }

              final songs = fav.favorites;
              return SliverList(
                delegate: SliverChildListDelegate([
                  // Play all button
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Text('${songs.length} songs', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            final player = context.read<PlayerProvider>();
                            player.playSong(songs[0], queue: songs, index: 0);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: AurumTheme.goldGradient,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.play_arrow_rounded, color: AurumTheme.bg, size: 18),
                              const SizedBox(width: 4),
                              Text('Play All', style: TextStyle(color: AurumTheme.bg, fontSize: 13, fontWeight: FontWeight.w700)),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...songs.asMap().entries.map((e) => SongTile(song: e.value, queue: songs, index: e.key)),
                  const SizedBox(height: 100),
                ]),
              );
            },
          ),
        ],
      ),
    );
  }
}
