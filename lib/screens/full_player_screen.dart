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
// FullPlayerScreen v3 — Clean flagship player
// Main player: artwork + controls only.
// Queue / Lyrics / Info open as premium spring-animated modal sheets.
// ─────────────────────────────────────────────────────────────────────────────

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {

  // ── Entry slide animation ──
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;

  // ── Artwork pulse ──
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  // ── Play button tap bounce ──
  late final AnimationController _playBtnCtrl;
  late final Animation<double> _playBtnAnim;

  // ── Swipe-down drag tracking ──
  double _dragY = 0;
  bool _isDragging = false;

  // ── Background palette ──
  Color _bg1 = const Color(0xFF0D0D18);
  Color _bg2 = const Color(0xFF060608);
  String? _lastArtUrl;

  // ── Favourite state (local toggle for now) ──
  bool _isFav = false;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideCtrl.forward();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.965, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _playBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _playBtnAnim = Tween<double>(begin: 1.0, end: 0.88)
        .animate(CurvedAnimation(parent: _playBtnCtrl, curve: Curves.easeIn));
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _pulseCtrl.dispose();
    _playBtnCtrl.dispose();
    super.dispose();
  }

  // ── Palette extraction ──────────────────────────────────────────────────
  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtUrl) return;
    _lastArtUrl = url;
    try {
      ImageProvider provider;
      if (url.startsWith('http')) {
        provider = CachedNetworkImageProvider(url);
      } else {
        return;
      }
      final pg = await PaletteGenerator.fromImageProvider(
        provider, size: const Size(80, 80));
      final c = pg.vibrantColor?.color
          ?? pg.dominantColor?.color
          ?? pg.mutedColor?.color
          ?? const Color(0xFF1A1630);
      if (!mounted) return;
      setState(() {
        _bg1 = Color.lerp(c, Colors.black, 0.42)!;
        _bg2 = Color.lerp(c, Colors.black, 0.80)!;
      });
    } catch (_) {}
  }

  // ── Dismiss ─────────────────────────────────────────────────────────────
  void _close() {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    _slideCtrl.reverse().then((_) {
      if (mounted) context.read<PlayerProvider>().closeFullPlayer();
    });
  }

  // ── Play button tap ─────────────────────────────────────────────────────
  Future<void> _onPlayTap(PlayerProvider player) async {
    HapticFeedback.heavyImpact();
    await _playBtnCtrl.forward();
    await _playBtnCtrl.reverse();
    player.togglePlay();
  }

  // ── Open modal sheets ───────────────────────────────────────────────────
  void _openSheet(_SheetType type) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.55),
      useSafeArea: false,
      builder: (_) {
        switch (type) {
          case _SheetType.queue:
            return _QueueSheet(bg1: _bg1);
          case _SheetType.lyrics:
            return _LyricsSheet(bg1: _bg1, bg2: _bg2);
          case _SheetType.info:
            final song = context.read<PlayerProvider>().currentSong;
            return _InfoSheet(song: song!, bg1: _bg1, bg2: _bg2);
        }
      },
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        if (song.artworkUrl.isNotEmpty) _extractColor(song.artworkUrl);

        final dragOpacity = (1.0 - (_dragY / 280).clamp(0.0, 0.45));
        final dragScale = (1.0 - (_dragY / 1800).clamp(0.0, 0.06));

        return SlideTransition(
          position: _slideAnim,
          child: GestureDetector(
            onVerticalDragStart: (_) => setState(() => _isDragging = true),
            onVerticalDragUpdate: (d) {
              if (d.delta.dy > 0) {
                setState(() => _dragY += d.delta.dy);
              }
            },
            onVerticalDragEnd: (d) {
              setState(() => _isDragging = false);
              if (_dragY > 120 || (d.primaryVelocity ?? 0) > 700) {
                _close();
              } else {
                setState(() => _dragY = 0);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragY.clamp(0.0, 260.0)),
              child: Transform.scale(
                scale: dragScale,
                child: Opacity(
                  opacity: dragOpacity,
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: Stack(
                      fit: StackFit.expand,
                      children: [
                        _BgLayer(song: song, bg1: _bg1, bg2: _bg2),
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
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, PlayerProvider player, Song song) {
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final w = constraints.maxWidth;
      final compact = h < 650;
      final vGap = compact ? 10.0 : 18.0;
      final artPad = w > 600 ? w * 0.18 : 32.0;

      return Column(
        children: [
          _buildHandle(),
          _buildTopBar(song),
          SizedBox(height: vGap),
          _buildArtwork(song, player, artPad),
          SizedBox(height: vGap + 4),
          _buildSongInfo(song, w),
          SizedBox(height: vGap),
          _buildSeekBar(player),
          SizedBox(height: vGap + 2),
          _buildControls(player),
          SizedBox(height: compact ? 6 : 10),
          _buildAudioBadge(song),
          const Spacer(),
          _buildBottomPill(),
        ],
      );
    });
  }

  // ── Handle ───────────────────────────────────────────────────────────────
  Widget _buildHandle() => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Container(
      width: 36, height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(55),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  // ── Top bar ──────────────────────────────────────────────────────────────
  Widget _buildTopBar(Song song) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(children: [
      _Tap(
        onTap: _close,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.keyboard_arrow_down_rounded,
              size: 28, color: Colors.white.withAlpha(220)),
        ),
      ),
      Expanded(
        child: Column(children: [
          Text('NOW PLAYING',
              style: TextStyle(
                color: Colors.white.withAlpha(90),
                fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.8)),
          const SizedBox(height: 3),
          Text(
            song.album.isNotEmpty ? song.album : 'Aurum Music',
            style: const TextStyle(
                color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ]),
      ),
      _Tap(
        onTap: () => _showOptions(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(Icons.more_vert_rounded,
              size: 22, color: Colors.white.withAlpha(200)),
        ),
      ),
    ]),
  );

  // ── Artwork ──────────────────────────────────────────────────────────────
  Widget _buildArtwork(Song song, PlayerProvider player, double hPad) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, child) => Transform.scale(
            scale: player.isPlaying ? _pulseAnim.value : 0.93,
            child: child,
          ),
          child: Hero(
            tag: 'aurum_artwork',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: _bg1.withAlpha(200),
                    blurRadius: 56,
                    offset: const Offset(0, 22),
                    spreadRadius: 2,
                  ),
                  BoxShadow(
                    color: Colors.black.withAlpha(110),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AurumArtwork(
                  url: song.artworkUrl,
                  size: double.infinity,
                  borderRadius: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Song info ────────────────────────────────────────────────────────────
  Widget _buildSongInfo(Song song, double w) {
    final titleSize = w > 600 ? 24.0 : 21.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _MarqueeText(
              text: song.title,
              style: TextStyle(
                color: Colors.white,
                fontSize: titleSize,
                fontWeight: FontWeight.w700,
                height: 1.2, letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              song.artist,
              style: TextStyle(color: Colors.white.withAlpha(145), fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        const SizedBox(width: 16),
        _Tap(
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _isFav = !_isFav);
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              _isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(_isFav),
              color: _isFav ? AurumTheme.gold : Colors.white.withAlpha(160),
              size: 26,
            ),
          ),
        ),
      ]),
    );
  }

  // ── Seek bar ─────────────────────────────────────────────────────────────
  Widget _buildSeekBar(PlayerProvider player) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(children: [
      SizedBox(
        height: 24,
        child: SliderTheme(
          data: const SliderThemeData(
            trackHeight: 3,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor: Colors.white,
            inactiveTrackColor: Color(0x33FFFFFF),
            thumbColor: Colors.white,
            overlayColor: Color(0x18FFFFFF),
            trackShape: _BufferedTrackShape(),
          ),
          child: Slider(
            value: player.progress,
            secondaryTrackValue: player.duration.inMilliseconds > 0
                ? (player.buffered.inMilliseconds /
                        player.duration.inMilliseconds)
                    .clamp(0.0, 1.0)
                : 0.0,
            onChangeStart: (_) => HapticFeedback.selectionClick(),
            onChanged: player.seek,
            onChangeEnd: (_) => HapticFeedback.selectionClick(),
          ),
        ),
      ),
      const SizedBox(height: 2),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(player.positionString,
              style: TextStyle(color: Colors.white.withAlpha(110), fontSize: 11)),
          Text(player.durationString,
              style: TextStyle(color: Colors.white.withAlpha(110), fontSize: 11)),
        ]),
      ),
    ]),
  );

  // ── Controls ─────────────────────────────────────────────────────────────
  Widget _buildControls(PlayerProvider player) {
    final isLoopOne = player.loopMode == LoopMode.one;
    final isLoopAll = player.loopMode == LoopMode.all;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CtrlBtn(
            icon: Icons.shuffle_rounded, size: 22,
            active: player.shuffle, semanticLabel: 'Shuffle',
            onTap: () { HapticFeedback.selectionClick(); player.toggleShuffle(); },
          ),
          _CtrlBtn(
            icon: Icons.skip_previous_rounded, size: 40,
            color: Colors.white.withAlpha(220), semanticLabel: 'Previous',
            onTap: () { HapticFeedback.mediumImpact(); player.skipPrev(); },
          ),
          ScaleTransition(
            scale: _playBtnAnim,
            child: _Tap(
              onTap: () => _onPlayTap(player),
              child: Semantics(
                label: player.isPlaying ? 'Pause' : 'Play',
                child: Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: Colors.white.withAlpha(50),
                          blurRadius: 28, spreadRadius: 2),
                      BoxShadow(color: _bg1.withAlpha(140),
                          blurRadius: 20, offset: const Offset(0, 7)),
                    ],
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim,
                            child: FadeTransition(opacity: anim, child: child)),
                    child: Icon(
                      player.isLoading
                          ? Icons.hourglass_empty_rounded
                          : player.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                      key: ValueKey('${player.isPlaying}-${player.isLoading}'),
                      color: Colors.black, size: 38,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _CtrlBtn(
            icon: Icons.skip_next_rounded, size: 40,
            color: Colors.white.withAlpha(220), semanticLabel: 'Next',
            onTap: () { HapticFeedback.mediumImpact(); player.skipNext(); },
          ),
          _CtrlBtn(
            icon: isLoopOne ? Icons.repeat_one_rounded : Icons.repeat_rounded,
            size: 22, active: isLoopAll || isLoopOne, semanticLabel: 'Repeat',
            onTap: () { HapticFeedback.selectionClick(); player.toggleLoop(); },
          ),
        ],
      ),
    );
  }

  // ── Audio badge ──────────────────────────────────────────────────────────
  Widget _buildAudioBadge(Song song) {
    final parts = <String>[];
    if (song.isLocal) parts.add('LOCAL');
    if (song.language != null && song.language!.isNotEmpty)
      parts.add(song.language!.toUpperCase());
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) return const SizedBox(height: 1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(22), width: 0.5),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(
          color: Colors.white.withAlpha(95),
          fontSize: 10.5, letterSpacing: 0.8, fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ── Bottom pill ──────────────────────────────────────────────────────────
  Widget _buildBottomPill() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // subtle top divider
      Divider(color: Colors.white.withAlpha(18), height: 1),
      // flat tab row — exactly like screenshot
      Row(
        children: [
          _BottomTab(
            label: 'Up Next',
            onTap: () => _openSheet(_SheetType.queue),
          ),
          _BottomTab(
            label: 'Lyrics',
            onTap: () => _openSheet(_SheetType.lyrics),
          ),
          _BottomTab(
            label: 'Info',
            onTap: () => _openSheet(_SheetType.info),
          ),
        ],
      ),
    ]);
  }

  // ── Options menu ─────────────────────────────────────────────────────────
  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F0F1A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded,
                color: Colors.white, size: 22),
            title: const Text('Add to Queue',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            onTap: () { Navigator.pop(context); player.addToQueue(song); },
          ),
          ListTile(
            leading: const Icon(Icons.skip_next_rounded,
                color: Colors.white, size: 22),
            title: const Text('Play Next',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            onTap: () { Navigator.pop(context); player.playNext(song); },
          ),
          ListTile(
            leading: const Icon(Icons.share_rounded,
                color: Colors.white, size: 22),
            title: const Text('Share',
                style: TextStyle(color: Colors.white, fontSize: 14)),
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet type enum
// ─────────────────────────────────────────────────────────────────────────────
enum _SheetType { queue, lyrics, info }

// ─────────────────────────────────────────────────────────────────────────────
// Pill button + divider
// ─────────────────────────────────────────────────────────────────────────────
// Flat bottom tab — exactly like screenshot (Up Next / Lyrics / Info)
class _BottomTab extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _BottomTab({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: _Tap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withAlpha(170),
              fontSize: 13,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base sheet — shared drag-dismiss + blurred glass scaffold
// ─────────────────────────────────────────────────────────────────────────────
class _BaseSheet extends StatefulWidget {
  final Color bg1;
  final Color bg2;
  final String title;
  final IconData titleIcon;
  final Widget child;

  const _BaseSheet({
    required this.bg1,
    required this.bg2,
    required this.title,
    required this.titleIcon,
    required this.child,
  });

  @override
  State<_BaseSheet> createState() => _BaseSheetState();
}

class _BaseSheetState extends State<_BaseSheet>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;

  void _dismiss() {
    Navigator.of(context).pop();
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final dragFraction = (_dragY / screenH).clamp(0.0, 1.0);
    final opacity = (1.0 - dragFraction * 2.2).clamp(0.0, 1.0);
    final scale = (1.0 - dragFraction * 0.08).clamp(0.88, 1.0);

    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy > 0) setState(() => _dragY += d.delta.dy);
      },
      onVerticalDragEnd: (d) {
        if (_dragY > 100 || (d.primaryVelocity ?? 0) > 600) {
          _dismiss();
        } else {
          setState(() => _dragY = 0);
        }
      },
      child: Transform.translate(
        offset: Offset(0, _dragY.clamp(0.0, screenH * 0.45)),
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                child: Container(
                  height: screenH * 0.88,
                  decoration: BoxDecoration(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(28)),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(widget.bg1, const Color(0xFF0A0A14), 0.55)!
                            .withOpacity(0.97),
                        Color.lerp(widget.bg2, const Color(0xFF020206), 0.6)!
                            .withOpacity(0.98),
                      ],
                    ),
                    border: Border(
                      top: BorderSide(
                          color: Colors.white.withOpacity(0.08), width: 0.5),
                    ),
                  ),
                  child: Column(children: [
                    // Handle
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Container(
                        width: 36, height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(50),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    // Sheet header
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      child: Row(children: [
                        Icon(widget.titleIcon,
                            color: AurumTheme.gold, size: 18),
                        const SizedBox(width: 10),
                        Text(widget.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            )),
                        const Spacer(),
                        _Tap(
                          onTap: _dismiss,
                          child: Container(
                            width: 30, height: 30,
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(18),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.close_rounded,
                                color: Colors.white.withAlpha(170), size: 16),
                          ),
                        ),
                      ]),
                    ),
                    Divider(color: Colors.white.withAlpha(18), height: 1),
                    Expanded(child: widget.child),
                  ]),
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
// Queue Sheet
// ─────────────────────────────────────────────────────────────────────────────
class _QueueSheet extends StatelessWidget {
  final Color bg1;
  const _QueueSheet({required this.bg1});

  @override
  Widget build(BuildContext context) {
    return _BaseSheet(
      bg1: bg1,
      bg2: const Color(0xFF060608),
      title: 'Up Next',
      titleIcon: Icons.queue_music_rounded,
      child: Consumer<PlayerProvider>(
        builder: (context, player, _) {
          final queue = player.queue;
          final current = player.currentIndex;

          if (queue.isEmpty) {
            return Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                Icon(Icons.queue_music_rounded,
                    color: Colors.white.withAlpha(28), size: 52),
                const SizedBox(height: 14),
                Text('Queue is empty',
                    style: TextStyle(
                        color: Colors.white.withAlpha(70), fontSize: 14)),
              ]),
            );
          }

          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            physics: const BouncingScrollPhysics(),
            itemCount: queue.length,
            onReorder: (from, to) {
              HapticFeedback.mediumImpact();
              player.moveQueueItem(from, to > from ? to - 1 : to);
            },
            itemBuilder: (_, i) {
              final s = queue[i];
              final isCurrent = i == current;
              return _QueueTile(
                key: ValueKey(s.id + i.toString()),
                song: s,
                isCurrent: isCurrent,
                onTap: () {
                  HapticFeedback.selectionClick();
                  player.skipToIndex(i);
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  const _QueueTile(
      {super.key,
      required this.song,
      required this.isCurrent,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: isCurrent ? AurumTheme.gold.withAlpha(22) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: isCurrent
              ? Border.all(color: AurumTheme.gold.withAlpha(40), width: 0.5)
              : null,
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: AurumArtwork(url: song.artworkUrl, size: 48, borderRadius: 9),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title,
                  style: TextStyle(
                    color: isCurrent ? AurumTheme.gold : Colors.white,
                    fontSize: 13.5,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Text(song.artist,
                  style: TextStyle(
                      color: Colors.white.withAlpha(90), fontSize: 11.5),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
          if (isCurrent)
            const _EqualizerIcon()
          else
            Icon(Icons.drag_handle_rounded,
                color: Colors.white.withAlpha(55), size: 18),
        ]),
      ),
    );
  }
}

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
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20, height: 18,
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
    width: 4, height: 18 * f,
    decoration: BoxDecoration(
      color: AurumTheme.gold,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics Sheet — Apple Music inspired
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsSheet extends StatelessWidget {
  final Color bg1;
  final Color bg2;
  const _LyricsSheet({required this.bg1, required this.bg2});

  @override
  Widget build(BuildContext context) {
    return _BaseSheet(
      bg1: bg1,
      bg2: bg2,
      title: 'Lyrics',
      titleIcon: Icons.lyrics_rounded,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(12),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withAlpha(20), width: 0.5),
                ),
                child: Icon(Icons.lyrics_rounded,
                    color: Colors.white.withAlpha(60), size: 28),
              ),
              const SizedBox(height: 20),
              Text('Lyrics Coming Soon',
                  style: TextStyle(
                    color: Colors.white.withAlpha(200),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 8),
              Text('Synced lyrics will display here\nwith real-time highlighting',
                  style: TextStyle(
                    color: Colors.white.withAlpha(70),
                    fontSize: 13,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info Sheet
// ─────────────────────────────────────────────────────────────────────────────
class _InfoSheet extends StatelessWidget {
  final Song song;
  final Color bg1;
  final Color bg2;
  const _InfoSheet(
      {required this.song, required this.bg1, required this.bg2});

  @override
  Widget build(BuildContext context) {
    final rows = <_InfoRow>[];
    if (song.album.isNotEmpty) rows.add(_InfoRow('Album', song.album));
    if (song.artist.isNotEmpty) rows.add(_InfoRow('Artist', song.artist));
    if (song.year != null && song.year!.isNotEmpty)
      rows.add(_InfoRow('Year', song.year!));
    if (song.language != null && song.language!.isNotEmpty)
      rows.add(_InfoRow('Language', song.language!));
    if (song.duration != null)
      rows.add(_InfoRow('Duration', song.durationString));
    rows.add(_InfoRow('Source', song.isLocal ? 'Local Library' : 'Online Stream'));

    return _BaseSheet(
      bg1: bg1,
      bg2: bg2,
      title: 'Song Info',
      titleIcon: Icons.info_outline_rounded,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        physics: const BouncingScrollPhysics(),
        children: [
          // Artwork card
          Center(
            child: Container(
              width: 120, height: 120,
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: bg1.withAlpha(160),
                    blurRadius: 30,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AurumArtwork(
                    url: song.artworkUrl, size: 120, borderRadius: 16),
              ),
            ),
          ),
          // Info rows
          ...rows.map((r) => _buildRow(r.label, r.value)),
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 82,
          child: Text(label,
              style: TextStyle(
                  color: Colors.white.withAlpha(80), fontSize: 12.5)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              )),
        ),
      ]),
    );
  }
}

class _InfoRow {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Background — palette-driven gradient + blurred art
// ─────────────────────────────────────────────────────────────────────────────
class _BgLayer extends StatelessWidget {
  final Song song;
  final Color bg1;
  final Color bg2;
  const _BgLayer({required this.song, required this.bg1, required this.bg2});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bg1, bg2, const Color(0xFF020204)],
          stops: const [0.0, 0.48, 1.0],
        ),
      ),
      child: song.artworkUrl.isNotEmpty
          ? Stack(fit: StackFit.expand, children: [
              Opacity(
                opacity: 0.40,
                child: AurumArtwork(
                    url: song.artworkUrl,
                    size: double.infinity,
                    borderRadius: 0),
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 75, sigmaY: 75),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 700),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        bg1.withAlpha(105),
                        bg2.withAlpha(165),
                        const Color(0xFF020204).withAlpha(248),
                      ],
                      stops: const [0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ),
            ])
          : const SizedBox.shrink(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Marquee text
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
        vsync: this, duration: const Duration(seconds: 8));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

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
        _overflowing = overflow;
        if (overflow) {
          _ctrl.repeat();
        } else {
          _ctrl.stop();
          _ctrl.reset();
        }
      }

      if (!overflow) {
        return Text(widget.text,
            style: widget.style, maxLines: 1, overflow: TextOverflow.ellipsis);
      }

      return SizedBox(
        height: tp.height,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              final shift = -(tp.width + 40) * _ctrl.value;
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
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered slider track
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
        ..color = Colors.white.withAlpha(48)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
          thumbCenter.dx, trackRect.top, secondaryOffset.dx, trackRect.bottom);
      context.canvas.drawRRect(
          RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
          paint);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
class _Tap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Tap({required this.child, required this.onTap});
  @override
  Widget build(BuildContext context) =>
      GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child);
}

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
    final c = color ?? (active ? AurumTheme.gold : Colors.white.withAlpha(110));
    return Semantics(
      label: semanticLabel,
      button: true,
      child: _Tap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: size, color: c),
        ),
      ),
    );
  }
}
