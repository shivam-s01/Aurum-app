import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_loader.dart';
import '../screens/full_player_screen.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.hasSong) return const SizedBox.shrink();

        return AnimatedSlide(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          offset: Offset.zero,
          child: _MiniPlayerContent(player: player),
        );
      },
    );
  }
}

class _MiniPlayerContent extends StatelessWidget {
  final PlayerProvider player;
  const _MiniPlayerContent({required this.player});

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => const FullPlayerScreen(),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        height: 68,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.07)
                    : Colors.black.withOpacity(0.05),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? AurumTheme.gold.withOpacity(0.25)
                      : AurumTheme.gold.withOpacity(0.35),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(isDark ? 0.4 : 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.06),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Progress bar at top
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(18),
                    ),
                    child: LinearProgressIndicator(
                      value: player.progress,
                      backgroundColor: Colors.transparent,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AurumTheme.gold,
                      ),
                      minHeight: 2,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          // Artwork
                          AurumArtwork(
                            url: song.artworkUrl,
                            size: 44,
                            borderRadius: 10,
                          ),
                          const SizedBox(width: 12),
                          // Song info
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  song.title,
                                  style: TextStyle(
                                    color: AurumTheme.textPrimaryOf(context),
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
                                    color: AurumTheme.textSecondaryOf(context),
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
                          _ControlBtn(
                            icon: Icons.skip_previous_rounded,
                            onTap: player.skipPrev,
                            size: 22,
                            context: context,
                          ),
                          const SizedBox(width: 4),
                          _PlayBtn(player: player),
                          const SizedBox(width: 4),
                          _ControlBtn(
                            icon: Icons.skip_next_rounded,
                            onTap: player.skipNext,
                            size: 22,
                            context: context,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayBtn extends StatelessWidget {
  final PlayerProvider player;
  const _PlayBtn({required this.player});

  @override
  Widget build(BuildContext context) {
    if (player.isLoading) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(child: AurumLoader(size: 26)),
      );
    }
    return GestureDetector(
      onTap: player.togglePlay,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AurumTheme.gold.withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: AurumTheme.bg,
          size: 20,
        ),
      ),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final BuildContext context;

  const _ControlBtn({
    required this.icon,
    required this.onTap,
    required this.context,
    this.size = 24,
  });

  @override
  Widget build(BuildContext ctx) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          icon,
          color: AurumTheme.textSecondaryOf(context),
          size: size,
        ),
      ),
    );
  }
}
