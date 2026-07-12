import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_pressable.dart';
import '../screens/full_player_screen.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  double _dragY = 0;
  bool _dragging = false;

  static const double _dismissThreshold = 64.0;
  static const double _openThreshold = -60.0;

  void _onDragUpdate(DragUpdateDetails d) {
    setState(() {
      _dragging = true;
      _dragY = (_dragY + d.delta.dy).clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final y = _dragY;
    setState(() {
      _dragging = false;
      _dragY = 0;
    });

    if (y < _openThreshold || velocity < -400) {
      _openFullPlayer();
      return;
    }
    if (y > _dismissThreshold || velocity > 400) {
      HapticFeedback.mediumImpact();
      final player = context.read<PlayerProvider>();
      player.pause();
      player.dismissMiniPlayer();
    }
  }

  bool _opening = false;
  void _openFullPlayer() {
    if (_opening) return;
    _opening = true;
    HapticFeedback.lightImpact();
    Navigator.of(context)
        .push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      ),
    )
        .then((_) => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.miniPlayerVisible || player.currentSong == null) {
          return const SizedBox.shrink();
        }

        final song = player.currentSong!;
        final frac = (_dragY.abs() / 160.0).clamp(0.0, 1.0);
        final opacity = _dragging ? (1.0 - frac * 0.6).clamp(0.0, 1.0) : 1.0;
        final translateY = _dragging ? _dragY.clamp(-60.0, 200.0) : 0.0;

        return GestureDetector(
          onTap: _openFullPlayer,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Opacity(
              opacity: opacity,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      height: 68,
                      decoration: BoxDecoration(
                        color: (Theme.of(context).brightness == Brightness.dark
                                ? Colors.black
                                : Colors.white)
                            .withValues(
                          alpha: Theme.of(context).brightness == Brightness.dark
                              ? 0.42
                              : 0.62,
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: (Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.black)
                              .withValues(alpha: 0.08),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          _MiniProgressBar(player: player),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Row(
                                children: [
                                  AurumArtwork(
                                    url: song.artworkUrl,
                                    size: 44,
                                    borderRadius: 10,
                                  ),
                                  const SizedBox(width: 12),
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
                                  _ControlBtn(
                                    icon: Icons.skip_previous_rounded,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      player.skipPrev();
                                    },
                                    size: 22,
                                  ),
                                  const SizedBox(width: 4),
                                  _PlayBtn(player: player),
                                  const SizedBox(width: 4),
                                  _ControlBtn(
                                    icon: Icons.skip_next_rounded,
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      player.skipNext();
                                    },
                                    size: 22,
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
            ),
          ),
        );
      },
    );
  }
}

class _MiniProgressBar extends StatelessWidget {
  final PlayerProvider player;
  const _MiniProgressBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, double>(
      selector: (_, p) => p.progress,
      builder: (context, progress, _) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: RepaintBoundary(
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.transparent,
            valueColor: const AlwaysStoppedAnimation<Color>(AurumTheme.gold),
            minHeight: 2,
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
    final accent = context.watch<ThemeProvider>().accentColor;
    if (player.isLoading) {
      return Opacity(
        opacity: 0.35,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.play_arrow_rounded, color: accent, size: 26),
        ),
      );
    }
    return AurumPressable(
      scaleAmount: 0.88,
      haptic: false,
      onTap: () {
        HapticFeedback.heavyImpact();
        player.togglePlay();
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
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

  const _ControlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.82,
      haptic: false,
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
