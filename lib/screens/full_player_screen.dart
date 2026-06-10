import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/player_provider.dart';
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
  late AnimationController _artworkPulse;

  Color _bgColor1 = const Color(0xFF1A0A00);
  Color _bgColor2 = const Color(0xFF0A0500);
  String? _lastArtworkUrl;

  int _activeTab = 0; // 0=UpNext, 1=Lyrics, 2=Info
  bool _dragging = false;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
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

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtworkUrl) return;
    _lastArtworkUrl = url;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(100, 100),
      );
      final dominant = pg.dominantColor?.color ??
          pg.vibrantColor?.color ??
          const Color(0xFF1A0A00);
      if (mounted) {
        setState(() {
          _bgColor1 = Color.lerp(dominant, Colors.black, 0.35)!;
          _bgColor2 = Color.lerp(dominant, Colors.black, 0.72)!;
        });
      }
    } catch (_) {}
  }

  void _close() {
    _slideController.reverse().then((_) {
      if (mounted) context.read<PlayerProvider>().closeFullPlayer();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        // Extract color whenever artwork changes
        if (song.artworkUrl.isNotEmpty) {
          _extractColor(song.artworkUrl);
        }

        return SlideTransition(
          position: _slideAnim,
          child: GestureDetector(
            onVerticalDragStart: (_) => setState(() {
              _dragging = true;
              _dragOffset = 0;
            }),
            onVerticalDragUpdate: (d) {
              if (d.delta.dy > 0 || _dragOffset > 0) {
                setState(() {
                  _dragOffset = (_dragOffset + d.delta.dy).clamp(0.0, 300.0);
                });
              }
            },
            onVerticalDragEnd: (d) {
              if (_dragOffset > 80 || (d.primaryVelocity ?? 0) > 600) {
                _close();
              } else {
                setState(() {
                  _dragging = false;
                  _dragOffset = 0;
                });
              }
            },
            child: Transform.translate(
              offset: Offset(0, _dragOffset.clamp(0, 200)),
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    // ── Dynamic blur background ──────────────────────────
                    _buildBackground(song),
                    // ── Content ──────────────────────────────────────────
                    SafeArea(child: _buildContent(context, player, song)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Background ────────────────────────────────────────────────────────────

  Widget _buildBackground(Song song) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_bgColor1, _bgColor2, Colors.black],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: song.artworkUrl.isNotEmpty
          ? Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: song.artworkUrl,
                  fit: BoxFit.cover,
                  color: Colors.black.withOpacity(0.55),
                  colorBlendMode: BlendMode.darken,
                ),
                BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _bgColor1.withOpacity(0.5),
                          _bgColor2.withOpacity(0.7),
                          Colors.black.withOpacity(0.92),
                        ],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }

  // ── Main content ──────────────────────────────────────────────────────────

  Widget _buildContent(BuildContext context, PlayerProvider player, Song song) {
    return Column(
      children: [
        _buildTopBar(context, song),
        const SizedBox(height: 8),
        _buildArtwork(song, player.isPlaying),
        const SizedBox(height: 20),
        _buildSongInfo(context, song, player),
        const SizedBox(height: 14),
        _buildSeekBar(context, player),
        const SizedBox(height: 18),
        _buildControls(context, player),
        const SizedBox(height: 14),
        _buildAudioInfo(song),
        const SizedBox(height: 12),
        _buildBottomTabs(context, player, song),
      ],
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context, Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: _close,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            color: Colors.white,
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  'Playing From',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 11,
                    letterSpacing: 0.3,
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

  // ── Artwork ───────────────────────────────────────────────────────────────

  Widget _buildArtwork(Song song, bool isPlaying) {
    final size = MediaQuery.of(context).size.width - 56;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: AnimatedBuilder(
        animation: _artworkPulse,
        builder: (_, child) => Transform.scale(
          scale: isPlaying ? (_artworkPulse.value) : 0.93,
          child: child,
        ),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _bgColor1.withOpacity(0.6),
                blurRadius: 32,
                offset: const Offset(0, 12),
                spreadRadius: 4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: song.artworkUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: song.artworkUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: Colors.white.withOpacity(0.05),
                      child: const Icon(
                        Icons.music_note_rounded,
                        color: AurumTheme.gold,
                        size: 64,
                      ),
                    ),
                  )
                : Container(
                    color: Colors.white.withOpacity(0.05),
                    child: const Icon(
                      Icons.music_note_rounded,
                      color: AurumTheme.gold,
                      size: 64,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ── Song info ─────────────────────────────────────────────────────────────

  Widget _buildSongInfo(BuildContext context, Song song, PlayerProvider player) {
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
                    fontSize: 19,
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
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () {}, // TODO: favourite toggle
            child: Icon(
              Icons.favorite_border_rounded,
              color: Colors.white.withOpacity(0.7),
              size: 26,
            ),
          ),
        ],
      ),
    );
  }

  // ── Seekbar ───────────────────────────────────────────────────────────────

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
              inactiveTrackColor: Colors.white.withOpacity(0.2),
              thumbColor: Colors.white,
              overlayColor: Colors.white.withOpacity(0.12),
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
                Text(
                  player.positionString,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                ),
                Text(
                  player.durationString,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 12,
                  ),
                ),
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
          // Shuffle
          IconButton(
            onPressed: player.toggleShuffle,
            icon: Icon(
              Icons.shuffle_rounded,
              color: player.shuffle
                  ? AurumTheme.gold
                  : Colors.white.withOpacity(0.6),
              size: 22,
            ),
          ),
          // Previous
          IconButton(
            onPressed: player.skipPrev,
            icon: Icon(
              Icons.skip_previous_rounded,
              color: Colors.white.withOpacity(0.9),
              size: 36,
            ),
          ),
          // Play / Pause
          GestureDetector(
            onTap: player.togglePlay,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.25),
                    blurRadius: 16,
                    spreadRadius: 2,
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
                size: 34,
              ),
            ),
          ),
          // Next
          IconButton(
            onPressed: player.skipNext,
            icon: Icon(
              Icons.skip_next_rounded,
              color: Colors.white.withOpacity(0.9),
              size: 36,
            ),
          ),
          // Repeat
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
            color: Colors.white.withOpacity(0.6), size: 22);
    }
  }

  // ── Audio info strip ──────────────────────────────────────────────────────

  Widget _buildAudioInfo(Song song) {
    final parts = <String>[];
    if (song.isLocal) parts.add('LOCAL');
    // Show language if available
    if (song.language != null && song.language!.isNotEmpty) {
      parts.add(song.language!.toUpperCase());
    }
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) parts.add('STREAM');

    return Text(
      parts.join(' • '),
      style: TextStyle(
        color: Colors.white.withOpacity(0.35),
        fontSize: 11,
        letterSpacing: 0.8,
        fontWeight: FontWeight.w500,
      ),
    );
  }

  // ── Bottom tabs ───────────────────────────────────────────────────────────

  Widget _buildBottomTabs(
      BuildContext context, PlayerProvider player, Song song) {
    final tabs = ['Up Next', 'Lyrics', 'Info'];
    return Expanded(
      child: Column(
        children: [
          // Tab bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: List.generate(tabs.length, (i) {
                final active = _activeTab == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _activeTab = i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: active
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        tabs[i],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: active
                              ? Colors.white
                              : Colors.white.withOpacity(0.4),
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          // Tab content
          Expanded(
            child: IndexedStack(
              index: _activeTab,
              children: [
                _buildUpNext(context, player),
                _buildLyrics(),
                _buildInfo(song),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Up Next tab ───────────────────────────────────────────────────────────

  Widget _buildUpNext(BuildContext context, PlayerProvider player) {
    final queue = player.queue;
    final current = player.currentIndex;
    if (queue.isEmpty) {
      return Center(
        child: Text(
          'Queue is empty',
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: queue.length,
      itemBuilder: (_, i) {
        final s = queue[i];
        final isCurrent = i == current;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: s.artworkUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: s.artworkUrl,
                    width: 42,
                    height: 42,
                    fit: BoxFit.cover,
                  )
                : Container(
                    width: 42,
                    height: 42,
                    color: Colors.white.withOpacity(0.08),
                    child: const Icon(Icons.music_note_rounded,
                        color: AurumTheme.gold, size: 18),
                  ),
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
              color: Colors.white.withOpacity(0.4),
              fontSize: 11,
            ),
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

  // ── Lyrics tab ────────────────────────────────────────────────────────────

  Widget _buildLyrics() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lyrics_rounded,
              color: Colors.white.withOpacity(0.15), size: 48),
          const SizedBox(height: 12),
          Text(
            'Lyrics coming soon',
            style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ── Info tab ──────────────────────────────────────────────────────────────

  Widget _buildInfo(Song song) {
    final rows = <Map<String, String>>[];
    if (song.album.isNotEmpty) rows.add({'Album': song.album});
    if (song.artist.isNotEmpty) rows.add({'Artist': song.artist});
    if (song.year != null && song.year!.isNotEmpty) rows.add({'Year': song.year!});
    if (song.language != null && song.language!.isNotEmpty)
      rows.add({'Language': song.language!});
    if (song.duration != null)
      rows.add({'Duration': song.durationString});
    rows.add({'Source': song.isLocal ? 'Local Library' : 'Online Stream'});

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: rows.map((r) {
        final key = r.keys.first;
        final val = r.values.first;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  key,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  val,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // ── Options sheet ─────────────────────────────────────────────────────────

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(2),
              ),
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
          ],
        ),
      ),
    );
  }
}
