import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import '../providers/player_provider.dart';
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
  late AnimationController _slideController;
  late Animation<Offset> _slideAnim;
  late AnimationController _artworkPulse;

  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _slideController.forward();

    _artworkPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.97,
      upperBound: 1.0,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _slideController.dispose();
    _artworkPulse.dispose();
    super.dispose();
  }

  void _close() {
    _slideController.reverse().then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (d.delta.dy > 0) setState(() => _dragOffset += d.delta.dy);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_dragOffset > 100 || (d.primaryVelocity ?? 0) > 700) {
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
                offset: Offset(0, _dragOffset * 0.35),
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      // ── Dynamic blurred background ──
                      _DynamicBackground(artworkUrl: song.artworkUrl),
                      // ── Content ──
                      SafeArea(
                        child: Column(
                          children: [
                            _buildHandle(),
                            _buildHeader(),
                            const SizedBox(height: 24),
                            // ── Artwork ──
                            _buildArtwork(player, song.artworkUrl),
                            const SizedBox(height: 32),
                            // ── Song info ──
                            _buildSongInfo(context, player, song),
                            const SizedBox(height: 20),
                            // ── Progress ──
                            _buildProgress(context, player),
                            const SizedBox(height: 28),
                            // ── Controls ──
                            _buildControls(context, player),
                            const SizedBox(height: 24),
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          GestureDetector(
            onTap: _close,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 26),
            ),
          ),
          const Expanded(
            child: Text('Now Playing',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 1.5)),
          ),
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
            child: const Icon(Icons.more_vert_rounded, color: Colors.white60, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork(PlayerProvider player, String url) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: AnimatedScale(
        scale: player.isPlaying ? 1.0 : 0.9,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 50,
                offset: const Offset(0, 25),
              ),
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.15),
                blurRadius: 40,
                spreadRadius: -10,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: AurumArtwork(
              url: url,
              size: MediaQuery.of(context).size.width - 64,
              borderRadius: 24,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSongInfo(BuildContext context, PlayerProvider player, song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title,
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
                Text(song.artist,
                  style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: player.toggleShuffle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: player.shuffle
                    ? AurumTheme.gold.withOpacity(0.2)
                    : Colors.white.withOpacity(0.08),
                shape: BoxShape.circle,
                border: Border.all(
                  color: player.shuffle ? AurumTheme.gold.withOpacity(0.4) : Colors.transparent,
                ),
              ),
              child: Icon(Icons.shuffle_rounded,
                color: player.shuffle ? AurumTheme.gold : Colors.white38,
                size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withOpacity(0.15),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withOpacity(0.15),
            ),
            child: Slider(value: player.progress, onChanged: player.seek),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(player.positionString,
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
                Text(player.durationString,
                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Loop
          GestureDetector(
            onTap: player.toggleLoop,
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
          // Prev
          GestureDetector(
            onTap: player.skipPrev,
            child: Container(
              width: 54, height: 54,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 30),
            ),
          ),
          // Play/Pause — big gold button
          GestureDetector(
            onTap: player.togglePlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 70, height: 70,
              decoration: BoxDecoration(
                gradient: AurumTheme.goldGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.5),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: player.isLoading
                  ? const Center(child: AurumLoader(size: 30))
                  : Icon(
                      player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.black,
                      size: 36,
                    ),
            ),
          ),
          // Next
          GestureDetector(
            onTap: player.skipNext,
            child: Container(
              width: 54, height: 54,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 30),
            ),
          ),
          // Queue
          GestureDetector(
            onTap: () => _showQueue(context, player),
            child: const Icon(Icons.queue_music_rounded, color: Colors.white30, size: 22),
          ),
        ],
      ),
    );
  }

  void _showQueue(BuildContext context, PlayerProvider player) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(children: [
        const SizedBox(height: 8),
        Container(width: 36, height: 4,
          decoration: BoxDecoration(color: AurumTheme.divider, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 12),
        const Text('Queue', style: TextStyle(color: AurumTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: player.queue.length,
            itemBuilder: (context, i) {
              final s = player.queue[i];
              final isCurrent = i == player.currentIndex;
              return ListTile(
                leading: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: isCurrent ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: isCurrent ? Border.all(color: AurumTheme.gold.withOpacity(0.5)) : null,
                  ),
                  child: isCurrent
                      ? const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 18)
                      : const Icon(Icons.music_note_rounded, color: AurumTheme.textMuted, size: 18),
                ),
                title: Text(s.title,
                  style: TextStyle(
                    color: isCurrent ? AurumTheme.gold : AurumTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.artist,
                  style: const TextStyle(color: AurumTheme.textSecondary, fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () { player.skipToIndex(i); Navigator.pop(context); },
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ── Dynamic blurred background ───────────────────────────────────────────────

class _DynamicBackground extends StatelessWidget {
  final String artworkUrl;
  const _DynamicBackground({required this.artworkUrl});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Artwork stretched as background
        AurumArtwork(
          url: artworkUrl,
          size: MediaQuery.of(context).size.height,
          borderRadius: 0,
        ),
        // Heavy blur
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.45),
                  Colors.black.withOpacity(0.75),
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
