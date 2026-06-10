import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_loader.dart';
import '../screens/main_shell.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.hasSong) return const SizedBox.shrink();

        return GestureDetector(
          onTap: () => FullPlayerRoute.open(context),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) {
              FullPlayerRoute.open(context);
            }
          },
          child: _MiniPlayerBody(player: player),
        );
      },
    );
  }
}

class _MiniPlayerBody extends StatelessWidget {
  final PlayerProvider player;
  const _MiniPlayerBody({required this.player});

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final progress = player.progress;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 72,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.07)
                  : Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? AurumTheme.gold.withOpacity(0.22)
                    : AurumTheme.gold.withOpacity(0.30),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black
                      .withOpacity(isDark ? 0.45 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Stack(
              children: [
                // Progress bar at top
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20)),
                    child: SizedBox(
                      height: 2,
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation(
                            AurumTheme.gold),
                      ),
                    ),
                  ),
                ),
                // Main row
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(10, 2, 10, 0),
                  child: Row(
                    children: [
                      // Artwork with playing indicator
                      _ArtworkWithIndicator(
                        url: song.artworkUrl,
                        isPlaying: player.isPlaying,
                      ),
                      const SizedBox(width: 12),
                      // Song info
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Text(
                              song.title,
                              style: TextStyle(
                                color: AurumTheme
                                    .textPrimaryOf(context),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song.artist,
                              style: TextStyle(
                                color: AurumTheme
                                    .textSecondaryOf(context),
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Controls
                      _MiniControl(
                        icon: Icons.skip_previous_rounded,
                        onTap: player.skipPrev,
                        size: 20,
                      ),
                      const SizedBox(width: 2),
                      _MiniPlayButton(player: player),
                      const SizedBox(width: 2),
                      _MiniControl(
                        icon: Icons.skip_next_rounded,
                        onTap: player.skipNext,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtworkWithIndicator extends StatelessWidget {
  final String url;
  final bool isPlaying;

  const _ArtworkWithIndicator({
    required this.url,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: isPlaying
            ? [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                )
              ]
            : [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            AurumArtwork(url: url, size: 46, borderRadius: 12),
            if (isPlaying)
              Container(
                color: Colors.black.withOpacity(0.3),
                child: Center(
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    color: AurumTheme.gold,
                    size: 18,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniPlayButton extends StatelessWidget {
  final PlayerProvider player;
  const _MiniPlayButton({required this.player});

  @override
  Widget build(BuildContext context) {
    if (player.isLoading) {
      return const SizedBox(
        width: 38,
        height: 38,
        child: Center(child: AurumLoader(size: 24)),
      );
    }
    return GestureDetector(
      onTap: player.togglePlay,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AurumTheme.gold.withOpacity(0.35),
              blurRadius: 10,
              offset: const Offset(0, 3),
            )
          ],
        ),
        child: Icon(
          player.isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          color: Colors.black,
          size: 20,
        ),
      ),
    );
  }
}

class _MiniControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _MiniControl({
    required this.icon,
    required this.onTap,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 34,
        height: 34,
        child: Icon(
          icon,
          color: AurumTheme.textSecondaryOf(context),
          size: size,
        ),
      ),
    );
  }
}
