import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late AnimationController _slideController;
  late Animation<Offset> _slideAnim;
  late AnimationController _artworkScale;

  Color _bgColor1 = const Color(0xFF1A0A00);
  Color _bgColor2 = const Color(0xFF0A0500);
  String? _lastArtworkUrl;
  int _activeTab = 0;

  // Swipe-to-close — only top drag handle area
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _slideController.forward();

    _artworkScale = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.96,
      upperBound: 1.0,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _slideController.dispose();
    _artworkScale.dispose();
    super.dispose();
  }

  void _close() {
    _slideController.reverse().then((_) {
      if (mounted) context.read<PlayerProvider>().closeFullPlayer();
    });
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtworkUrl || url.startsWith('content://')) return;
    _lastArtworkUrl = url;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(80, 80),
      );
      final dominant = pg.dominantColor?.color ??
          pg.vibrantColor?.color ??
          const Color(0xFF1A0A00);
      if (mounted) {
        setState(() {
          _bgColor1 = Color.lerp(dominant, Colors.black, 0.3)!;
          _bgColor2 = Color.lerp(dominant, Colors.black, 0.68)!;
        });
      }
    } catch (_) {}
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        if (song.artworkUrl.isNotEmpty && !song.artworkUrl.startsWith('content://')) {
          _extractColor(song.artworkUrl);
        }

        return SlideTransition(
          position: _slideAnim,
          child: Transform.translate(
            offset: Offset(0, _dragOffset.clamp(0.0, 220.0)),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                fit: StackFit.expand,
                children: [
                  _buildBackground(song),
                  SafeArea(
                    child: Column(
                      children: [
                        // ── Drag handle (swipe-to-close only here) ──
                        GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onVerticalDragUpdate: (d) {
                            if (d.delta.dy > 0 || _dragOffset > 0) {
                              setState(() {
                                _dragOffset = (_dragOffset + d.delta.dy).clamp(0.0, 300.0);
                              });
                            }
                          },
                          onVerticalDragEnd: (d) {
                            if (_dragOffset > 80 || (d.primaryVelocity ?? 0) > 500) {
                              _close();
                            } else {
                              setState(() => _dragOffset = 0);
                            }
                          },
                          child: _buildTopBar(context, song),
                        ),
                        // ── Fixed: artwork + controls ──
                        const SizedBox(height: 6),
                        _buildArtwork(song, player.isPlaying),
                        const SizedBox(height: 18),
                        _buildSongInfo(context, song, player),
                        const SizedBox(height: 12),
                        _buildSeekBar(context, player),
                        const SizedBox(height: 16),
                        _buildControls(context, player),
                        const SizedBox(height: 10),
                        _buildAudioStrip(song),
                        const SizedBox(height: 8),
                        // ── Scrollable tab section ──
                        _buildTabBar(context),
                        Expanded(child: _buildTabContent(context, player, song)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Background — full bleed blur ──────────────────────────────────────────

  Widget _buildBackground(Song song) {
    final hasArt = song.artworkUrl.isNotEmpty;
    final isLocal = song.artworkUrl.startsWith('content://');

    return Stack(
      fit: StackFit.expand,
      children: [
        // Gradient base always
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
        // Full bleed artwork behind blur
        if (hasArt)
          isLocal
              ? _LocalBlurredBg(uri: song.artworkUrl)
              : CachedNetworkImage(
                  imageUrl: song.artworkUrl,
                  fit: BoxFit.cover,
                  color: Colors.black.withOpacity(0.45),
                  colorBlendMode: BlendMode.darken,
                  errorWidget: (_, __, ___) => const SizedBox.shrink(),
                ),
        // Blur layer
        if (hasArt)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _bgColor1.withOpacity(0.45),
                    _bgColor2.withOpacity(0.65),
                    Colors.black.withOpacity(0.94),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context, Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: _close,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
            color: Colors.white,
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'NOW PLAYING',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
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
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _showOptions(context),
            icon: const Icon(Icons.more_vert_rounded, size: 24),
            color: Colors.white,
          ),
        ],
      ),
    );
  }

  // ── Artwork — larger, centered, shadow ───────────────────────────────────

  Widget _buildArtwork(Song song, bool isPlaying) {
    final screenW = MediaQuery.of(context).size.width;
    final size = screenW - 48.0; // larger — only 24px each side
    return Center(
      child: AnimatedBuilder(
        animation: _artworkScale,
        builder: (_, child) => Transform.scale(
          scale: isPlaying ? _artworkScale.value : 0.92,
          child: child,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: _bgColor1.withOpacity(0.7),
                blurRadius: 40,
                offset: const Offset(0, 16),
                spreadRadius: 6,
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AurumArtwork(
              url: song.artworkUrl,
              size: size,
              borderRadius: 18,
            ),
          ),
        ),
      ),
    );
  }

  // ── Song info ─────────────────────────────────────────────────────────────

  Widget _buildSongInfo(BuildContext context, Song song, PlayerProvider player) {
    final fav = context.watch<FavoritesProvider>();
    final isLiked = fav.isFavorite(song.id);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
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
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
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
                color: isLiked ? const Color(0xFFE1306C) : Colors.white.withOpacity(0.7),
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Seek bar ──────────────────────────────────────────────────────────────

  Widget _buildSeekBar(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
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
            child: Slider(
              value: player.progress,
              onChanged: player.seek,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(player.positionString,
                    style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
                Text(player.durationString,
                    style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControls(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            onPressed: player.toggleShuffle,
            icon: Icon(
              Icons.shuffle_rounded,
              color: player.shuffle ? AurumTheme.gold : Colors.white.withOpacity(0.55),
              size: 22,
            ),
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
                    color: Colors.white.withOpacity(0.22),
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
        return Icon(Icons.repeat_rounded, color: Colors.white.withOpacity(0.55), size: 22);
    }
  }

  // ── Audio quality strip ───────────────────────────────────────────────────

  Widget _buildAudioStrip(Song song) {
    final parts = <String>[];

    if (song.isLocal) {
      final path = song.localPath ?? '';
      final ext = path.split('.').last.toUpperCase();
      if (['MP3','M4A','AAC','FLAC','WAV','OGG'].contains(ext)) {
        parts.add(ext == 'M4A' ? 'AAC' : ext);
      } else {
        parts.add('LOCAL');
      }
      // Sample rate hint based on format
      if (ext == 'FLAC') {
        parts.add('LOSSLESS');
      } else if (ext == 'MP3') {
        parts.add('44100 Hz');
      } else {
        parts.add('48000 Hz');
      }
    } else {
      parts.add('STREAM');
      if (song.language != null && song.language!.isNotEmpty) {
        parts.add(song.language!.toUpperCase());
      }
    }

    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        parts.join('  •  '),
        style: TextStyle(
          color: Colors.white.withOpacity(0.4),
          fontSize: 11,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ── Tab bar — clean, Echo Nighty style ───────────────────────────────────

  Widget _buildTabBar(BuildContext context) {
    final tabs = ['Up Next', 'Lyrics', 'Info'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = _activeTab == i;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _activeTab = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: active ? Colors.white : Colors.white.withOpacity(0.1),
                      width: active ? 1.5 : 0.5,
                    ),
                  ),
                ),
                child: Text(
                  tabs[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white.withOpacity(0.35),
                    fontSize: 12,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Tab content — ONLY this scrolls ──────────────────────────────────────

  Widget _buildTabContent(BuildContext context, PlayerProvider player, Song song) {
    switch (_activeTab) {
      case 0: return _buildUpNext(context, player);
      case 1: return _buildLyrics();
      case 2: return _buildInfo(song);
      default: return const SizedBox.shrink();
    }
  }

  // ── Up Next ───────────────────────────────────────────────────────────────

  Widget _buildUpNext(BuildContext context, PlayerProvider player) {
    final queue = player.queue;
    final current = player.currentIndex;
    if (queue.isEmpty) {
      return Center(
        child: Text('Queue is empty',
            style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13)),
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
      itemCount: queue.length,
      itemBuilder: (_, i) {
        final s = queue[i];
        final isCurrent = i == current;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: AurumArtwork(url: s.artworkUrl, size: 42, borderRadius: 6),
          ),
          title: Text(s.title,
              style: TextStyle(
                color: isCurrent ? AurumTheme.gold : Colors.white,
                fontSize: 13,
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
              ),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(s.artist,
              style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: isCurrent
              ? const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 18)
              : null,
          onTap: () => player.skipToIndex(i),
        );
      },
    );
  }

  // ── Lyrics ────────────────────────────────────────────────────────────────

  Widget _buildLyrics() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.lyrics_rounded, color: Colors.white.withOpacity(0.12), size: 48),
        const SizedBox(height: 12),
        Text('Lyrics coming soon',
            style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13)),
      ]),
    );
  }

  // ── Info ──────────────────────────────────────────────────────────────────

  Widget _buildInfo(Song song) {
    final rows = <MapEntry<String, String>>[];
    if (song.title.isNotEmpty) rows.add(MapEntry('Title', song.title));
    if (song.artist.isNotEmpty) rows.add(MapEntry('Artist', song.artist));
    if (song.album.isNotEmpty) rows.add(MapEntry('Album', song.album));
    if (song.year != null && song.year!.isNotEmpty) rows.add(MapEntry('Year', song.year!));
    if (song.language != null && song.language!.isNotEmpty) rows.add(MapEntry('Language', song.language!));
    if (song.duration != null) rows.add(MapEntry('Duration', song.durationString));
    rows.add(MapEntry('Source', song.isLocal ? 'Local Library' : 'Online Stream'));
    if (song.localPath != null && song.localPath!.isNotEmpty) {
      rows.add(MapEntry('Format', song.localPath!.split('.').last.toUpperCase()));
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: rows.map((e) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(e.key,
                  style: TextStyle(color: Colors.white.withOpacity(0.38), fontSize: 12)),
            ),
            Expanded(
              child: Text(e.value,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      )).toList(),
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
            width: 36, height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2), borderRadius: BorderRadius.circular(2)),
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
            title: const Text('Add to Queue', style: TextStyle(color: Colors.white)),
            onTap: () { Navigator.pop(context); player.addToQueue(song); },
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

// ── Local blurred background widget ──────────────────────────────────────────
// Uses AurumArtwork internally — handles content:// URI via MethodChannel
class _LocalBlurredBg extends StatelessWidget {
  final String uri;
  const _LocalBlurredBg({required this.uri});

  @override
  Widget build(BuildContext context) {
    return AurumArtwork(
      url: uri,
      size: MediaQuery.of(context).size.height,
      borderRadius: 0,
    );
  }
}
