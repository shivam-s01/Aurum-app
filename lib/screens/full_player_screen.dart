import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FullPlayerScreen — production-grade premium music player
// ─────────────────────────────────────────────────────────────────────────────

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {

  // ── Animations ─────────────────────────────────────────────────────────────
  late final AnimationController _slideCtrl;
  late final Animation<Offset>   _slideAnim;

  late final AnimationController _pulseCtrl;
  late final Animation<double>   _pulseAnim;

  late final AnimationController _playBtnCtrl;
  late final Animation<double>   _playBtnAnim;

  // ── Tab & page ──────────────────────────────────────────────────────────────
  late final PageController _pageCtrl;
  int _tab = 0;

  // ── Drag to dismiss ─────────────────────────────────────────────────────────
  double _dragY = 0;

  // ── Dynamic bg colors ───────────────────────────────────────────────────────
  Color _bg1 = const Color(0xFF0D0D18);
  Color _bg2 = const Color(0xFF060608);
  String? _lastArtUrl;

  // ── Favourite state ─────────────────────────────────────────────────────────
  bool _isFav = false;

  @override
  void initState() {
    super.initState();

    // Slide up entry
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutQuart));
    _slideCtrl.forward();

    // Artwork breathing pulse
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.97, end: 1.0)
        .animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Play button press scale
    _playBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
    );
    _playBtnAnim = Tween<double>(begin: 1.0, end: 0.90)
        .animate(CurvedAnimation(parent: _playBtnCtrl, curve: Curves.easeIn));

    _pageCtrl = PageController();
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _pulseCtrl.dispose();
    _playBtnCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ── Color extraction ────────────────────────────────────────────────────────
  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtUrl) return;
    _lastArtUrl = url;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(80, 80),
      );
      final c = pg.vibrantColor?.color ??
          pg.dominantColor?.color ??
          pg.mutedColor?.color ??
          const Color(0xFF1A1630);
      if (!mounted) return;
      setState(() {
        _bg1 = Color.lerp(c, Colors.black, 0.42)!;
        _bg2 = Color.lerp(c, Colors.black, 0.80)!;
      });
    } catch (_) {}
  }

  // ── Close ───────────────────────────────────────────────────────────────────
  void _close() {
    HapticFeedback.lightImpact();
    _slideCtrl.reverse().then((_) {
      if (mounted) context.read<PlayerProvider>().closeFullPlayer();
    });
  }

  // ── Tab switch ──────────────────────────────────────────────────────────────
  void _switchTab(int i) {
    if (_tab == i) return;
    HapticFeedback.selectionClick();
    setState(() => _tab = i);
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // ── Play button tap ─────────────────────────────────────────────────────────
  Future<void> _onPlayTap(PlayerProvider player) async {
    HapticFeedback.heavyImpact();
    await _playBtnCtrl.forward();
    await _playBtnCtrl.reverse();
    player.togglePlay();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        if (song.artworkUrl.isNotEmpty) _extractColor(song.artworkUrl);

        return SlideTransition(
          position: _slideAnim,
          child: GestureDetector(
            onVerticalDragUpdate: (d) {
              if (d.delta.dy > 0) setState(() => _dragY += d.delta.dy);
            },
            onVerticalDragEnd: (d) {
              if (_dragY > 110 || (d.primaryVelocity ?? 0) > 650) {
                _close();
              } else {
                setState(() => _dragY = 0);
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragY.clamp(0.0, 240.0)),
              child: Opacity(
                opacity: (1.0 - (_dragY / 300).clamp(0.0, 0.4)),
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: Stack(
                    fit: StackFit.expand,
                    children: [
                      _BgLayer(
                        artworkUrl: song.artworkUrl,
                        bg1: _bg1,
                        bg2: _bg2,
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
        );
      },
    );
  }

  // ── Body layout ─────────────────────────────────────────────────────────────
  Widget _buildBody(BuildContext context, PlayerProvider player, Song song) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Responsive spacing based on screen height
        final h = constraints.maxHeight;
        final vGap = h < 680 ? 8.0 : 14.0;

        return Column(
          children: [
            _buildHandle(),
            _buildTopBar(song),
            SizedBox(height: vGap),
            _buildArtwork(song, player),
            SizedBox(height: vGap + 4),
            _buildSongInfo(song),
            SizedBox(height: vGap),
            _buildSeekBar(player),
            SizedBox(height: vGap + 2),
            _buildControls(player),
            SizedBox(height: vGap - 4),
            _buildAudioBadge(song),
            SizedBox(height: vGap - 2),
            Expanded(child: _buildTabSection(player, song)),
          ],
        );
      },
    );
  }

  // ── Drag handle ─────────────────────────────────────────────────────────────
  Widget _buildHandle() => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Container(
      width: 36, height: 4,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(64),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  // ── Top bar ─────────────────────────────────────────────────────────────────
  Widget _buildTopBar(Song song) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Row(
      children: [
        _Tap(
          onTap: _close,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.keyboard_arrow_down_rounded,
                size: 28, color: Colors.white.withAlpha(230)),
          ),
        ),
        Expanded(
          child: Column(children: [
            Text(
              'NOW PLAYING',
              style: TextStyle(
                color: Colors.white.withAlpha(100),
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.album.isNotEmpty ? song.album : 'Aurum Music',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ]),
        ),
        _Tap(
          onTap: () => _showOptions(context),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(Icons.more_vert_rounded,
                size: 22, color: Colors.white.withAlpha(210)),
          ),
        ),
      ],
    ),
  );

  // ── Artwork ─────────────────────────────────────────────────────────────────
  Widget _buildArtwork(Song song, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: AspectRatio(
        aspectRatio: 1.0,
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, child) => Transform.scale(
            scale: player.isPlaying ? _pulseAnim.value : 0.93,
            child: child,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: _bg1.withAlpha(200),
                  blurRadius: 48,
                  offset: const Offset(0, 18),
                  spreadRadius: 2,
                ),
                BoxShadow(
                  color: Colors.black.withAlpha(100),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: song.artworkUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: song.artworkUrl,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => _artPlaceholder(),
                      errorWidget: (_, __, ___) => _artPlaceholder(),
                    )
                  : _artPlaceholder(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _artPlaceholder() => Container(
    color: AurumTheme.darkBgElevated,
    child: Center(
      child: Icon(Icons.music_note_rounded,
          color: AurumTheme.gold.withAlpha(180), size: 80),
    ),
  );

  // ── Song info ────────────────────────────────────────────────────────────────
  Widget _buildSongInfo(Song song) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 26),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                song.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  letterSpacing: -0.4,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 5),
              Text(
                song.artist,
                style: TextStyle(
                  color: Colors.white.withAlpha(145),
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _Tap(
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _isFav = !_isFav);
          },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              _isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(_isFav),
              color: _isFav ? AurumTheme.gold : Colors.white.withAlpha(165),
              size: 26,
            ),
          ),
        ),
      ],
    ),
  );

  // ── Seekbar ──────────────────────────────────────────────────────────────────
  Widget _buildSeekBar(PlayerProvider player) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22),
    child: Column(
      children: [
        SizedBox(
          height: 20,
          child: SliderTheme(
            data: const SliderThemeData(
              trackHeight: 3,
              thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: Colors.white,
              inactiveTrackColor: Color(0x33FFFFFF),
              thumbColor: Colors.white,
              overlayColor: Color(0x1AFFFFFF),
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
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(player.positionString,
                  style: TextStyle(
                      color: Colors.white.withAlpha(115), fontSize: 11)),
              Text(player.durationString,
                  style: TextStyle(
                      color: Colors.white.withAlpha(115), fontSize: 11)),
            ],
          ),
        ),
      ],
    ),
  );

  // ── Controls ──────────────────────────────────────────────────────────────────
  Widget _buildControls(PlayerProvider player) {
    final isLoopOne = player.loopMode == LoopMode.one;
    final isLoopAll = player.loopMode == LoopMode.all;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Shuffle
          _CtrlBtn(
            icon: Icons.shuffle_rounded,
            size: 22,
            active: player.shuffle,
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleShuffle();
            },
          ),
          // Previous
          _CtrlBtn(
            icon: Icons.skip_previous_rounded,
            size: 40,
            color: Colors.white.withAlpha(230),
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipPrev();
            },
          ),
          // Play / Pause — animated
          ScaleTransition(
            scale: _playBtnAnim,
            child: _Tap(
              onTap: () => _onPlayTap(player),
              child: Container(
                width: 68, height: 68,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withAlpha(55),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: _bg1.withAlpha(120),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  transitionBuilder: (child, anim) =>
                      ScaleTransition(scale: anim, child: child),
                  child: Icon(
                    player.isLoading
                        ? Icons.hourglass_empty_rounded
                        : player.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                    key: ValueKey(player.isPlaying),
                    color: Colors.black,
                    size: 36,
                  ),
                ),
              ),
            ),
          ),
          // Next
          _CtrlBtn(
            icon: Icons.skip_next_rounded,
            size: 40,
            color: Colors.white.withAlpha(230),
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipNext();
            },
          ),
          // Repeat
          _CtrlBtn(
            icon: isLoopOne
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            size: 22,
            active: isLoopAll || isLoopOne,
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleLoop();
            },
          ),
        ],
      ),
    );
  }

  // ── Audio quality badge ───────────────────────────────────────────────────────
  Widget _buildAudioBadge(Song song) {
    final parts = <String>[];
    if (song.isLocal) parts.add('LOCAL');
    if (song.language != null && song.language!.isNotEmpty)
      parts.add(song.language!.toUpperCase());
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) parts.add('STREAM');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: Colors.white.withAlpha(25), width: 0.5),
      ),
      child: Text(
        parts.join(' · '),
        style: TextStyle(
          color: Colors.white.withAlpha(100),
          fontSize: 10.5,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ── Tab section ────────────────────────────────────────────────────────────────
  Widget _buildTabSection(PlayerProvider player, Song song) {
    return Column(
      children: [
        // Pill segmented control
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(18),
              borderRadius: BorderRadius.circular(19),
              border: Border.all(
                  color: Colors.white.withAlpha(20), width: 0.5),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Row(
                children: List.generate(3, (i) {
                  final labels = ['Up Next', 'Lyrics', 'Info'];
                  final active = _tab == i;
                  return Expanded(
                    child: _Tap(
                      onTap: () => _switchTab(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 230),
                        curve: Curves.easeInOut,
                        decoration: BoxDecoration(
                          color: active
                              ? Colors.white.withAlpha(38)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            color: active
                                ? Colors.white
                                : Colors.white.withAlpha(95),
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Swipeable content
        Expanded(
          child: PageView(
            controller: _pageCtrl,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (i) => setState(() => _tab = i),
            children: [
              _UpNextTab(player: player),
              _LyricsTab(),
              _InfoTab(song: song),
            ],
          ),
        ),
      ],
    );
  }

  // ── Options sheet ──────────────────────────────────────────────────────────────
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                  color: Colors.white.withAlpha(50),
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded,
                  color: Colors.white, size: 22),
              title: const Text('Add to Queue',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                player.addToQueue(song);
              },
            ),
            ListTile(
              leading: const Icon(Icons.skip_next_rounded,
                  color: Colors.white, size: 22),
              title: const Text('Play Next',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () {
                Navigator.pop(context);
                player.playNext(song);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded,
                  color: Colors.white, size: 22),
              title: const Text('Share',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background — separate StatefulWidget to avoid main rebuild on color change
// ─────────────────────────────────────────────────────────────────────────────

class _BgLayer extends StatelessWidget {
  final String artworkUrl;
  final Color bg1;
  final Color bg2;

  const _BgLayer({
    required this.artworkUrl,
    required this.bg1,
    required this.bg2,
  });

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
      child: artworkUrl.isNotEmpty
          ? Stack(fit: StackFit.expand, children: [
              CachedNetworkImage(
                imageUrl: artworkUrl,
                fit: BoxFit.cover,
                color: Colors.black.withAlpha(153),
                colorBlendMode: BlendMode.darken,
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 64, sigmaY: 64),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 700),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        bg1.withAlpha(115),
                        bg2.withAlpha(165),
                        const Color(0xFF020204).withAlpha(242),
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
// Up Next tab — reorderable queue
// ─────────────────────────────────────────────────────────────────────────────

class _UpNextTab extends StatelessWidget {
  final PlayerProvider player;
  const _UpNextTab({required this.player});

  @override
  Widget build(BuildContext context) {
    final queue = player.queue;
    final current = player.currentIndex;

    if (queue.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.queue_music_rounded,
              color: Colors.white.withAlpha(30), size: 48),
          const SizedBox(height: 12),
          Text('Queue is empty',
              style: TextStyle(
                  color: Colors.white.withAlpha(75), fontSize: 13)),
        ]),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
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
  }
}

class _QueueTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;

  const _QueueTile({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent
              ? Colors.white.withAlpha(18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: song.artworkUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: song.artworkUrl,
                      width: 46, height: 46,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 46, height: 46,
                      color: AurumTheme.darkBgElevated,
                      child: const Icon(Icons.music_note_rounded,
                          color: AurumTheme.gold, size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: TextStyle(
                      color: isCurrent
                          ? AurumTheme.gold
                          : Colors.white,
                      fontSize: 13,
                      fontWeight: isCurrent
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song.artist,
                    style: TextStyle(
                        color: Colors.white.withAlpha(95), fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (isCurrent)
              const _EqualizerIcon()
            else
              Icon(Icons.drag_handle_rounded,
                  color: Colors.white.withAlpha(60), size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Equalizer bars animation ────────────────────────────────────────────────

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
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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

  Widget _bar(double fraction) => Container(
    width: 4,
    height: 18 * fraction,
    decoration: BoxDecoration(
      color: AurumTheme.gold,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics tab
// ─────────────────────────────────────────────────────────────────────────────

class _LyricsTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.lyrics_rounded,
            color: Colors.white.withAlpha(25), size: 52),
        const SizedBox(height: 14),
        Text(
          'Lyrics coming soon',
          style: TextStyle(
              color: Colors.white.withAlpha(75),
              fontSize: 14,
              fontWeight: FontWeight.w400),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info tab
// ─────────────────────────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  final Song song;
  const _InfoTab({required this.song});

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[];
    if (song.album.isNotEmpty) rows.add(MapEntry('Album', song.album));
    if (song.artist.isNotEmpty) rows.add(MapEntry('Artist', song.artist));
    if (song.year != null && song.year!.isNotEmpty)
      rows.add(MapEntry('Year', song.year!));
    if (song.language != null && song.language!.isNotEmpty)
      rows.add(MapEntry('Language', song.language!));
    if (song.duration != null)
      rows.add(MapEntry('Duration', song.durationString));
    rows.add(MapEntry('Source',
        song.isLocal ? 'Local Library' : 'Online Stream'));

    return ListView(
      padding: const EdgeInsets.fromLTRB(26, 14, 26, 24),
      physics: const BouncingScrollPhysics(),
      children: rows.map((e) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 76,
            child: Text(e.key,
                style: TextStyle(
                    color: Colors.white.withAlpha(88),
                    fontSize: 12,
                    fontWeight: FontWeight.w400)),
          ),
          Expanded(
            child: Text(e.value,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
        ]),
      )).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered track shape for seekbar
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
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context, offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    // Draw buffered region
    if (secondaryOffset != null) {
      final trackRect = getPreferredRect(
          parentBox: parentBox,
          offset: offset,
          sliderTheme: sliderTheme,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete);
      final paint = Paint()
        ..color = Colors.white.withAlpha(50)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
        thumbCenter.dx,
        trackRect.top,
        secondaryOffset.dx,
        trackRect.bottom,
      );
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
        paint,
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper widgets
// ─────────────────────────────────────────────────────────────────────────────

/// Tap target with no InkWell flicker
class _Tap extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _Tap({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) =>
      GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child);
}

/// Control icon button
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool active;
  final Color? color;
  final VoidCallback onTap;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
    this.active = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? (active ? AurumTheme.gold : Colors.white.withAlpha(115));
    return _Tap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: size, color: c),
      ),
    );
  }
}
