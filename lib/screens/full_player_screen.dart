import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});
  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin {
  // Screen slide-up animation
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;

  // Artwork breathe animation
  late AnimationController _artCtrl;

  // Tab PageView
  late PageController _pageCtrl;
  late TabController _tabCtrl;

  Color _bgColor1 = const Color(0xFF1A0A00);
  Color _bgColor2 = const Color(0xFF0A0500);
  String? _lastUrl;

  // Swipe-to-close
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideCtrl.forward();

    _artCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
      lowerBound: 0.96,
      upperBound: 1.0,
    )..repeat(reverse: true);

    _tabCtrl = TabController(length: 3, vsync: this);
    _pageCtrl = PageController();

    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) return;
      _pageCtrl.animateToPage(
        _tabCtrl.index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _artCtrl.dispose();
    _tabCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  void _close() {
    _slideCtrl.reverse().then((_) {
      if (mounted) context.read<PlayerProvider>().closeFullPlayer();
    });
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastUrl || url.startsWith('content://')) return;
    _lastUrl = url;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(80, 80),
      );
      final c = pg.dominantColor?.color ??
          pg.vibrantColor?.color ??
          const Color(0xFF1A0A00);
      if (mounted) {
        setState(() {
          _bgColor1 = Color.lerp(c, Colors.black, 0.28)!;
          _bgColor2 = Color.lerp(c, Colors.black, 0.65)!;
        });
      }
    } catch (_) {}
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(builder: (context, player, _) {
      final song = player.currentSong;
      if (song == null) return const SizedBox.shrink();

      if (song.artworkUrl.isNotEmpty &&
          !song.artworkUrl.startsWith('content://')) {
        _extractColor(song.artworkUrl);
      }

      return SlideTransition(
        position: _slideAnim,
        child: Transform.translate(
          offset: Offset(0, _dragOffset.clamp(0.0, 200.0)),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              fit: StackFit.expand,
              children: [
                // ── Blurred background ──
                _buildBg(song),
                // ── Main layout ──
                SafeArea(
                  child: Column(
                    children: [
                      // Top bar — drag handle here only
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onVerticalDragUpdate: (d) {
                          if (d.delta.dy > 0 || _dragOffset > 0) {
                            setState(() {
                              _dragOffset =
                                  (_dragOffset + d.delta.dy).clamp(0.0, 300.0);
                            });
                          }
                        },
                        onVerticalDragEnd: (d) {
                          if (_dragOffset > 80 ||
                              (d.primaryVelocity ?? 0) > 500) {
                            _close();
                          } else {
                            setState(() => _dragOffset = 0);
                          }
                        },
                        child: _buildTopBar(song),
                      ),

                      // ── Artwork ──
                      const SizedBox(height: 4),
                      _buildArtwork(song, player.isPlaying),
                      const SizedBox(height: 16),

                      // ── Song info ──
                      _buildSongInfo(song),
                      const SizedBox(height: 10),

                      // ── Seek bar ──
                      _buildSeekBar(player),
                      const SizedBox(height: 14),

                      // ── Controls ──
                      _buildControls(player),
                      const SizedBox(height: 8),

                      // ── Audio strip ──
                      _buildAudioStrip(song),

                      // ── Tab content scrolls here ──
                      Expanded(
                        child: PageView(
                          controller: _pageCtrl,
                          physics: const BouncingScrollPhysics(),
                          onPageChanged: (i) {
                            _tabCtrl.animateTo(i);
                          },
                          children: [
                            _buildUpNext(player),
                            _buildLyrics(),
                            _buildInfo(song),
                          ],
                        ),
                      ),

                      // ── Tabs FIXED at bottom ──
                      _buildBottomTabBar(),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  // ── Background ────────────────────────────────────────────────────────────

  Widget _buildBg(Song song) {
    final hasArt = song.artworkUrl.isNotEmpty;
    final isLocal = song.artworkUrl.startsWith('content://');

    return Stack(fit: StackFit.expand, children: [
      // Gradient base
      AnimatedContainer(
        duration: const Duration(milliseconds: 700),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgColor1, _bgColor2, Colors.black],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
      // Artwork behind blur
      if (hasArt)
        isLocal
            ? SizedBox.expand(
                child: AurumArtwork(
                  url: song.artworkUrl,
                  size: MediaQuery.of(context).size.height,
                  borderRadius: 0,
                ),
              )
            : CachedNetworkImage(
                imageUrl: song.artworkUrl,
                fit: BoxFit.cover,
                color: Colors.black.withOpacity(0.42),
                colorBlendMode: BlendMode.darken,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
      // Blur + gradient overlay
      if (hasArt)
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 65, sigmaY: 65),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _bgColor1.withOpacity(0.42),
                  _bgColor2.withOpacity(0.62),
                  Colors.black.withOpacity(0.95),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
        ),
    ]);
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(children: [
        IconButton(
          onPressed: _close,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          color: Colors.white,
        ),
        Expanded(
          child: Column(children: [
            Text(
              'NOW PLAYING',
              style: TextStyle(
                color: Colors.white.withOpacity(0.38),
                fontSize: 10,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              song.album.isNotEmpty ? song.album : 'Aurum Music',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ]),
        ),
        IconButton(
          onPressed: () => _showOptions(context),
          icon: const Icon(Icons.more_vert_rounded, size: 24),
          color: Colors.white,
        ),
      ]),
    );
  }

  // ── Artwork ───────────────────────────────────────────────────────────────

  Widget _buildArtwork(Song song, bool isPlaying) {
    final size = MediaQuery.of(context).size.width - 52.0;
    return Center(
      child: AnimatedBuilder(
        animation: _artCtrl,
        builder: (_, child) => Transform.scale(
          scale: isPlaying ? _artCtrl.value : 0.91,
          child: child,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: _bgColor1.withOpacity(0.75),
                blurRadius: 44,
                offset: const Offset(0, 18),
                spreadRadius: 6,
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 22,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AurumArtwork(url: song.artworkUrl, size: size, borderRadius: 20),
          ),
        ),
      ),
    );
  }

  // ── Song info ─────────────────────────────────────────────────────────────

  Widget _buildSongInfo(Song song) {
    final fav = context.watch<FavoritesProvider>();
    final isLiked = fav.isFavorite(song.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              song.title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  height: 1.2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              song.artist,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 14,
                  fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ]),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: () => fav.toggleFavorite(song),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              key: ValueKey(isLiked),
              color: isLiked
                  ? const Color(0xFFE1306C)
                  : Colors.white.withOpacity(0.7),
              size: 26,
            ),
          ),
        ),
      ]),
    );
  }

  // ── Seek bar ──────────────────────────────────────────────────────────────

  Widget _buildSeekBar(PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withOpacity(0.18),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withOpacity(0.1),
          ),
          child: Slider(value: player.progress, onChanged: player.seek),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(player.positionString,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.42), fontSize: 12)),
              Text(player.durationString,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.42), fontSize: 12)),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControls(PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            onPressed: player.toggleShuffle,
            icon: Icon(Icons.shuffle_rounded,
                color: player.shuffle
                    ? AurumTheme.gold
                    : Colors.white.withOpacity(0.5),
                size: 22),
          ),
          IconButton(
            onPressed: player.skipPrev,
            icon: Icon(Icons.skip_previous_rounded,
                color: Colors.white.withOpacity(0.9), size: 38),
          ),
          GestureDetector(
            onTap: player.togglePlay,
            child: Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.2),
                    blurRadius: 18,
                    spreadRadius: 3,
                  ),
                ],
              ),
              child: Icon(
                player.isLoading
                    ? Icons.hourglass_empty_rounded
                    : player.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                color: Colors.black,
                size: 36,
              ),
            ),
          ),
          IconButton(
            onPressed: player.skipNext,
            icon: Icon(Icons.skip_next_rounded,
                color: Colors.white.withOpacity(0.9), size: 38),
          ),
          IconButton(
            onPressed: player.toggleLoop,
            icon: _repeatIcon(player),
          ),
        ],
      ),
    );
  }

  Widget _repeatIcon(PlayerProvider player) {
    switch (player.loopMode.toString()) {
      case 'LoopMode.one':
        return Icon(Icons.repeat_one_rounded, color: AurumTheme.gold, size: 22);
      case 'LoopMode.all':
        return Icon(Icons.repeat_rounded, color: AurumTheme.gold, size: 22);
      default:
        return Icon(Icons.repeat_rounded,
            color: Colors.white.withOpacity(0.5), size: 22);
    }
  }

  // ── Audio strip ───────────────────────────────────────────────────────────

  Widget _buildAudioStrip(Song song) {
    final parts = <String>[];
    if (song.isLocal) {
      final ext = (song.localPath ?? '').split('.').last.toUpperCase();
      parts.add(['M4A', 'AAC'].contains(ext) ? 'AAC' : ext.isEmpty ? 'LOCAL' : ext);
      parts.add(['FLAC', 'WAV'].contains(ext) ? 'LOSSLESS' : '48000 Hz');
    } else {
      parts.add('STREAM');
      if (song.language != null && song.language!.isNotEmpty) {
        parts.add(song.language!.toUpperCase());
      }
    }
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          parts.join('  •  '),
          style: TextStyle(
            color: Colors.white.withOpacity(0.38),
            fontSize: 11,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  // ── Bottom tab bar — FIXED at bottom ─────────────────────────────────────

  Widget _buildBottomTabBar() {
    final tabs = ['Up Next', 'Lyrics', 'Info'];
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.08), width: 0.5),
        ),
      ),
      child: TabBar(
        controller: _tabCtrl,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white.withOpacity(0.32),
        indicatorColor: Colors.white,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 1.5,
        labelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.3),
        unselectedLabelStyle: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w400),
        dividerColor: Colors.transparent,
        tabs: tabs.map((t) => Tab(text: t, height: 40)).toList(),
      ),
    );
  }

  // ── Up Next ───────────────────────────────────────────────────────────────

  Widget _buildUpNext(PlayerProvider player) {
    final queue = player.queue;
    final current = player.currentIndex;
    if (queue.isEmpty) {
      return Center(
        child: Text('Queue is empty',
            style: TextStyle(
                color: Colors.white.withOpacity(0.28), fontSize: 13)),
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      itemCount: queue.length,
      itemBuilder: (_, i) {
        final s = queue[i];
        final isCurrent = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: isCurrent
                ? Colors.white.withOpacity(0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            dense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AurumArtwork(url: s.artworkUrl, size: 44, borderRadius: 8),
            ),
            title: Text(
              s.title,
              style: TextStyle(
                color: isCurrent ? AurumTheme.gold : Colors.white,
                fontSize: 13,
                fontWeight:
                    isCurrent ? FontWeight.w600 : FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              s.artist,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.38), fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: isCurrent
                ? const Icon(Icons.equalizer_rounded,
                    color: AurumTheme.gold, size: 18)
                : null,
            onTap: () => player.skipToIndex(i),
          ),
        );
      },
    );
  }

  // ── Lyrics ────────────────────────────────────────────────────────────────

  Widget _buildLyrics() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.lyrics_rounded,
            color: Colors.white.withOpacity(0.1), size: 52),
        const SizedBox(height: 14),
        Text('Lyrics coming soon',
            style: TextStyle(
                color: Colors.white.withOpacity(0.28), fontSize: 13)),
      ]),
    );
  }

  // ── Info ──────────────────────────────────────────────────────────────────

  Widget _buildInfo(Song song) {
    final rows = <MapEntry<String, String>>[];
    if (song.title.isNotEmpty) rows.add(MapEntry('Title', song.title));
    if (song.artist.isNotEmpty) rows.add(MapEntry('Artist', song.artist));
    if (song.album.isNotEmpty) rows.add(MapEntry('Album', song.album));
    if (song.year != null && song.year!.isNotEmpty)
      rows.add(MapEntry('Year', song.year!));
    if (song.language != null && song.language!.isNotEmpty)
      rows.add(MapEntry('Language', song.language!));
    if (song.duration != null)
      rows.add(MapEntry('Duration', song.durationString));
    rows.add(MapEntry('Source', song.isLocal ? 'Local Library' : 'Online Stream'));
    if (song.localPath != null && song.localPath!.isNotEmpty)
      rows.add(MapEntry('Format', song.localPath!.split('.').last.toUpperCase()));

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: rows
          .map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 78,
                        child: Text(e.key,
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.35),
                                fontSize: 12)),
                      ),
                      Expanded(
                        child: Text(e.value,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                      ),
                    ]),
              ))
          .toList(),
    );
  }

  // ── Options sheet ─────────────────────────────────────────────────────────

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2)),
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
            title: const Text('Add to Queue',
                style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(context);
              player.addToQueue(song);
            },
          ),
          ListTile(
            leading: const Icon(Icons.share_rounded, color: Colors.white),
            title: const Text('Share', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
