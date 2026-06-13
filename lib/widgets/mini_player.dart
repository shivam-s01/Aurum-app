import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_loader.dart';
import '../screens/full_player_screen.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;
  bool _isDragging = false;
  // FIX: track dismissed song id — resets automatically when new song plays
  String? _dismissedSongId;

  late final AnimationController _settleCtrl;
  late Animation<double> _settleAnim;

  static const double _dismissThreshold = 80.0;
  static const double _openThreshold = -60.0;
  static const double _velocityThreshold = 400.0;

  @override
  void initState() {
    super.initState();
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _settleAnim = AlwaysStoppedAnimation(0.0);
  }

  @override
  void dispose() {
    _settleCtrl.dispose();
    super.dispose();
  }

  void _onDragStart(DragStartDetails _) {
    _settleCtrl.stop();
    setState(() => _isDragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragY += details.delta.dy;
      _dragY = _dragY.clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDragging = false);

    if (_dragY < _openThreshold || velocity < -_velocityThreshold) {
      HapticFeedback.mediumImpact();
      _springBack();
      _openFullPlayer();
      return;
    }

    if (_dragY > _dismissThreshold || velocity > _velocityThreshold) {
      HapticFeedback.heavyImpact();
      _dismissPlayer();
      return;
    }

    _springBack();
  }

  void _springBack() {
    final from = _dragY;
    _settleAnim = Tween<double>(begin: from, end: 0.0).animate(
      CurvedAnimation(parent: _settleCtrl, curve: Curves.easeOutCubic),
    );
    _settleCtrl.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _dragY = 0);
      _settleCtrl.reset();
    });
  }

  void _dismissPlayer() {
    final from = _dragY;
    _settleAnim = Tween<double>(begin: from, end: 200.0).animate(
      CurvedAnimation(parent: _settleCtrl, curve: Curves.easeInCubic),
    );
    _settleCtrl.forward(from: 0.0).then((_) {
      if (!mounted) return;
      final player = context.read<PlayerProvider>();
      // FIX: store dismissed song id instead of bool flag
      final songId = player.currentSong?.id;
      player.pause();
      setState(() {
        _dismissedSongId = songId;
        _dragY = 0;
      });
      _settleCtrl.reset();
    });
  }

  void _openFullPlayer() {
    setState(() => _dragY = 0);
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 380),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.hasSong) return const SizedBox.shrink();

        // FIX: if new/different song plays, auto-reset dismissed state instantly
        if (_dismissedSongId != null &&
            player.currentSong?.id != _dismissedSongId) {
          _dismissedSongId = null;
        }

        if (_dismissedSongId != null) return const SizedBox.shrink();

        return AnimatedBuilder(
          animation: _settleCtrl,
          builder: (_, child) {
            final y = _settleCtrl.isAnimating ? _settleAnim.value : _dragY;
            final frac = (y.abs() / 160.0).clamp(0.0, 1.0);
            final op = (1.0 - frac * 0.6).clamp(0.0, 1.0);
            final sc = (1.0 - frac * 0.04).clamp(0.92, 1.0);

            return Transform.translate(
              offset: Offset(0, y.clamp(-60.0, 200.0)),
              child: Transform.scale(
                scale: sc,
                child: Opacity(opacity: op, child: child),
              ),
            );
          },
          child: GestureDetector(
            onTap: _openFullPlayer,
            onVerticalDragStart: _onDragStart,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: _MiniPlayerContent(
              player: player,
              isDragging: _isDragging,
              dragY: _dragY,
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _MiniPlayerContent extends StatelessWidget {
  final PlayerProvider player;
  final bool isDragging;
  final double dragY;

  const _MiniPlayerContent({
    required this.player,
    required this.isDragging,
    required this.dragY,
  });

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      height: 70,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              // Premium: richer gradient overlay
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        Colors.white.withAlpha(isDragging ? 18 : 12),
                        Colors.white.withAlpha(isDragging ? 8 : 5),
                      ]
                    : [
                        Colors.black.withAlpha(isDragging ? 15 : 9),
                        Colors.black.withAlpha(isDragging ? 8 : 4),
                      ],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isDragging
                    ? AurumTheme.gold.withAlpha(80)
                    : AurumTheme.gold.withAlpha(isDark ? 45 : 60),
                width: 0.9,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 120 : 40),
                  blurRadius: isDragging ? 32 : 24,
                  offset: const Offset(0, 6),
                ),
                // Gold glow — premium touch
                BoxShadow(
                  color: AurumTheme.gold.withAlpha(isDragging ? 30 : 18),
                  blurRadius: 16,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Thicker gold progress bar
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(22)),
                      child: LinearProgressIndicator(
                        value: player.progress,
                        backgroundColor: AurumTheme.gold.withAlpha(25),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            AurumTheme.gold),
                        minHeight: 2.5,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            // Artwork with subtle glow
                            Hero(
                              tag: 'aurum_artwork',
                              flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                                  ScaleTransition(scale: anim, child: to.widget),
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(11),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AurumTheme.gold.withAlpha(40),
                                      blurRadius: 10,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: AurumArtwork(
                                  url: song.artworkUrl,
                                  size: 46,
                                  borderRadius: 11,
                                ),
                              ),
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
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.1,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    song.artist,
                                    style: TextStyle(
                                      color: AurumTheme.textSecondaryOf(context),
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w400,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Controls
                            _ControlBtn(
                              icon: Icons.skip_previous_rounded,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                player.skipPrev();
                              },
                              size: 23,
                              context: context,
                            ),
                            const SizedBox(width: 2),
                            _PlayBtn(player: player),
                            const SizedBox(width: 2),
                            _ControlBtn(
                              icon: Icons.skip_next_rounded,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                player.skipNext();
                              },
                              size: 23,
                              context: context,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                // Drag hint overlay
                if (showUpHint || showDownHint)
                  Positioned.fill(
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: (dragY.abs() / 60.0).clamp(0.0, 0.85),
                      child: Container(
                        decoration: BoxDecoration(
                          color: showDownHint
                              ? Colors.red.withAlpha(35)
                              : AurumTheme.gold.withAlpha(15),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: Center(
                          child: Icon(
                            showDownHint
                                ? Icons.stop_circle_outlined
                                : Icons.keyboard_arrow_up_rounded,
                            color: showDownHint
                                ? Colors.red.withAlpha(200)
                                : AurumTheme.gold.withAlpha(200),
                            size: 30,
                          ),
                        ),
                      ),
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

// ─────────────────────────────────────────────────────────────────────────────
class _PlayBtn extends StatelessWidget {
  final PlayerProvider player;
  const _PlayBtn({required this.player});

  @override
  Widget build(BuildContext context) {
    if (player.isLoading) {
      return const SizedBox(
        width: 38,
        height: 38,
        child: Center(child: AurumLoader(size: 26)),
      );
    }
    return GestureDetector(
      onTap: () {
        HapticFeedback.heavyImpact();
        player.togglePlay();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AurumTheme.gold.withAlpha(player.isPlaying ? 130 : 70),
              blurRadius: player.isPlaying ? 16 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey(player.isPlaying),
            color: AurumTheme.bg,
            size: 21,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
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
