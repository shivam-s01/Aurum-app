import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_loader.dart';
import 'queue_screen.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  late AnimationController _rotateController;
  late AnimationController _colorController;
  bool _draggingSlider = false;
  double _sliderValue = 0.0;
  Color _dominantColor = AurumTheme.gold;
  Color _prevColor = AurumTheme.gold;
  String? _lastArtworkUrl;

  @override
  void initState() {
    super.initState();
    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _rotateController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  Future<void> _extractColor(String? url) async {
    if (url == null || url.isEmpty || url == _lastArtworkUrl) return;
    _lastArtworkUrl = url;
    try {
      final generator = await PaletteGenerator.fromImageProvider(
        NetworkImage(url),
        size: const Size(100, 100),
        maximumColorCount: 8,
      );
      final color = generator.vibrantColor?.color ??
          generator.dominantColor?.color ??
          AurumTheme.gold;
      if (mounted) {
        setState(() {
          _prevColor = _dominantColor;
          _dominantColor = color;
        });
        _colorController.forward(from: 0);
      }
    } catch (_) {}
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

        // Extract color when song changes
        _extractColor(song.artworkUrl);

        if (player.isPlaying) {
          _rotateController.repeat();
        } else {
          _rotateController.stop();
        }

        return Scaffold(
          backgroundColor: AurumTheme.bgOf(context),
          body: AnimatedBuilder(
            animation: _colorController,
            builder: (_, child) {
              final animColor = Color.lerp(
                _prevColor,
                _dominantColor,
                _colorController.value,
              )!;
              return Stack(
                children: [
                  // Dynamic background gradient
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            animColor.withOpacity(0.18),
                            animColor.withOpacity(0.06),
                            AurumTheme.bgOf(context),
                            AurumTheme.bgOf(context),
                          ],
                          stops: const [0.0, 0.25, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    child: Column(
                      children: [
                        _buildTopBar(context, animColor),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              child: Column(
                                children: [
                                  const SizedBox(height: 24),
                                  _buildArtwork(player, song),
                                  const SizedBox(height: 32),
                                  _buildSongInfo(context, song, animColor),
                                  const SizedBox(height: 28),
                                  _buildProgressBar(context, player),
                                  const SizedBox(height: 24),
                                  _buildControls(context, player, animColor),
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
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context, Color accent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
            color: AurumTheme.textSecondaryOf(context),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
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
            color: AurumTheme.textSecondaryOf(context),
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
          angle: player.isPlaying
              ? _rotateController.value * 2 * 3.14159
              : 0,
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
              color: _dominantColor.withOpacity(0.35),
              blurRadius: 50,
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

  Widget _buildSongInfo(BuildContext context, song, Color accent) {
    return Column(
      children: [
        Text(
          song.title,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
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
          style: TextStyle(
            color: AurumTheme.textSecondaryOf(context),
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
            style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  Widget _buildProgressBar(BuildContext context, PlayerProvider player) {
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: _dominantColor,
            inactiveTrackColor: AurumTheme.bgSurfaceOf(context),
            thumbColor: _dominantColor,
            overlayColor: _dominantColor.withOpacity(0.2),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: _draggingSlider
                ? _sliderValue
                : player.progress.isNaN
                    ? 0.0
                    : player.progress,
            onChangeStart: (v) {
              setState(() {
                _draggingSlider = true;
                _sliderValue = v;
              });
            },
            onChanged: (v) {
              setState(() => _sliderValue = v);
            },
            onChangeEnd: (v) {
              player.seek(v);
              setState(() => _draggingSlider = false);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                player.positionString,
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 12,
                ),
              ),
              Text(
                player.durationString,
                style: TextStyle(
                  color: AurumTheme.textMutedOf(context),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls(
      BuildContext context, PlayerProvider player, Color accent) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          icon: Icon(
            Icons.shuffle_rounded,
            color: player.shuffle ? accent : AurumTheme.textMutedOf(context),
          ),
          iconSize: 22,
          onPressed: player.toggleShuffle,
        ),
        IconButton(
          icon: Icon(
            Icons.skip_previous_rounded,
            color: AurumTheme.textPrimaryOf(context),
          ),
          iconSize: 36,
          onPressed: player.skipPrev,
        ),
        // Play/Pause with AurumLoader
        GestureDetector(
          onTap: player.togglePlay,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: player.isLoading
                ? const Center(
                    child: AurumLoader(size: 32, color: Colors.white),
                  )
                : Icon(
                    player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
          ),
        ),
        IconButton(
          icon: Icon(
            Icons.skip_next_rounded,
            color: AurumTheme.textPrimaryOf(context),
          ),
          iconSize: 36,
          onPressed: player.skipNext,
        ),
        IconButton(
          icon: Icon(
            player.loopMode == LoopMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            color: player.loopMode != LoopMode.off
                ? accent
                : AurumTheme.textMutedOf(context),
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
        _ExtraBtn(
          icon: Icons.queue_music_rounded,
          label: 'Queue',
          context: context,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const QueueScreen()),
          ),
        ),
      ],
    );
  }
}

class _ExtraBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final BuildContext context;

  const _ExtraBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.context,
  });

  @override
  Widget build(BuildContext ctx) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: AurumTheme.textSecondaryOf(context), size: 22),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: AurumTheme.textMutedOf(context),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
