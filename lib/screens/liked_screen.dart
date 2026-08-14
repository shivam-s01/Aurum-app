import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/mini_player_slot.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

class LikedScreen extends StatelessWidget {
  const LikedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER: this screen is pushed via
      // Navigator.push from Library, so it builds its own Scaffold on top
      // of MainShell's — MainShell's own mini player (in its
      // bottomNavigationBar) is no longer part of the visible layout once
      // this screen is on top. MiniPlayerSlot reproduces the exact same
      // visibility/transparency behavior here, so playback controls never
      // disappear just because the user browsed into Liked Songs — same
      // as Spotify/YT Music, where the mini player follows you into every
      // browsing screen and only hides behind the full Now Playing view.
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
              icon: Icon(Icons.arrow_back_ios_rounded, color: AurumTheme.textSecondaryOf(context), size: 20),
              onPressed: () { AurumHaptics.light(); Navigator.pop(context); },
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: Row(
                children: [
                  const Icon(Icons.favorite_rounded, color: Color(0xFFE1306C), size: 22),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
                    child: Text(l10n.libraryLikedSongs, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
          Consumer<FavoritesProvider>(
            builder: (context, fav, _) {
              if (fav.isLoading) {
                return SliverFillRemaining(
                  child: Center(child: AurumMorphLoader(size: 56)),
                );
              }

              if (fav.favorites.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: AurumEmptyState(
                      icon: Icons.favorite_border_rounded,
                      title: l10n.likedNoSongsYet,
                      subtitle: l10n.likedTapToSave,
                    ),
                  ),
                );
              }

              final songs = fav.favorites;
              // PERF FIX (nav-in jank on Liked Songs — "jatka" on open):
              // this used to build every SongTile eagerly via
              // SliverChildListDelegate + songs.map(...).toList() — the
              // ENTIRE liked list was constructed, laid out, and painted
              // on the very first frame after the push transition
              // started, competing directly with the 350ms page-slide
              // animation for frame budget. On a sizeable liked list that
              // showed up as a visible stutter right as the screen
              // entered, unlike every other library sub-screen (History,
              // Downloads, Albums, Artists), which already used a lazy
              // SliverChildBuilderDelegate. Switched to the same lazy
              // pattern: only the tiles actually on/near screen build on
              // that first frame, the rest build cheaply as the user
              // scrolls — matching Spotify/YT Music's own lazy list
              // behavior and giving this screen the same light, instant
              // open feel as its siblings.
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: [
                            Text(l10n.librarySongsCount(songs.length), style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                AurumHaptics.medium();
                                final player = context.read<PlayerProvider>();
                                player.playSong(songs[0], queue: songs, index: 0, curatedQueue: true);
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
                                  Text(l10n.commonPlayAll, style: TextStyle(color: AurumTheme.bg, fontSize: 13, fontWeight: FontWeight.w700)),
                                ]),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    if (index == songs.length + 1) {
                      return const SizedBox(height: 100);
                    }
                    final songIndex = index - 1;
                    return SongTile(
                      song: songs[songIndex],
                      queue: songs,
                      index: songIndex,
                      curatedQueue: true,
                    );
                  },
                  childCount: songs.length + 2,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
