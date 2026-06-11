import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import 'up_next_sheet.dart';
import 'lyrics_screen.dart';
import 'song_info_screen.dart';

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
  late AnimationController _playBtnController;

  Color _bgColor1 = const Color(0xFF1A1A2E);
  Color _bgColor2 = const Color(0xFF0D0D0D);
  String? _lastArtworkUrl;
  double _dragOffset = 0;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
        .animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _slideController.forward();

    _artworkPulse = AnimationController(vsync: this,
        duration: const Duration(milliseconds: 1600), lowerBound: 0.97, upperBound: 1.0)
      ..repeat(reverse: true);

    _playBtnController = AnimationController(vsync: this, duration: const Duration(milliseconds: 120),
        lowerBound: 0.9, upperBound: 1.0, value: 1.0);
  }

  @override
  void dispose() {
    _slideController.dispose();
    _artworkPulse.dispose();
    _playBtnController.dispose();
    super.dispose();
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastArtworkUrl) return;
    _lastArtworkUrl = url;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
          CachedNetworkImageProvider(url), size: const Size(100, 100));
      final dominant = pg.dominantColor?.color ?? pg.vibrantColor?.color ?? const Color(0xFF1A1A2E);
      if (mounted) setState(() {
        _bgColor1 = Color.lerp(dominant, Colors.black, 0.25)!;
        _bgColor2 = Color.lerp(dominant, Colors.black, 0.78)!;
      });
    } catch (_) {}
  }

  void _close() {
    if (!mounted) return;
    _slideController.reverse().then((_) { if (mounted) Navigator.of(context).pop(); });
  }

  void _openUpNext(PlayerProvider player) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => UpNextSheet(player: player),
    );
  }

  void _openLyrics(Song song) {
    Navigator.of(context).push(PageRouteBuilder(
      pageBuilder: (_, a, __) => LyricsScreen(song: song),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
      transitionDuration: const Duration(milliseconds: 280),
    ));
  }

  void _openInfo(Song song) {
    Navigator.of(context).push(PageRouteBuilder(
      pageBuilder: (_, a, __) => SongInfoScreen(song: song, bgColor: _bgColor1),
      transitionsBuilder: (_, a, __, child) =>
          SlideTransition(position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
      transitionDuration: const Duration(milliseconds: 300),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        final song = player.currentSong;
        if (song == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) Navigator.of(context).pop(); });
          return const SizedBox.shrink();
        }
        if (song.artworkUrl.isNotEmpty) _extractColor(song.artworkUrl);

        return SlideTransition(
          position: _slideAnim,
          child: GestureDetector(
            onVerticalDragUpdate: (d) { if (d.delta.dy > 0) setState(() => _dragOffset += d.delta.dy); },
            onVerticalDragEnd: (d) {
              if (_dragOffset > 100 || (d.primaryVelocity ?? 0) > 800) _close();
              else setState(() => _dragOffset = 0);
            },
            child: Transform.translate(
              offset: Offset(0, _dragOffset.clamp(0.0, 300.0)),
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(fit: StackFit.expand, children: [
                  _buildBackground(song),
                  SafeArea(child: _buildContent(context, player, song)),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBackground(Song song) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 800),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [_bgColor1, _bgColor2, Colors.black],
          stops: const [0.0, 0.45, 1.0],
        ),
      ),
      child: song.artworkUrl.isNotEmpty
          ? Stack(fit: StackFit.expand, children: [
              CachedNetworkImage(imageUrl: song.artworkUrl, fit: BoxFit.cover,
                  color: Colors.black.withOpacity(0.62), colorBlendMode: BlendMode.darken),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 65, sigmaY: 65),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [_bgColor1.withOpacity(0.4), _bgColor2.withOpacity(0.6), Colors.black.withOpacity(0.96)],
                      stops: const [0.0, 0.4, 1.0],
                    ),
                  ),
                ),
              ),
            ])
          : const SizedBox.shrink(),
    );
  }

  Widget _buildContent(BuildContext context, PlayerProvider player, Song song) {
    return Column(children: [
      _buildTopBar(song),
      const SizedBox(height: 2),
      _buildArtwork(song, player.isPlaying),
      const SizedBox(height: 20),
      _buildSongInfo(song),
      const SizedBox(height: 14),
      _buildSeekBar(context, player),
      const SizedBox(height: 14),
      _buildControls(player),
      const SizedBox(height: 10),
      _buildAudioPill(song),
      const Spacer(),
      _buildBottomButtons(player, song),
      const SizedBox(height: 16),
    ]);
  }

  Widget _buildTopBar(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(children: [
        IconButton(onPressed: _close,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: Colors.white)),
        Expanded(child: Column(children: [
          Text('Playing From', style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11, letterSpacing: 0.5)),
          const SizedBox(height: 2),
          Text(song.album.isNotEmpty ? song.album : 'Aurum Music',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
              maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ])),
        IconButton(onPressed: () => _showOptions(context),
            icon: const Icon(Icons.more_vert_rounded, size: 24, color: Colors.white)),
      ]),
    );
  }

  Widget _buildArtwork(Song song, bool isPlaying) {
    final size = MediaQuery.of(context).size.width - 64;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: AnimatedBuilder(
        animation: _artworkPulse,
        builder: (_, child) => Transform.scale(
          scale: isPlaying ? _artworkPulse.value : 0.91,
          child: child,
        ),
        child: Container(
          width: size, height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: _bgColor1.withOpacity(0.75), blurRadius: 45, offset: const Offset(0, 18), spreadRadius: 8),
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 22, offset: const Offset(0, 10)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: song.artworkUrl.isNotEmpty
                ? CachedNetworkImage(imageUrl: song.artworkUrl, fit: BoxFit.cover,
                    placeholder: (_, __) => _artPlaceholder(),
                    errorWidget: (_, __, ___) => _artPlaceholder())
                : _artPlaceholder(),
          ),
        ),
      ),
    );
  }

  Widget _artPlaceholder() => Container(
    decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topLeft, end: Alignment.bottomRight,
        colors: [_bgColor1.withOpacity(0.8), _bgColor2])),
    child: const Icon(Icons.music_note_rounded, color: AurumTheme.gold, size: 80),
  );

  Widget _buildSongInfo(Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(song.title,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, height: 1.2),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 5),
          Text(song.artist,
              style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 14),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        const SizedBox(width: 12),
        Icon(Icons.favorite_border_rounded, color: Colors.white.withOpacity(0.5), size: 26),
      ]),
    );
  }

  Widget _buildSeekBar(BuildContext context, PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.5,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white.withOpacity(0.18),
            thumbColor: Colors.white,
            overlayColor: Colors.white.withOpacity(0.1),
          ),
          child: Slider(value: player.progress.clamp(0.0, 1.0), onChanged: player.seek),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(player.positionString, style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
            Text(player.durationString, style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 12)),
          ]),
        ),
      ]),
    );
  }

  Widget _buildControls(PlayerProvider player) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        _ctrlBtn(Icons.shuffle_rounded, 22,
            player.shuffle ? AurumTheme.gold : Colors.white.withOpacity(0.45), player.toggleShuffle),
        _ctrlBtn(Icons.skip_previous_rounded, 40, Colors.white.withOpacity(0.9), player.skipPrev),
        // Play/Pause with scale animation
        GestureDetector(
          onTapDown: (_) => _playBtnController.reverse(),
          onTapUp: (_) { _playBtnController.forward(); player.togglePlay(); },
          onTapCancel: () => _playBtnController.forward(),
          child: AnimatedBuilder(
            animation: _playBtnController,
            builder: (_, child) => Transform.scale(scale: _playBtnController.value, child: child),
            child: Container(
              width: 70, height: 70,
              decoration: BoxDecoration(
                color: Colors.white, shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.white.withOpacity(0.35), blurRadius: 24, spreadRadius: 3)],
              ),
              child: Icon(
                player.isLoading ? Icons.hourglass_empty_rounded
                    : player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.black, size: 38,
              ),
            ),
          ),
        ),
        _ctrlBtn(Icons.skip_next_rounded, 40, Colors.white.withOpacity(0.9), player.skipNext),
        _ctrlBtn(
          player.loopMode.toString() == 'LoopMode.one' ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          22,
          player.loopMode.toString() != 'LoopMode.off' ? AurumTheme.gold : Colors.white.withOpacity(0.45),
          player.toggleLoop,
        ),
      ]),
    );
  }

  Widget _ctrlBtn(IconData icon, double size, Color color, VoidCallback onTap) =>
      GestureDetector(onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(8), child: Icon(icon, size: size, color: color)));

  Widget _buildAudioPill(Song song) {
    final parts = <String>[];
    if (song.isLocal) parts.add('LOCAL');
    if (song.language != null && song.language!.isNotEmpty) parts.add(song.language!.toUpperCase());
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) parts.add('STREAM');

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Text(parts.join(' • '),
              style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 11,
                  letterSpacing: 0.8, fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }

  Widget _buildBottomButtons(PlayerProvider player, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(children: [
        Expanded(child: _bottomBtn(Icons.queue_music_rounded, 'Up Next', () => _openUpNext(player))),
        Container(width: 1, height: 32, color: Colors.white.withOpacity(0.15)),
        Expanded(child: _bottomBtn(Icons.lyrics_rounded, 'Lyrics', () => _openLyrics(song))),
        Container(width: 1, height: 32, color: Colors.white.withOpacity(0.15)),
        Expanded(child: _bottomBtn(Icons.info_outline_rounded, 'Info', () => _openInfo(song))),
      ]),
    );
  }

  Widget _bottomBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white.withOpacity(0.7), size: 20),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 11, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 38, height: 4, margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(2))),
        ListTile(leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
            title: const Text('Add to Queue', style: TextStyle(color: Colors.white)),
            onTap: () { Navigator.pop(context); player.addToQueue(song); }),
        ListTile(leading: const Icon(Icons.share_rounded, color: Colors.white),
            title: const Text('Share', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context)),
        const SizedBox(height: 8),
      ])),
    );
  }
}
