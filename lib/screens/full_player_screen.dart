import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import 'queue_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  late AnimationController _rotateController;
  bool _draggingSlider = false;
  double _sliderValue = 0.0;

  @override
  void initState() {
    super.initState();
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _rotateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.hasSong) {
          Navigator.pop(context);
          return const SizedBox.shrink();
        }
        final song = player.currentSong!;

        // Keep rotating only when playing
        if (player.isPlaying) {
          _rotateController.repeat();
        } else {
          _rotateController.stop();
        }

        return Scaffold(
          backgroundColor: AurumTheme.bg,
          body: Stack(
            children: [
              // Background gradient
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AurumTheme.gold.withOpacity(0.05),
                        AurumTheme.bg,
                        AurumTheme.bg,
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _buildTopBar(context),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              const SizedBox(height: 24),
                              _buildArtwork(player, song),
                              const SizedBox(height: 32),
                              _buildSongInfo(song),
                              const SizedBox(height: 28),
                              _buildProgressBar(player),
                              const SizedBox(height: 24),
                              _buildControls(player),
                              const SizedBox(height: 20),
                              _buildExtras(context, player),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
            color: AurumTheme.textSecondary,
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                const Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: AurumTheme.textMuted,
                    fontSize: 10,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.queue_music_rounded, size: 24),
            color: AurumTheme.textSecondary,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QueueScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork(PlayerProvider player, song) {
    return AnimatedBuilder(
      animation: _rotateController,
      builder: (_, child) {
        return Transform.rotate(
          angle: player.isPlaying ? _rotateController.value * 2 * 3.14159 : 0,
          child: child,
        );
      },
      child: Container(
        width: 270,
        height: 270,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AurumTheme.gold.withOpacity(0.25),
              blurRadius: 40,
              spreadRadius: 5,
            ),
          ],
        ),
        child: ClipOval(
          child: AurumArtwork(
            url: song.artworkUrl,
            size: 270,
            borderRadius: 135,
          ),
        ),
      ),
    );
  }

  Widget _buildSongInfo(song) {
    return Column(
      children: [
        Text(
          song.title,
          style: const TextStyle(
            color: AurumTheme.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          song.artist,
          style: const TextStyle(
            color: AurumTheme.textSecondary,
            fontSize: 15,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (song.album.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            song.album,
            style: const TextStyle(color: AurumTheme.textMuted, fontSize: 12),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildProgressBar(PlayerProvider player) {
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: AurumTheme.gold,
            inactiveTrackColor: AurumTheme.bgSurface,
            thumbColor: AurumTheme.gold,
            overlayColor: AurumTheme.gold.withOpacity(0.2),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: _draggingSlider
                ? _sliderValue
                : player.progress.isNaN
                    ? 0.0
                    : player.progress,
            onChangeStart: (v) {
              setState(() { _draggingSlider = true; _sliderValue = v; });
            },
            onChanged: (v) {
              setState(() { _sliderValue = v; });
            },
            onChangeEnd: (v) {
              player.seek(v);
              setState(() { _draggingSlider = false; });
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(player.positionString, style: const TextStyle(color: AurumTheme.textMuted, fontSize: 12)),
              Text(player.durationString, style: const TextStyle(color: AurumTheme.textMuted, fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls(PlayerProvider player) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Shuffle
        IconButton(
          icon: Icon(
            Icons.shuffle_rounded,
            color: player.shuffle ? AurumTheme.gold : AurumTheme.textMuted,
          ),
          iconSize: 22,
          onPressed: player.toggleShuffle,
        ),
        // Prev
        IconButton(
          icon: const Icon(Icons.skip_previous_rounded),
          color: AurumTheme.textPrimary,
          iconSize: 36,
          onPressed: player.skipPrev,
        ),
        // Play/pause
        GestureDetector(
          onTap: player.togglePlay,
          child: Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              color: AurumTheme.gold,
              shape: BoxShape.circle,
            ),
            child: player.isLoading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(color: AurumTheme.bg, strokeWidth: 2.5),
                  )
                : Icon(
                    player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: AurumTheme.bg,
                    size: 36,
                  ),
          ),
        ),
        // Next
        IconButton(
          icon: const Icon(Icons.skip_next_rounded),
          color: AurumTheme.textPrimary,
          iconSize: 36,
          onPressed: player.skipNext,
        ),
        // Loop
        IconButton(
          icon: Icon(
            player.loopMode == LoopMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: player.loopMode != LoopMode.off ? AurumTheme.gold : AurumTheme.textMuted,
          ),
          iconSize: 22,
          onPressed: player.toggleLoop,
        ),
      ],
    );
  }

  Widget _buildExtras(BuildContext context, PlayerProvider player) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ExtraButton(
          icon: Icons.queue_music_rounded,
          label: 'Queue',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const QueueScreen()),
          ),
        ),
      ],
    );
  }
}

class _ExtraButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ExtraButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: AurumTheme.textSecondary, size: 22),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: AurumTheme.textMuted, fontSize: 11)),
        ],
      ),
    );
  }
}
