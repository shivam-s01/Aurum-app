import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_loader.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  // Slide-up entrance
  late AnimationController _enterCtrl;
  late Animation<Offset> _slideAnim;

  // Disc rotation
  late AnimationController _discCtrl;

  // Drag-to-close
  double _dragOffset = 0;

  // Tab: 0 = player, 1 = queue, 2 = lyrics (ready)
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();

    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(
                parent: _enterCtrl, curve: Curves.easeOutCubic));
    _enterCtrl.forward();

    _discCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    // Pause disc when paused
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final player = context.read<PlayerProvider>();
      if (!player.isPlaying) _discCtrl.stop();
      player.addListener(_syncDisc);
    });
  }

  void _syncDisc() {
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    if (player.isPlaying && !_discCtrl.isAnimating) {
      _discCtrl.repeat();
    } else if (!player.isPlaying && _discCtrl.isAnimating) {
      _discCtrl.stop();
    }
  }

  @override
  void dispose() {
    final player = context.read<PlayerProvider>();
    player.removeListener(_syncDisc);
    _enterCtrl.dispose();
    _discCtrl.dispose();
    super.dispose();
  }

  void _close() {
    _enterCtrl.reverse().then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (d.delta.dy > 0) {
      setState(() => _dragOffset += d.delta.dy);
    }
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dragOffset > 90 || (d.primaryVelocity ?? 0) > 600) {
      _close();
    } else {
      setState(() => _dragOffset = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: GestureDetector(
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: SlideTransition(
              position: _slideAnim,
              child: Transform.translate(
                offset: Offset(0, _dragOffset * 0.3),
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Dynamic blurred background
                      _PlayerBackground(
                          artworkUrl: song.artworkUrl),
                      // Main content
                      SafeArea(
                        bottom: false,
                        child: Column(
                          children: [
                            _buildHandle(),
                            _buildTopBar(context, player, song),
                            const SizedBox(height: 4),
                            _buildTabSelector(context),
                            Expanded(
                              child: _activeTab == 0
                                  ? _PlayerContent(
                                      player: player,
                                      song: song,
                                      discCtrl: _discCtrl,
                                    )
                                  : _activeTab == 1
                                      ? _QueueView(player: player)
                                      : _LyricsPlaceholder(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHandle() {
    return GestureDetector(
      onTap: _close,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(
      BuildContext context, PlayerProvider player, song) {
    final lib = context.read<LibraryProvider>();
    final isFav = lib.isFavorite(song.id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _GlassButton(
            icon: Icons.keyboard_arrow_down_rounded,
            size: 26,
            onTap: _close,
          ),
          const Expanded(
            child: Text(
              'NOW PLAYING',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 2,
              ),
            ),
          ),
          _GlassButton(
            icon: isFav
                ? Icons.favorite_rounded
                : Icons.favorite_outline_rounded,
            size: 22,
            color: isFav ? Colors.redAccent : null,
            onTap: () => lib.toggleFavorite(song),
          ),
        ],
      ),
    );
  }

  Widget _buildTabSelector(BuildContext context) {
    const tabs = ['Player', 'Queue', 'Lyrics'];
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: 20, vertical: 12),
      child: Container(
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: tabs.asMap().entries.map((e) {
            final isActive = _activeTab == e.key;
            return Expanded(
              child: GestureDetector(
                onTap: () =>
                    setState(() => _activeTab = e.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AurumTheme.gold.withOpacity(0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                    border: isActive
                        ? Border.all(
                            color: AurumTheme.gold
                                .withOpacity(0.5),
                            width: 0.8)
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      e.value,
                      style: TextStyle(
                        color: isActive
                            ? AurumTheme.gold
                            : Colors.white38,
                        fontSize: 12,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ── Player Content (disc + controls) ─────────────────────────────────────────

class _PlayerContent extends StatelessWidget {
  final PlayerProvider player;
  final dynamic song;
  final AnimationController discCtrl;

  const _PlayerContent({
    required this.player,
    required this.song,
    required this.discCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _RotatingDisc(
              artworkUrl: song.artworkUrl,
              controller: discCtrl,
              isPlaying: player.isPlaying),
          const SizedBox(height: 28),
          _SongInfoRow(player: player, song: song),
          const SizedBox(height: 20),
          _ProgressSection(player: player),
          const SizedBox(height: 24),
          _ControlsRow(player: player),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Rotating Disc ─────────────────────────────────────────────────────────────

class _RotatingDisc extends StatelessWidget {
  final String artworkUrl;
  final AnimationController controller;
  final bool isPlaying;

  const _RotatingDisc({
    required this.artworkUrl,
    required this.controller,
    required this.isPlaying,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.68;

    return AnimatedScale(
      scale: isPlaying ? 1.0 : 0.88,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      child: SizedBox(
        width: size,
        height: size,
        child: RotationTransition(
          turns: controller,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Outer vinyl ring
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF1A1A1A),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.7),
                      blurRadius: 50,
                      offset: const Offset(0, 20),
                    ),
                    BoxShadow(
                      color:
                          AurumTheme.gold.withOpacity(0.15),
                      blurRadius: 40,
                      spreadRadius: -5,
                    ),
                  ],
                ),
              ),
              // Vinyl grooves (decorative rings)
              _VinylGrooves(size: size),
              // Artwork circle
              Center(
                child: SizedBox(
                  width: size * 0.62,
                  height: size * 0.62,
                  child: ClipOval(
                    child: AurumArtwork(
                      url: artworkUrl,
                      size: size * 0.62,
                      borderRadius: size * 0.31,
                    ),
                  ),
                ),
              ),
              // Center hole
              Center(
                child: Container(
                  width: size * 0.1,
                  height: size * 0.1,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0A0A0A),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VinylGrooves extends StatelessWidget {
  final double size;
  const _VinylGrooves({required this.size});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GroovesPainter(),
      size: Size(size, size),
    );
  }
}

class _GroovesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.04)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final radii = [0.48, 0.44, 0.40, 0.36];
    for (final r in radii) {
      canvas.drawCircle(center, size.width * r, paint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── Song Info Row ─────────────────────────────────────────────────────────────

class _SongInfoRow extends StatelessWidget {
  final PlayerProvider player;
  final dynamic song;

  const _SongInfoRow(
      {required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          GestureDetector(
            onTap: player.toggleShuffle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: player.shuffle
                    ? AurumTheme.gold.withOpacity(0.2)
                    : Colors.white.withOpacity(0.07),
                shape: BoxShape.circle,
                border: Border.all(
                  color: player.shuffle
                      ? AurumTheme.gold.withOpacity(0.5)
                      : Colors.transparent,
                ),
              ),
              child: Icon(
                Icons.shuffle_rounded,
                color: player.shuffle
                    ? AurumTheme.gold
                    : Colors.white30,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Progress Section ──────────────────────────────────────────────────────────

class _ProgressSection extends StatelessWidget {
  final PlayerProvider player;
  const _ProgressSection({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          // Buffered progress behind seek bar
          Stack(
            children: [
              // Buffered track
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 0),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 0),
                  activeTrackColor:
                      Colors.white.withOpacity(0.2),
                  inactiveTrackColor:
                      Colors.white.withOpacity(0.08),
                ),
                child: Slider(
                    value: player.bufferedProgress,
                    onChanged: null),
              ),
              // Seek slider
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor:
                      Colors.white.withOpacity(0.15),
                ),
                child: Slider(
                    value: player.progress,
                    onChanged: player.seek),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  player.positionString,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11),
                ),
                Text(
                  player.durationString,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Controls Row ──────────────────────────────────────────────────────────────

class _ControlsRow extends StatelessWidget {
  final PlayerProvider player;
  const _ControlsRow({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Loop
          GestureDetector(
            onTap: player.toggleLoop,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: player.loopMode != LoopMode.off
                    ? AurumTheme.gold.withOpacity(0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                player.loopMode == LoopMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                color: player.loopMode != LoopMode.off
                    ? AurumTheme.gold
                    : Colors.white30,
                size: 22,
              ),
            ),
          ),
          // Previous
          GestureDetector(
            onTap: player.skipPrev,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color:
                    Colors.white.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.skip_previous_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
          // Play / Pause
          GestureDetector(
            onTap: player.togglePlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: AurumTheme.goldGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color:
                        AurumTheme.gold.withOpacity(0.5),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: player.isLoading
                  ? const Center(
                      child: AurumLoader(size: 28, color: Colors.black))
                  : Icon(
                      player.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.black,
                      size: 38,
                    ),
            ),
          ),
          // Next
          GestureDetector(
            onTap: player.skipNext,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color:
                    Colors.white.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.skip_next_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
          // Equalizer / More
          _GlassButton(
            icon: Icons.equalizer_rounded,
            size: 22,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

// ── Queue View ────────────────────────────────────────────────────────────────

class _QueueView extends StatelessWidget {
  final PlayerProvider player;
  const _QueueView({required this.player});

  @override
  Widget build(BuildContext context) {
    final queue = player.queue;
    if (queue.isEmpty) {
      return Center(
        child: Text('Queue is empty',
            style: TextStyle(
                color: Colors.white38, fontSize: 14)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      physics: const BouncingScrollPhysics(),
      itemCount: queue.length,
      itemBuilder: (context, i) {
        final song = queue[i];
        final isCurrent = i == player.currentIndex;
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
          leading: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: isCurrent
                  ? Border.all(
                      color:
                          AurumTheme.gold.withOpacity(0.6),
                      width: 1.5)
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AurumArtwork(
                  url: song.artworkUrl,
                  size: 44,
                  borderRadius: 10),
            ),
          ),
          title: Text(
            song.title,
            style: TextStyle(
              color:
                  isCurrent ? AurumTheme.gold : Colors.white,
              fontSize: 13,
              fontWeight: isCurrent
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            song.artist,
            style: const TextStyle(
                color: Colors.white38, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: isCurrent
              ? const Icon(Icons.equalizer_rounded,
                  color: AurumTheme.gold, size: 18)
              : null,
          onTap: () => player.skipToIndex(i),
        );
      },
    );
  }
}

// ── Lyrics Placeholder ────────────────────────────────────────────────────────

class _LyricsPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lyrics_outlined,
              color: Colors.white12, size: 48),
          const SizedBox(height: 16),
          const Text(
            'Lyrics coming soon',
            style:
                TextStyle(color: Colors.white24, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ── Dynamic Background ────────────────────────────────────────────────────────

class _PlayerBackground extends StatelessWidget {
  final String artworkUrl;
  const _PlayerBackground({required this.artworkUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AurumArtwork(
          url: artworkUrl,
          size: MediaQuery.of(context).size.height,
          borderRadius: 0,
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.50),
                  Colors.black.withOpacity(0.72),
                  Colors.black.withOpacity(0.92),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Glass Button ──────────────────────────────────────────────────────────────

class _GlassButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final Color? color;

  const _GlassButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.09),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
          ),
        ),
        child: Icon(
          icon,
          color: color ?? Colors.white60,
          size: size,
        ),
      ),
    );
  }
}
