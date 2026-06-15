import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FullPlayerScreen v5.0 — Echo Nightly Premium
// Changes from v4.3:
//   • _BgLayer: 3-color palette extraction (vibrant + dominant + dark muted)
//   • _BgLayer: breathing gradient animation via _breatheCtrl (4s loop)
//   • _BgLayer: blur sigma reduced 60→50 for lighter GPU load
//   • _showOptions: replaced basic list with premium grid sheet (JioSaavn style)
//   • _QueuePage: Echo Nightly style — "Now Playing" header, gradient tiles
//   • _QueueTile: album art, gradient highlight on current, cleaner layout
//   • _PremiumOptionsSheet: new widget — 2-col grid, song header, all actions
// ─────────────────────────────────────────────────────────────────────────────

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {

  // ── Entry animation (420ms, easeOutCubic) ──
  late final AnimationController _entryCtrl;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  // ── Artwork scale on play/pause/song change ──
  late final AnimationController _artworkCtrl;
  late final Animation<double> _artworkAnim;

  // ── Play button tactile scale (110ms) ──
  late final AnimationController _playBtnCtrl;
  late final Animation<double> _playBtnAnim;

  // ── Background color morphing (600ms) ──
  late final AnimationController _bgColorCtrl;
  Color _targetBg1 = const Color(0xFF0D0D18);
  Color _targetBg2 = const Color(0xFF060608);
  Color _targetBg3 = const Color(0xFF030305);
  Color _currentBg1 = const Color(0xFF0D0D18);
  Color _currentBg2 = const Color(0xFF060608);
  Color _currentBg3 = const Color(0xFF030305);

  // ── Breathing gradient (4s loop, reverse) ──
  late final AnimationController _breatheCtrl;

  // ── Swipe-down to dismiss ──
  double _dragY = 0;
  bool _isDragging = false;

  // ── Palette / song cache ──
  String? _lastArtUrl;
  String? _lastSongId;

  // ── Favourite toggle (local) ──
  bool _isFav = false;

  @override
  void initState() {
    super.initState();

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutCubic));
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0)
        .animate(CurvedAnimation(
            parent: _entryCtrl,
            curve: const Interval(0.0, 0.6, curve: Curves.easeOut)));
    _entryCtrl.forward();

    _artworkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _artworkAnim = Tween<double>(begin: 0.94, end: 1.0)
        .animate(CurvedAnimation(parent: _artworkCtrl, curve: Curves.easeOutCubic));

    _playBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );
    _playBtnAnim = Tween<double>(begin: 1.0, end: 0.87)
        .animate(CurvedAnimation(parent: _playBtnCtrl, curve: Curves.easeInOut));

    _bgColorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    // Breathing: slow pulse 4s, loops forever with reverse
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _artworkCtrl.dispose();
    _playBtnCtrl.dispose();
    _bgColorCtrl.dispose();
    _breatheCtrl.dispose();
    super.dispose();
  }

  // ── Palette extraction → 3 colors, starts morph ──
  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtUrl) return;
    _lastArtUrl = url;
    try {
      final ImageProvider provider;
      if (url.startsWith('http')) {
        provider = CachedNetworkImageProvider(url);
      } else {
        return;
      }
      final pg = await PaletteGenerator.fromImageProvider(
          provider, size: const Size(80, 80));

      // 3 distinct color roles
      final c1 = pg.vibrantColor?.color ??
          pg.dominantColor?.color ??
          const Color(0xFF1A1630);
      final c2 = pg.dominantColor?.color ??
          pg.mutedColor?.color ??
          const Color(0xFF120F24);
      final c3 = pg.darkMutedColor?.color ??
          pg.darkVibrantColor?.color ??
          const Color(0xFF080810);

      if (!mounted) return;

      // Snapshot current lerped position before morphing
      final t = _bgColorCtrl.value;
      _currentBg1 = Color.lerp(_currentBg1, _targetBg1, t) ?? _currentBg1;
      _currentBg2 = Color.lerp(_currentBg2, _targetBg2, t) ?? _currentBg2;
      _currentBg3 = Color.lerp(_currentBg3, _targetBg3, t) ?? _currentBg3;

      // Darken each color appropriately for bg
      _targetBg1 = Color.lerp(c1, Colors.black, 0.40)!;
      _targetBg2 = Color.lerp(c2, Colors.black, 0.62)!;
      _targetBg3 = Color.lerp(c3, Colors.black, 0.80)!;

      _bgColorCtrl.forward(from: 0.0);
    } catch (_) {}
  }

  void _triggerArtworkAnimation() {
    if (mounted && !_artworkCtrl.isAnimating) {
      _artworkCtrl.forward(from: 0.0);
    }
  }

  void _close() {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    _entryCtrl.reverse().then((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _onPlayTap(PlayerProvider player) async {
    HapticFeedback.heavyImpact();
    await _playBtnCtrl.forward();
    await _playBtnCtrl.reverse();
    player.togglePlay();
    _triggerArtworkAnimation();
  }

  void _openPanel() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(165),
      useSafeArea: false,
      builder: (_) => _PremiumContentPanel(
        bg1: _currentBg1,
        bg2: _currentBg2,
        bg3: _currentBg3,
      ),
    );
  }

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => _PremiumOptionsSheet(
        song: song,
        player: player,
        accentColor: _targetBg1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        // Trigger artwork + color extraction on song change only
        if (song.id != _lastSongId) {
          _lastSongId = song.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _triggerArtworkAnimation();
            if (song.artworkUrl.isNotEmpty) _extractColor(song.artworkUrl);
          });
        }

        final dragOpacity =
            (1.0 - (_dragY / 320).clamp(0.0, 0.55)).clamp(0.0, 1.0);
        final dragScale =
            (1.0 - (_dragY / 2200).clamp(0.0, 0.06)).clamp(0.0, 1.0);

        return SlideTransition(
          position: _slideAnim,
          child: FadeTransition(
            opacity: _fadeAnim,
            child: GestureDetector(
              onVerticalDragStart: (_) => setState(() => _isDragging = true),
              onVerticalDragUpdate: (d) {
                if (d.delta.dy > 0) setState(() => _dragY += d.delta.dy);
              },
              onVerticalDragEnd: (d) {
                setState(() => _isDragging = false);
                if (_dragY > 110 || (d.primaryVelocity ?? 0) > 750) {
                  _close();
                } else {
                  setState(() => _dragY = 0);
                }
              },
              child: Transform.translate(
                offset: Offset(0, _dragY.clamp(0.0, 280.0)),
                child: Transform.scale(
                  scale: dragScale,
                  child: Opacity(
                    opacity: dragOpacity,
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      body: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Background: isolated repaint boundary
                          RepaintBoundary(
                            child: _BgLayer(
                              song: song,
                              bgCtrl: _bgColorCtrl,
                              breatheCtrl: _breatheCtrl,
                              startBg1: _currentBg1,
                              startBg2: _currentBg2,
                              startBg3: _currentBg3,
                              targetBg1: _targetBg1,
                              targetBg2: _targetBg2,
                              targetBg3: _targetBg3,
                            ),
                          ),
                          SafeArea(
                            child: _buildBody(context, player, song),
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

  Widget _buildBody(BuildContext context, PlayerProvider player, Song song) {
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final w = constraints.maxWidth;
      final isCompact = h < 640;
      final isTablet = w > 600;

      final vGapSm = isCompact ? 8.0 : 16.0;
      final vGapMd = isCompact ? 12.0 : 20.0;
      final hPad = isTablet ? w * 0.16 : 28.0;

      return GestureDetector(
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -400) _openPanel();
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DragHandle(isDragging: _isDragging),
            _TopBar(song: song, onMore: () => _showOptions(context)),
            SizedBox(height: vGapMd),
            _Artwork(
              song: song,
              player: player,
              hPad: hPad,
              h: h,
              w: w,
              artworkAnim: _artworkAnim,
            ),
            SizedBox(height: vGapMd),
            _SongInfo(
              song: song,
              hPad: hPad,
              isTablet: isTablet,
              isFav: _isFav,
              onFavTap: () {
                HapticFeedback.lightImpact();
                setState(() => _isFav = !_isFav);
              },
            ),
            SizedBox(height: vGapSm),
            _SeekBar(player: player, hPad: hPad),
            SizedBox(height: vGapSm),
            _Controls(
              player: player,
              hPad: hPad,
              playBtnAnim: _playBtnAnim,
              bg1: _currentBg1,
              onPlayTap: () => _onPlayTap(player),
            ),
            SizedBox(height: isCompact ? 8.0 : 12.0),
            _QualityPills(song: song, hPad: hPad),
            const Spacer(),
            _BottomPill(hPad: hPad, onTap: _openPanel),
            SizedBox(height: isCompact ? 8.0 : 12.0),
          ],
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drag Handle
// ─────────────────────────────────────────────────────────────────────────────
class _DragHandle extends StatelessWidget {
  final bool isDragging;
  const _DragHandle({required this.isDragging});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: isDragging ? 44 : 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(isDragging ? 80 : 45),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top Bar
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final Song song;
  final VoidCallback onMore;
  const _TopBar({required this.song, required this.onMore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        _IconBtn(
          icon: Icons.keyboard_arrow_down_rounded,
          size: 26,
          onTap: () => Navigator.pop(context),
          semanticLabel: 'Close player',
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withAlpha(12), width: 0.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                'NOW PLAYING',
                style: TextStyle(
                  color: Colors.white.withAlpha(72),
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.album.isNotEmpty ? song.album : 'Aurum Music',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
        _IconBtn(
          icon: Icons.more_vert_rounded,
          size: 22,
          onTap: onMore,
          semanticLabel: 'More options',
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
// ─────────────────────────────────────────────────────────────────────────────
class _Artwork extends StatelessWidget {
  final Song song;
  final PlayerProvider player;
  final double hPad, h, w;
  final Animation<double> artworkAnim;

  const _Artwork({
    required this.song,
    required this.player,
    required this.hPad,
    required this.h,
    required this.w,
    required this.artworkAnim,
  });

  @override
  Widget build(BuildContext context) {
    final maxArtSize = (w - hPad * 2).clamp(0.0, h * 0.42);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Center(
        child: SizedBox(
          width: maxArtSize,
          height: maxArtSize,
          child: AnimatedBuilder(
            animation: artworkAnim,
            builder: (_, child) => Transform.scale(
              scale: artworkAnim.value,
              child: child,
            ),
            child: Hero(
              tag: 'aurum_artwork',
              flightShuttleBuilder: (context, animation, direction, from, to) {
                return Material(
                  color: Colors.transparent,
                  child: ScaleTransition(scale: animation, child: to.widget),
                );
              },
              child: RepaintBoundary(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(player.isPlaying ? 180 : 110),
                        blurRadius: player.isPlaying ? 64 : 40,
                        offset: const Offset(0, 24),
                        spreadRadius: player.isPlaying ? 4 : 0,
                      ),
                      BoxShadow(
                        color: Colors.black.withAlpha(90),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: AurumArtwork(
                      url: song.artworkUrl,
                      size: double.infinity,
                      borderRadius: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song Info
// ─────────────────────────────────────────────────────────────────────────────
class _SongInfo extends StatelessWidget {
  final Song song;
  final double hPad;
  final bool isTablet, isFav;
  final VoidCallback onFavTap;

  const _SongInfo({
    required this.song,
    required this.hPad,
    required this.isTablet,
    required this.isFav,
    required this.onFavTap,
  });

  @override
  Widget build(BuildContext context) {
    final titleSize = isTablet ? 26.0 : 22.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MarqueeText(
                  text: song.title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: Colors.white.withAlpha(128),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          _FavButton(isFav: isFav, onTap: onFavTap),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seek Bar
// ─────────────────────────────────────────────────────────────────────────────
class _SeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  const _SeekBar({required this.player, required this.hPad});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _dragging ? 3.5 : 2.5,
              thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _dragging ? 8 : 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white.withAlpha(28),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withAlpha(16),
              trackShape: const _BufferedTrackShape(),
            ),
            child: Slider(
              value: widget.player.progress,
              secondaryTrackValue: widget.player.duration.inMilliseconds > 0
                  ? (widget.player.buffered.inMilliseconds /
                          widget.player.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0,
              onChangeStart: (_) {
                HapticFeedback.selectionClick();
                setState(() => _dragging = true);
              },
              onChanged: widget.player.seek,
              onChangeEnd: (_) {
                HapticFeedback.selectionClick();
                setState(() => _dragging = false);
              },
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.player.positionString,
                style: TextStyle(
                  color: Colors.white.withAlpha(92),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
              Text(
                widget.player.durationString,
                style: TextStyle(
                  color: Colors.white.withAlpha(92),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Controls
// ─────────────────────────────────────────────────────────────────────────────
class _Controls extends StatelessWidget {
  final PlayerProvider player;
  final double hPad;
  final Animation<double> playBtnAnim;
  final Color bg1;
  final VoidCallback onPlayTap;

  const _Controls({
    required this.player,
    required this.hPad,
    required this.playBtnAnim,
    required this.bg1,
    required this.onPlayTap,
  });

  @override
  Widget build(BuildContext context) {
    final isLoopOne = player.loopMode == LoopMode.one;
    final isLoopAll = player.loopMode == LoopMode.all;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad - 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CtrlBtn(
            icon: Icons.shuffle_rounded,
            size: 20,
            active: player.shuffle,
            semanticLabel: 'Shuffle',
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleShuffle();
            },
          ),
          _CtrlBtn(
            icon: Icons.skip_previous_rounded,
            size: 38,
            color: Colors.white.withAlpha(210),
            semanticLabel: 'Previous',
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipPrev();
            },
          ),
          ScaleTransition(
            scale: playBtnAnim,
            child: _PremiumPlayButton(
              isPlaying: player.isPlaying,
              isLoading: player.isLoading,
              bg1: bg1,
              onTap: onPlayTap,
            ),
          ),
          _CtrlBtn(
            icon: Icons.skip_next_rounded,
            size: 38,
            color: Colors.white.withAlpha(210),
            semanticLabel: 'Next',
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipNext();
            },
          ),
          _CtrlBtn(
            icon: isLoopOne
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            size: 20,
            active: isLoopAll || isLoopOne,
            semanticLabel: 'Repeat',
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleLoop();
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pills
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPills extends StatelessWidget {
  final Song song;
  final double hPad;
  const _QualityPills({required this.song, required this.hPad});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (song.isLocal) parts.add('LOCAL');
    if (song.language != null && song.language!.isNotEmpty) {
      parts.add(song.language!.toUpperCase());
    }
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) return const SizedBox(height: 8);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        children: parts.map((p) => _QualityPill(label: p)).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom Pill
// ─────────────────────────────────────────────────────────────────────────────
class _BottomPill extends StatelessWidget {
  final double hPad;
  final VoidCallback onTap;
  const _BottomPill({required this.hPad, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: GestureDetector(
        onTap: onTap,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -300) onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(10),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withAlpha(18), width: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.keyboard_arrow_up_rounded,
                  color: Colors.white.withAlpha(96), size: 16),
              const SizedBox(width: 8),
              Text(
                'Queue · Lyrics · Info',
                style: TextStyle(
                  color: Colors.white.withAlpha(112),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Play Button
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumPlayButton extends StatelessWidget {
  final bool isPlaying, isLoading;
  final Color bg1;
  final VoidCallback onTap;

  const _PremiumPlayButton({
    required this.isPlaying,
    required this.isLoading,
    required this.bg1,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: isPlaying ? 'Pause' : 'Play',
      button: true,
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.white.withAlpha(38),
                blurRadius: 32,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: bg1.withAlpha(128),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: isLoading
                ? const SizedBox(
                    key: ValueKey('loading'),
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black38,
                    ),
                  )
                : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(isPlaying),
                    color: Colors.black,
                    size: 36,
                  ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Favourite Button
// ─────────────────────────────────────────────────────────────────────────────
class _FavButton extends StatelessWidget {
  final bool isFav;
  final VoidCallback onTap;
  const _FavButton({required this.isFav, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: ValueKey(isFav),
            color: isFav ? AurumTheme.gold : Colors.white.withAlpha(128),
            size: 24,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pill
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPill extends StatelessWidget {
  final String label;
  const _QualityPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withAlpha(20), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withAlpha(88),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Options Sheet — JioSaavn / Echo Nightly style grid
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumOptionsSheet extends StatelessWidget {
  final Song song;
  final PlayerProvider player;
  final Color accentColor;

  const _PremiumOptionsSheet({
    required this.song,
    required this.player,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final actions = [
      _SheetAction(Icons.skip_next_rounded, 'Play Next', () {
        Navigator.pop(context);
        player.playNext(song);
      }),
      _SheetAction(Icons.queue_music_rounded, 'Add to Queue', () {
        Navigator.pop(context);
        player.addToQueue(song);
      }),
      _SheetAction(Icons.favorite_border_rounded, 'Like', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.share_rounded, 'Share', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.playlist_add_rounded, 'Save to Playlist', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.library_add_rounded, 'Save to Library', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.equalizer_rounded, 'Audio Effects', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.timer_outlined, 'Sleep Timer', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.info_outline_rounded, 'Song Info', () {
        Navigator.pop(context);
      }),
      _SheetAction(Icons.radio_rounded, 'Go to Radio', () {
        Navigator.pop(context);
      }),
    ];

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: Color.lerp(accentColor, const Color(0xFF0C0C18), 0.55)!
                .withAlpha(245),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(color: Colors.white.withAlpha(14), width: 0.5),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(40),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Song header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AurumArtwork(
                          url: song.artworkUrl, size: 52, borderRadius: 10),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            song.artist,
                            style: TextStyle(
                              color: Colors.white.withAlpha(120),
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 16),
                  child: Divider(
                    color: Colors.white.withAlpha(14),
                    height: 1,
                  ),
                ),
                // Action grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 2.6,
                    ),
                    itemCount: actions.length,
                    itemBuilder: (_, i) => _SheetActionTile(
                      action: actions[i],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SheetAction(this.icon, this.label, this.onTap);
}

class _SheetActionTile extends StatefulWidget {
  final _SheetAction action;
  const _SheetActionTile({required this.action});

  @override
  State<_SheetActionTile> createState() => _SheetActionTileState();
}

class _SheetActionTileState extends State<_SheetActionTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.selectionClick();
        widget.action.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: _pressed
              ? Colors.white.withAlpha(22)
              : Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withAlpha(_pressed ? 22 : 12),
            width: 0.5,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        child: Row(
          children: [
            Icon(widget.action.icon,
                size: 18, color: Colors.white.withAlpha(200)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.action.label,
                style: TextStyle(
                  color: Colors.white.withAlpha(220),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Content Panel — Queue / Lyrics / Info
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumContentPanel extends StatefulWidget {
  final Color bg1, bg2, bg3;
  const _PremiumContentPanel(
      {required this.bg1, required this.bg2, required this.bg3});

  @override
  State<_PremiumContentPanel> createState() => _PremiumContentPanelState();
}

class _PremiumContentPanelState extends State<_PremiumContentPanel>
    with TickerProviderStateMixin {
  int _activeTab = 0;
  double _dragY = 0;

  late final AnimationController _tabCtrl;
  late final Animation<double> _tabFade;

  @override
  void initState() {
    super.initState();
    _tabCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _tabFade = CurvedAnimation(parent: _tabCtrl, curve: Curves.easeOut);
    _tabCtrl.forward();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  void _switchTab(int idx) {
    if (idx == _activeTab) return;
    HapticFeedback.selectionClick();
    _tabCtrl.reverse().then((_) {
      if (!mounted) return;
      setState(() => _activeTab = idx);
      _tabCtrl.forward();
    });
  }

  void _dismiss() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final dragFraction = (_dragY / screenH).clamp(0.0, 1.0);
    final opacity = (1.0 - dragFraction * 2.5).clamp(0.0, 1.0);
    final scale = (1.0 - dragFraction * 0.06).clamp(0.88, 1.0);

    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 0) setState(() => _dragY += d.delta.dy);
      },
      onVerticalDragEnd: (d) {
        if (_dragY > 90 || (d.primaryVelocity ?? 0) > 600) {
          _dismiss();
        } else {
          setState(() => _dragY = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(0, _dragY.clamp(0.0, screenH * 0.5)),
        child: Transform.scale(
          scale: scale,
          alignment: Alignment.topCenter,
          child: Opacity(
            opacity: opacity,
            child: SizedBox(
              height: screenH * 0.95,
              child: ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(32)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(32)),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.lerp(widget.bg1, const Color(0xFF0A0A16), 0.5)!
                              .withAlpha(247),
                          Color.lerp(widget.bg2, const Color(0xFF060610), 0.5)!
                              .withAlpha(248),
                          Color.lerp(widget.bg3, const Color(0xFF020206), 0.6)!
                              .withAlpha(250),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                      border: Border(
                        top: BorderSide(
                            color: Colors.white.withAlpha(18), width: 0.5),
                      ),
                    ),
                    child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 6),
                        child: Container(
                          width: 32,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(40),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Expanded(
                        child: FadeTransition(
                          opacity: _tabFade,
                          child: _buildTabContent(),
                        ),
                      ),
                      _buildTabBar(),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_activeTab) {
      case 0:
        return const _QueuePage();
      case 1:
        return const _LyricsPage();
      case 2:
        return const _InfoPage();
      default:
        return const _QueuePage();
    }
  }

  Widget _buildTabBar() {
    const tabs = [
      (Icons.queue_music_rounded, 'Queue'),
      (Icons.lyrics_rounded, 'Lyrics'),
      (Icons.info_outline_rounded, 'Info'),
    ];

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(color: Colors.white.withAlpha(14), height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: List.generate(tabs.length, (i) {
                final isActive = _activeTab == i;
                return Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _switchTab(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tabs[i].$1,
                            size: 20,
                            color: isActive
                                ? AurumTheme.gold
                                : Colors.white.withAlpha(80),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tabs[i].$2,
                            style: TextStyle(
                              color: isActive
                                  ? AurumTheme.gold
                                  : Colors.white.withAlpha(70),
                              fontSize: 11,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: isActive ? 18 : 0,
                            height: 2,
                            decoration: BoxDecoration(
                              color: AurumTheme.gold,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Page — Echo Nightly style
// ─────────────────────────────────────────────────────────────────────────────
class _QueuePage extends StatelessWidget {
  const _QueuePage();

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final queue = player.queue;
        final current = player.currentIndex;

        if (queue.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.queue_music_rounded,
                    color: Colors.white.withAlpha(22), size: 56),
                const SizedBox(height: 16),
                Text(
                  'Queue is empty',
                  style: TextStyle(
                    color: Colors.white.withAlpha(60),
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        }

        // Separate now playing from up next
        final upNext = <int>[];
        for (int i = 0; i < queue.length; i++) {
          if (i != current) upNext.add(i);
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Now Playing header
            if (current != null && current < queue.length)
              SliverToBoxAdapter(
                child: _NowPlayingHeader(song: queue[current]),
              ),
            // Up Next label
            if (upNext.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Text(
                    'UP NEXT',
                    style: TextStyle(
                      color: Colors.white.withAlpha(60),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
              ),
            // Up next list
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, listIdx) {
                    final queueIdx = upNext[listIdx];
                    return _QueueTile(
                      key: ValueKey('${queue[queueIdx].id}_$queueIdx'),
                      song: queue[queueIdx],
                      isCurrent: false,
                      index: listIdx + 1,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        player.skipToIndex(queueIdx);
                      },
                      onRemove: () {
                        HapticFeedback.mediumImpact();
                        player.removeFromQueue(queueIdx);
                      },
                    );
                  },
                  childCount: upNext.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Header — large card at top of queue
// ─────────────────────────────────────────────────────────────────────────────
class _NowPlayingHeader extends StatelessWidget {
  final Song song;
  const _NowPlayingHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AurumTheme.gold.withAlpha(18),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: AurumTheme.gold.withAlpha(40),
            width: 0.5,
          ),
        ),
        child: Row(children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AurumArtwork(
                    url: song.artworkUrl, size: 54, borderRadius: 12),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AurumTheme.gold,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Center(
                    child: _MiniEqualizerIcon(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: AurumTheme.gold.withAlpha(200),
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.6,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: Colors.white.withAlpha(110),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini Equalizer Icon — for now playing badge
// ─────────────────────────────────────────────────────────────────────────────
class _MiniEqualizerIcon extends StatefulWidget {
  const _MiniEqualizerIcon();

  @override
  State<_MiniEqualizerIcon> createState() => _MiniEqualizerIconState();
}

class _MiniEqualizerIconState extends State<_MiniEqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final v = _ctrl.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar(0.4 + 0.6 * v, 7),
            const SizedBox(width: 1),
            _bar(0.9 - 0.5 * v, 7),
            const SizedBox(width: 1),
            _bar(0.6 + 0.4 * v, 7),
          ],
        );
      },
    );
  }

  Widget _bar(double f, double maxH) => Container(
        width: 2,
        height: maxH * f,
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          borderRadius: BorderRadius.circular(1),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Tile — Echo Nightly style with swipe-to-remove
// ─────────────────────────────────────────────────────────────────────────────
class _QueueTile extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueTile({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.index,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_QueueTile> createState() => _QueueTileState();
}

class _QueueTileState extends State<_QueueTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swipeCtrl;
  late Animation<double> _settleAnim;
  double _dragOffset = 0;
  bool _swiped = false;

  @override
  void initState() {
    super.initState();
    _swipeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _settleAnim = AlwaysStoppedAnimation(0.0);
  }

  @override
  void dispose() {
    _swipeCtrl.dispose();
    super.dispose();
  }

  void _handleSwipeEnd() {
    if (_dragOffset.abs() > 60) {
      HapticFeedback.heavyImpact();
      _swiped = true;
      _swipeCtrl.forward().then((_) {
        if (mounted) widget.onRemove();
      });
    } else {
      final fromOffset = _dragOffset;
      _settleAnim = Tween<double>(begin: fromOffset, end: 0.0).animate(
        CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
      );
      _swipeCtrl.forward(from: 0.0).then((_) {
        if (mounted) setState(() => _dragOffset = 0);
        _swipeCtrl.reset();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_swiped) return const SizedBox.shrink();

    return GestureDetector(
      onTap: widget.onTap,
      onHorizontalDragUpdate: (d) {
        _swipeCtrl.stop();
        setState(() {
          _dragOffset += d.delta.dx;
          _dragOffset = _dragOffset.clamp(-120.0, 0.0);
        });
      },
      onHorizontalDragEnd: (_) => _handleSwipeEnd(),
      child: AnimatedBuilder(
        animation: _swipeCtrl,
        builder: (_, child) {
          final offset = _swiped
              ? _dragOffset
              : (_swipeCtrl.isAnimating && _dragOffset == 0)
                  ? _settleAnim.value
                  : _dragOffset;
          return Transform.translate(
            offset: Offset(offset, 0),
            child: child,
          );
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(7),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withAlpha(10),
              width: 0.5,
            ),
          ),
          child: Row(children: [
            // Index number
            SizedBox(
              width: 22,
              child: Text(
                '${widget.index}',
                style: TextStyle(
                  color: Colors.white.withAlpha(45),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AurumArtwork(
                  url: widget.song.artworkUrl, size: 44, borderRadius: 10),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.song.title,
                    style: TextStyle(
                      color: Colors.white.withAlpha(220),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.song.artist,
                    style: TextStyle(
                      color: Colors.white.withAlpha(80),
                      fontSize: 11.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.drag_handle_rounded,
                color: Colors.white.withAlpha(40), size: 18),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics Page
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPage extends StatefulWidget {
  const _LyricsPage();

  @override
  State<_LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<_LyricsPage> {
  String? _lyrics;
  bool _loading = true;
  bool _notFound = false;
  Song? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _loadedFor?.id) {
      _loadedFor = song;
      _fetchLyrics(song);
    }
  }

  Future<void> _fetchLyrics(Song song) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _notFound = false;
      _lyrics = null;
    });
    final lyrics = await context.read<PlayerProvider>().fetchLyrics();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (lyrics != null && lyrics.trim().isNotEmpty) {
        _lyrics = lyrics.trim();
      } else {
        _notFound = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_loading) {
      content = const Center(
        key: ValueKey('loading'),
        child: CircularProgressIndicator(
          color: Colors.white38,
          strokeWidth: 1.5,
        ),
      );
    } else if (_notFound) {
      content = Center(
        key: const ValueKey('not-found'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lyrics_rounded,
                color: Colors.white.withAlpha(25), size: 52),
            const SizedBox(height: 16),
            Text(
              'No lyrics found',
              style: TextStyle(
                color: Colors.white.withAlpha(140),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Lyrics not available for this song',
              style: TextStyle(
                color: Colors.white.withAlpha(70),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    } else {
      content = SingleChildScrollView(
        key: const ValueKey('lyrics'),
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
        child: Text(
          _lyrics ?? '',
          style: TextStyle(
            color: Colors.white.withAlpha(200),
            fontSize: 15,
            height: 1.85,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.1,
          ),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: content,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info Page
// ─────────────────────────────────────────────────────────────────────────────
class _InfoPage extends StatelessWidget {
  const _InfoPage();

  @override
  Widget build(BuildContext context) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return const SizedBox.shrink();

    final rows = <_InfoRow>[];
    if (song.album.isNotEmpty) rows.add(_InfoRow('Album', song.album));
    if (song.artist.isNotEmpty) rows.add(_InfoRow('Artist', song.artist));
    if (song.year != null && song.year!.isNotEmpty) {
      rows.add(_InfoRow('Year', song.year!));
    }
    if (song.language != null && song.language!.isNotEmpty) {
      rows.add(_InfoRow('Language', song.language!));
    }
    if (song.duration != null) {
      rows.add(_InfoRow('Duration', song.durationString));
    }
    rows.add(_InfoRow('Source', song.isLocal ? 'Local Library' : 'Online Stream'));

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        _InfoHeader(song: song),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(7),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withAlpha(12), width: 0.5),
          ),
          child: Column(
            children: List.generate(rows.length, (i) {
              return Column(children: [
                _buildInfoRow(rows[i].label, rows[i].value),
                if (i < rows.length - 1)
                  Divider(
                    color: Colors.white.withAlpha(10),
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                  ),
              ]);
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withAlpha(70),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoHeader extends StatelessWidget {
  final Song song;
  const _InfoHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AurumArtwork(url: song.artworkUrl, size: 72, borderRadius: 14),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              song.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              song.artist,
              style: TextStyle(
                color: Colors.white.withAlpha(120),
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ]);
  }
}

class _InfoRow {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Background Layer — 3-color palette + breathing gradient
// AnimatedBuilder-driven, zero setState, isolated RepaintBoundary
// ─────────────────────────────────────────────────────────────────────────────
class _BgLayer extends StatelessWidget {
  final Song song;
  final AnimationController bgCtrl;
  final AnimationController breatheCtrl;
  final Color startBg1, startBg2, startBg3;
  final Color targetBg1, targetBg2, targetBg3;

  const _BgLayer({
    required this.song,
    required this.bgCtrl,
    required this.breatheCtrl,
    required this.startBg1,
    required this.startBg2,
    required this.startBg3,
    required this.targetBg1,
    required this.targetBg2,
    required this.targetBg3,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([bgCtrl, breatheCtrl]),
      builder: (_, __) {
        final t = bgCtrl.value;
        final b = CurvedAnimation(
          parent: breatheCtrl,
          curve: Curves.easeInOut,
        ).value;

        // Palette morph
        final bg1 = Color.lerp(startBg1, targetBg1, t)!;
        final bg2 = Color.lerp(startBg2, targetBg2, t)!;
        final bg3 = Color.lerp(startBg3, targetBg3, t)!;

        // Breathing: subtle gradient alignment shift + opacity pulse
        final breatheShift = b * 0.10;
        final topAlign = Alignment(-0.2 + breatheShift, -1.0);
        final botAlign = Alignment(0.2 - breatheShift, 1.0);

        // Artwork opacity breathes: 0.20 → 0.28
        final artOpacity = 0.20 + b * 0.08;

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: topAlign,
              end: botAlign,
              colors: [bg1, bg2, bg3, const Color(0xFF010103)],
              stops: const [0.0, 0.35, 0.68, 1.0],
            ),
          ),
          child: song.artworkUrl.isNotEmpty
              ? Stack(fit: StackFit.expand, children: [
                  Opacity(
                    opacity: artOpacity,
                    child: AurumArtwork(
                      url: song.artworkUrl,
                      size: double.infinity,
                      borderRadius: 0,
                    ),
                  ),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            bg1.withAlpha(82 + (b * 18).toInt()),
                            bg2.withAlpha(165),
                            const Color(0xFF010103).withAlpha(252),
                          ],
                          stops: const [0.0, 0.42, 1.0],
                        ),
                      ),
                    ),
                  ),
                ])
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Marquee Text
// ─────────────────────────────────────────────────────────────────────────────
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _overflowing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 10500));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final tp = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: double.infinity);

      final overflow = tp.width > constraints.maxWidth;

      if (overflow != _overflowing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _overflowing = overflow);
          if (overflow) {
            _ctrl.repeat();
          } else {
            _ctrl.stop();
            _ctrl.reset();
          }
        });
      }

      if (!overflow) {
        return Text(widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
      }

      return ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent
          ],
          stops: [0.0, 0.04, 0.92, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SizedBox(
          height: tp.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                final scrollAnim = CurvedAnimation(
                  parent: _ctrl,
                  curve: const Interval(0.0, 0.857, curve: Curves.linear),
                );
                final shift = -(tp.width + 40) * scrollAnim.value;
                return Stack(children: [
                  Positioned(
                      left: shift,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                  Positioned(
                      left: shift + tp.width + 40,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                ]);
              },
            ),
          ),
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered Track Shape
// ─────────────────────────────────────────────────────────────────────────────
class _BufferedTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);

    if (secondaryOffset != null) {
      final trackRect = getPreferredRect(
          parentBox: parentBox,
          offset: offset,
          sliderTheme: sliderTheme,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete);
      final paint = Paint()
        ..color = Colors.white.withAlpha(40)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
          trackRect.left, trackRect.top, secondaryOffset.dx, trackRect.bottom);
      context.canvas.drawRRect(
          RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
          paint);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Equalizer Icon — animated bars
// ─────────────────────────────────────────────────────────────────────────────
class _EqualizerIcon extends StatefulWidget {
  const _EqualizerIcon();

  @override
  State<_EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<_EqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final v = _ctrl.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(0.3 + 0.7 * v),
              _bar(0.8 - 0.6 * v),
              _bar(0.5 + 0.5 * v),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double f) => Container(
        width: 3.5,
        height: 18 * f,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Icon Button
// ─────────────────────────────────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final String? semanticLabel;

  const _IconBtn({
    required this.icon,
    required this.size,
    required this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: size, color: Colors.white.withAlpha(200)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control Button
// ─────────────────────────────────────────────────────────────────────────────
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool active;
  final Color? color;
  final String? semanticLabel;
  final VoidCallback onTap;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
    this.active = false,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? (active ? AurumTheme.gold : Colors.white.withAlpha(100));
    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: size, color: c),
        ),
      ),
    );
  }
}
