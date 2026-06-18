import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_loader.dart';
import '../screens/full_player_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MiniPlayer v2.0 — Fautune-style Premium
// • Swipe UP  → open FullPlayerScreen (smooth slide)
// • Swipe DOWN → stop music + dismiss with fade+scale out
// • Drag tracking: real-time translate + opacity + scale
// • Spring-settle back if drag cancelled
// • Gold progress bar, glassmorphism, haptics
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;
  bool _isDragging = false;
  bool _dismissed = false;

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
    setState(() {
      _isDragging = true;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragY += details.delta.dy;
      // Allow both up and down with resistance
      _dragY = _dragY.clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDragging = false);

    // Swipe UP → open full player
    if (_dragY < _openThreshold || velocity < -_velocityThreshold) {
      HapticFeedback.mediumImpact();
      _springBack();
      _openFullPlayer();
      return;
    }

    // Swipe DOWN → dismiss + stop
    if (_dragY > _dismissThreshold || velocity > _velocityThreshold) {
      HapticFeedback.heavyImpact();
      _dismissPlayer();
      return;
    }

    // Cancelled → spring back
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
      player.pause();
      setState(() {
        _dismissed = true;
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
              .animate(
                  CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
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
        if (!player.hasSong) {
          // Reset dismissed state when new song starts
          if (_dismissed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _dismissed = false);
            });
          }
          return const SizedBox.shrink();
        }

        if (_dismissed) return const SizedBox.shrink();

        // Calculate visual transforms
        final currentY = _settleCtrl.isAnimating ? _settleAnim.value : _dragY;
        final dragFraction = (currentY.abs() / 160.0).clamp(0.0, 1.0);
        final opacity = (1.0 - dragFraction * 0.6).clamp(0.0, 1.0);
        final scale = (1.0 - dragFraction * 0.04).clamp(0.92, 1.0);

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
                child: Opacity(
                  opacity: op,
                  child: child,
                ),
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
// Content Widget
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

    // Hint: show up/down arrows while dragging
    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      height: 68,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withAlpha(isDragging ? 14 : 9)
                  : Colors.black.withAlpha(isDragging ? 12 : 7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDragging
                    ? AurumTheme.gold.withAlpha(60)
                    : AurumTheme.gold.withAlpha(isDark ? 35 : 50),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(isDark ? 100 : 30),
                  blurRadius: isDragging ? 28 : 20,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: AurumTheme.gold.withAlpha(isDragging ? 20 : 10),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Stack(
              children: [
                // Main row
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Progress bar at top
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20)),
                      child: LinearProgressIndicator(
                        value: player.progress,
                        backgroundColor: Colors.transparent,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(AurumTheme.gold),
                        minHeight: 2,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            // Artwork
                            Hero(
                              tag: 'aurum_artwork',
                              flightShuttleBuilder:
                                  (ctx, anim, dir, from, to) =>
                                      ScaleTransition(
                                          scale: anim, child: to.widget),
                              child: AurumArtwork(
                                url: song.artworkUrl,
                                size: 44,
                                borderRadius: 10,
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
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  player.skipPrev();
                                },
                                size: 22,
                                context: context),
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
                                context: context),
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
                              ? Colors.red.withAlpha(30)
                              : Colors.white.withAlpha(10),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Center(
                          child: Icon(
                            showDownHint
                                ? Icons.stop_circle_outlined
                                : Icons.keyboard_arrow_up_rounded,
                            color: showDownHint
                                ? Colors.red.withAlpha(180)
                                : Colors.white.withAlpha(150),
                            size: 28,
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
// Play Button
// ─────────────────────────────────────────────────────────────────────────────
class _PlayBtn extends StatelessWidget {
  final PlayerProvider player;
  const _PlayBtn({required this.player});

  @override
  Widget build(BuildContext context) {
    if (player.isLoading) {
      return const SizedBox(
          width: 36,
          height: 36,
          child: Center(child: AurumLoader(size: 26)));
    }
    return GestureDetector(
      onTap: () {
        HapticFeedback.heavyImpact();
        player.togglePlay();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AurumTheme.gold.withAlpha(100),
              blurRadius: player.isPlaying ? 14 : 8,
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
            size: 20,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control Button
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
