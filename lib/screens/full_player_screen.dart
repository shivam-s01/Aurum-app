import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  // ── Slide-in animation ───────────────────────────────────────────────────
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;

  // ── Disc rotation ─────────────────────────────────────────────────────────
  late AnimationController _discCtrl;

  // ── Drag to dismiss ───────────────────────────────────────────────────────
  double _dragOffset = 0;

  // ── Dynamic background color ──────────────────────────────────────────────
  Color _bgColor1 = const Color(0xFF2A1800);
  Color _bgColor2 = const Color(0xFF050508);
  String _lastArtworkUrl = '';
  bool _bgExtracting = false;

  @override
  void initState() {
    super.initState();

    // Slide up
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 370),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideCtrl.forward();

    // Disc — one full rotation every 10 s
    _discCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerProvider>();
    _syncDisc(player);
    _maybeExtractColor(player.currentSong?.artworkUrl ?? '');
  }

  // ── Keep disc in sync with play state ────────────────────────────────────
  void _syncDisc(PlayerProvider player) {
    if (player.isPlaying) {
      if (!_discCtrl.isAnimating) _discCtrl.repeat();
    } else {
      if (_discCtrl.isAnimating) _discCtrl.stop();
    }
  }

  // ── Extract dominant color from artwork ───────────────────────────────────
  Future<void> _maybeExtractColor(String url) async {
    if (url.isEmpty || url == _lastArtworkUrl || _bgExtracting) return;
    _lastArtworkUrl = url;
    _bgExtracting = true;

    try {
      // Local content:// or file paths — skip palette, use warm amber default
      if (url.startsWith('content://') || url.startsWith('/') ||
          url.startsWith('file://')) {
        if (mounted) {
          setState(() {
            _bgColor1 = const Color(0xFF2A1800);
            _bgColor2 = const Color(0xFF050508);
          });
        }
        _bgExtracting = false;
        return;
      }

      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(100, 100),
        maximumColorCount: 8,
      );

      final base = palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          palette.mutedColor?.color ??
          AurumTheme.goldDark;

      final hsl = HSLColor.fromColor(base);
      final dark = hsl
          .withLightness(0.09)
          .withSaturation((hsl.saturation * 0.65).clamp(0.0, 1.0))
          .toColor();

      if (mounted) {
        setState(() {
          _bgColor1 = dark;
          _bgColor2 = const Color(0xFF050508);
        });
      }
    } catch (_) {
      // Palette failed — keep current colors
    } finally {
      _bgExtracting = false;
    }
  }

  void _close() {
    _slideCtrl.reverse().then((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _discCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        // Sync disc & colors when song changes
        _syncDisc(player);
        if (song.artworkUrl != _lastArtworkUrl) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _maybeExtractColor(song.artworkUrl);
          });
        }

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: GestureDetector(
            onVerticalDragUpdate: (d) {
              if (d.delta.dy > 0) setState(() => _dragOffset += d.delta.dy);
            },
            onVerticalDragEnd: (d) {
              if (_dragOffset > 110 || (d.primaryVelocity ?? 0) > 650) {
                _close();
              } else {
                setState(() => _dragOffset = 0);
              }
            },
            child: SlideTransition(
              position: _slideAnim,
              child: Transform.translate(
                offset: Offset(0, _dragOffset * 0.32),
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      // ── Dynamic blurred background ──────────────────────
                      _PlayerBackground(
                        artworkUrl: song.artworkUrl,
                        color1: _bgColor1,
                        color2: _bgColor2,
                      ),
                      // ── Scrollable content ──────────────────────────────
                      SafeArea(
                        child: _buildContent(context, player, song),
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

  // ── Content column ────────────────────────────────────────────────────────
  Widget _buildContent(BuildContext context, PlayerProvider player, song) {
    final h = MediaQuery.of(context).size.height;

    return Column(
      children: [
        // Drag handle
        GestureDetector(
          onTap: _close,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: _dragOffset > 20 ? 52 : 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.28),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),

        // Header
        _buildHeader(context),
        SizedBox(height: h * 0.028),

        // Spinning disc
        _buildDisc(player, song.artworkUrl),
        SizedBox(height: h * 0.038),

        // Song info + shuffle
        _buildSongInfo(context, player, song),
        SizedBox(height: h * 0.024),

        // Progress bar
        _buildProgress(context, player),
        SizedBox(height: h * 0.028),

        // Controls
        _buildControls(context, player),
        SizedBox(height: h * 0.022),

        // Extras
        _buildExtras(context, player),
      ],
    );
  }

  // ── Header row ────────────────────────────────────────────────────────────
  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          _CircleBtn(
            icon: Icons.keyboard_arrow_down_rounded,
            size: 26,
            onTap: _close,
          ),
          const Expanded(
            child: Text(
              'NOW PLAYING',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.2,
              ),
            ),
          ),
          _CircleBtn(
            icon: Icons.more_vert_rounded,
            size: 20,
            onTap: () => _showMoreOptions(context),
          ),
        ],
      ),
    );
  }

  // ── Spinning vinyl disc ───────────────────────────────────────────────────
  Widget _buildDisc(PlayerProvider player, String artworkUrl) {
    final screenW = MediaQuery.of(context).size.width;
    final discSize = screenW * 0.74;
    final artSize = discSize * 0.62;

    return Center(
      child: AnimatedBuilder(
        animation: _discCtrl,
        builder: (_, __) {
          return Transform.rotate(
            angle: _discCtrl.value * 2 * math.pi,
            child: AnimatedScale(
              scale: player.isPlaying ? 1.0 : 0.86,
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              child: SizedBox(
                width: discSize,
                height: discSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Shadow behind disc
                    Container(
                      width: discSize,
                      height: discSize,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.75),
                            blurRadius: 55,
                            spreadRadius: 8,
                            offset: const Offset(0, 22),
                          ),
                          BoxShadow(
                            color: AurumTheme.gold.withOpacity(0.10),
                            blurRadius: 45,
                            spreadRadius: -5,
                          ),
                        ],
                      ),
                    ),

                    // Disc base (dark vinyl)
                    Container(
                      width: discSize,
                      height: discSize,
                      decoration: const BoxDecoration(
                        color: Color(0xFF111111),
                        shape: BoxShape.circle,
                      ),
                    ),

                    // Vinyl grooves
                    ...List.generate(6, (i) {
                      final r = discSize * (0.84 + i * 0.024);
                      return Container(
                        width: r,
                        height: r,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white
                                .withOpacity((0.028 - i * 0.003).clamp(0.0, 1.0)),
                            width: 0.6,
                          ),
                        ),
                      );
                    }),

                    // Artwork — circular, 62 % of disc
                    ClipOval(
                      child: SizedBox(
                        width: artSize,
                        height: artSize,
                        child: AurumArtwork(
                          url: artworkUrl,
                          size: artSize,
                          borderRadius: artSize / 2,
                        ),
                      ),
                    ),

                    // Ring around artwork
                    Container(
                      width: artSize + 6,
                      height: artSize + 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.08),
                          width: 1.5,
                        ),
                      ),
                    ),

                    // Spindle hole (outer dark)
                    Container(
                      width: discSize * 0.085,
                      height: discSize * 0.085,
                      decoration: const BoxDecoration(
                        color: Color(0xFF0A0A0A),
                        shape: BoxShape.circle,
                      ),
                    ),

                    // Spindle hole (inner gold dot)
                    Container(
                      width: discSize * 0.032,
                      height: discSize * 0.032,
                      decoration: BoxDecoration(
                        color: AurumTheme.gold.withOpacity(0.55),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Song info + shuffle toggle ─────────────────────────────────────────────
  Widget _buildSongInfo(BuildContext context, PlayerProvider player, song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title.isNotEmpty ? song.title : 'Unknown Title',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Text(
                  song.artist.isNotEmpty ? song.artist : 'Unknown Artist',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.50),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // Shuffle toggle
          GestureDetector(
            onTap: player.toggleShuffle,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: player.shuffle
                    ? AurumTheme.gold.withOpacity(0.18)
                    : Colors.white.withOpacity(0.07),
                shape: BoxShape.circle,
                border: Border.all(
                  color: player.shuffle
                      ? AurumTheme.gold.withOpacity(0.45)
                      : Colors.transparent,
                ),
              ),
              child: Icon(
                Icons.shuffle_rounded,
                color: player.shuffle ? AurumTheme.gold : Colors.white30,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Progress bar ──────────────────────────────────────────────────────────
  Widget _buildProgress(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Buffered track
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: player.bufferedProgress,
                  backgroundColor: Colors.white.withOpacity(0.08),
                  valueColor: AlwaysStoppedAnimation(
                    Colors.white.withOpacity(0.18),
                  ),
                  minHeight: 3,
                ),
              ),
              // Seek slider on top
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 16),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white.withOpacity(0.12),
                ),
                child: Slider(
                  value: player.progress.clamp(0.0, 1.0),
                  onChanged: player.seek,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  player.positionString,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.38),
                    fontSize: 11,
                  ),
                ),
                Text(
                  player.durationString,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.38),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Playback controls ──────────────────────────────────────────────────────
  Widget _buildControls(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Loop
          GestureDetector(
            onTap: player.toggleLoop,
            child: AnimatedOpacity(
              opacity: player.loopMode != LoopMode.off ? 1.0 : 0.35,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                player.loopMode == LoopMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                color: player.loopMode != LoopMode.off
                    ? AurumTheme.gold
                    : Colors.white,
                size: 22,
              ),
            ),
          ),

          // Previous
          _ControlBtn(
            icon: Icons.skip_previous_rounded,
            size: 56,
            iconSize: 30,
            onTap: player.skipPrev,
          ),

          // Play / Pause — large gold button
          GestureDetector(
            onTap: player.togglePlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: AurumTheme.goldGradient,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.55),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: player.isLoading
                  ? const Center(child: AurumLoader(size: 30))
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
          _ControlBtn(
            icon: Icons.skip_next_rounded,
            size: 56,
            iconSize: 30,
            onTap: player.skipNext,
          ),

          // Queue
          GestureDetector(
            onTap: () => _showQueue(context, player),
            child: Icon(
              Icons.queue_music_rounded,
              color: Colors.white.withOpacity(0.30),
              size: 22,
            ),
          ),
        ],
      ),
    );
  }

  // ── Bottom extras ──────────────────────────────────────────────────────────
  Widget _buildExtras(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(Icons.favorite_border_rounded,
              color: Colors.white.withOpacity(0.24), size: 20),
          Icon(Icons.share_outlined,
              color: Colors.white.withOpacity(0.24), size: 20),
          Icon(Icons.playlist_add_rounded,
              color: Colors.white.withOpacity(0.24), size: 22),
          Icon(Icons.equalizer_rounded,
              color: Colors.white.withOpacity(0.24), size: 22),
        ],
      ),
    );
  }

  void _showMoreOptions(BuildContext context) {
    // TODO: options sheet
  }

  // ── Queue bottom sheet ─────────────────────────────────────────────────────
  void _showQueue(BuildContext context, PlayerProvider player) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F0F18),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scroll) => Column(
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Queue',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: scroll,
                itemCount: player.queue.length,
                onReorder: (from, to) {
                  player.moveQueueItem(from, to > from ? to - 1 : to);
                },
                itemBuilder: (ctx, i) {
                  final s = player.queue[i];
                  final isCur = i == player.currentIndex;
                  return ListTile(
                    key: ValueKey('q_${s.id}_$i'),
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: isCur
                            ? Border.all(
                                color: AurumTheme.gold.withOpacity(0.6),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: isCur
                            ? Container(
                                color: AurumTheme.gold.withOpacity(0.12),
                                child: const Icon(
                                  Icons.equalizer_rounded,
                                  color: AurumTheme.gold,
                                  size: 18,
                                ),
                              )
                            : AurumArtwork(
                                url: s.artworkUrl,
                                size: 42,
                                borderRadius: 8,
                              ),
                      ),
                    ),
                    title: Text(
                      s.title,
                      style: TextStyle(
                        color: isCur ? AurumTheme.gold : Colors.white,
                        fontSize: 13,
                        fontWeight:
                            isCur ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      s.artist,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isCur
                        ? null
                        : GestureDetector(
                            onTap: () => player.removeFromQueue(i),
                            child: Icon(
                              Icons.close_rounded,
                              color: Colors.white.withOpacity(0.24),
                              size: 18,
                            ),
                          ),
                    onTap: () {
                      player.skipToIndex(i);
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated blurred background
// ─────────────────────────────────────────────────────────────────────────────
class _PlayerBackground extends StatelessWidget {
  final String artworkUrl;
  final Color color1;
  final Color color2;

  const _PlayerBackground({
    required this.artworkUrl,
    required this.color1,
    required this.color2,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Artwork stretched as blurred bg — show even for local songs
        if (artworkUrl.isNotEmpty)
          SizedBox.expand(
            child: AurumArtwork(
              url: artworkUrl,
              size: size.height,
              borderRadius: 0,
            ),
          ),

        // Heavy blur
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 72, sigmaY: 72),
          child: const SizedBox.expand(),
        ),

        // Dynamic color overlay — animated when song changes
        AnimatedContainer(
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color1.withOpacity(0.72),
                color2.withOpacity(0.85),
                Colors.black.withOpacity(0.90),
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        ),

        // Bottom vignette
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.transparent,
                Color(0xCC000000),
                Colors.black,
              ],
              stops: [0.0, 0.45, 0.82, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable circle button (back, options)
// ─────────────────────────────────────────────────────────────────────────────
class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final Color? color;

  const _CircleBtn({
    required this.icon,
    required this.onTap,
    this.size = 22,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.07)),
        ),
        child: Icon(icon, color: color ?? Colors.white70, size: size),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Prev / Next control button
// ─────────────────────────────────────────────────────────────────────────────
class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback onTap;

  const _ControlBtn({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    );
  }
}
