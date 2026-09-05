// edge_to_edge_full_player.dart
// Astra Music — "Edge to Edge" Full Player Layout
//
// Second full-player design, selectable from Settings → Appearance →
// Full Player Layout. Unlike the default "Card" layout (album art inset
// in a rounded card, dedicated top bar with back/cast/queue icons, blur
// or solid background painted separately behind the card), this layout:
//
//   • Renders the artwork as a single BoxFit.cover image filling the
//     ENTIRE screen, from the very top of the status bar down to the
//     bottom of the volume row — the art IS the background, there is no
//     separate blur/solid bg layer underneath it.
//   • Has no top bar at all. Back navigation is via swipe-down-to-dismiss
//     or the system back gesture, matching the reference design.
//   • Overlays title/artist/actions, the scrub bar, transport controls,
//     and the volume row directly on top of the art with a bottom
//     gradient scrim for legibility, exactly as in the reference
//     screenshot.
//
// Deliberately self-contained (does not import or extend anything from
// full_player_screen.dart's massive _FullPlayerScreenState) so this
// layout can be maintained, tweaked, or removed independently without
// any risk to the Card layout's own drag-to-dismiss/animation logic.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:cached_network_image/cached_network_image.dart';

import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../utils/artwork_palette_cache.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/aurum_play_pause_icon.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/audio_output_sheet.dart';
import '../services/native_engine_bridge.dart' show MediaVolume;
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import 'full_player_screen.dart' show showAurumFullPlayerOptionsSheet, showSleepTimerForSong;
import 'settings_player_screen.dart' show SleepTimerService;

class EdgeToEdgeFullPlayer extends StatefulWidget {
  const EdgeToEdgeFullPlayer({super.key});

  @override
  State<EdgeToEdgeFullPlayer> createState() => _EdgeToEdgeFullPlayerState();
}

class _EdgeToEdgeFullPlayerState extends State<EdgeToEdgeFullPlayer> {
  double _dragY = 0;
  bool _dragging = false;

  // Song-specific solid panel color — extracted from the current
  // artwork's palette (same ArtworkPaletteCache the Card layout's "Solid"
  // background style uses), contrast-clamped for white text/icons on top.
  // Starts as a safe dark neutral before the first extraction resolves,
  // then updates per-song via _loadPaletteFor().
  Color _panelColor = const Color(0xFF1C1C1E);
  String? _paletteUrl;

  static const double _dismissThreshold = 140;

  void _handleDragUpdate(DragUpdateDetails d) {
    if (d.delta.dy <= 0 && _dragY == 0) return; // ignore upward drag start
    setState(() {
      _dragging = true;
      _dragY = (_dragY + d.delta.dy).clamp(0.0, 600.0);
    });
  }

  void _handleDragEnd(DragEndDetails d) {
    if (_dragY > _dismissThreshold || d.velocity.pixelsPerSecond.dy > 800) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _dragging = false;
      _dragY = 0;
    });
  }

  void _loadPaletteFor(String url) {
    if (url.isEmpty || url == _paletteUrl) return;
    _paletteUrl = url;

    // Cache hit — apply instantly, no flash of the fallback color.
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      final safe = ensureContrastSafe(cached.darkMuted, isLight: false);
      if (mounted) setState(() => _panelColor = safe);
      return;
    }

    ArtworkPaletteCache.get(url).then((palette) {
      if (!mounted || _paletteUrl != url) return;
      final safe = ensureContrastSafe(palette.darkMuted, isLight: false);
      setState(() => _panelColor = safe);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (String?, bool, bool, LoopMode, bool)>(
      selector: (_, p) => (
        p.currentSong?.id,
        p.isPlaying,
        p.isLoading,
        p.loopMode,
        p.shuffle,
      ),
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        final song = player.currentSong;
        if (song == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }

        _loadPaletteFor(song.artworkUrl);

        final scale = (1 - (_dragY / 1400)).clamp(0.9, 1.0);
        final opacity = (1 - (_dragY / 500)).clamp(0.35, 1.0);

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: GestureDetector(
              onVerticalDragUpdate: _handleDragUpdate,
              onVerticalDragEnd: _handleDragEnd,
              child: AnimatedContainer(
                duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(0, _dragY, 0)..scale(scale, scale),
                transformAlignment: Alignment.center,
                child: Opacity(
                  opacity: opacity,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Reference design: artwork fills roughly the top
                      // ~58% of the screen, then a FLAT solid panel (not a
                      // gradient fade) takes over for title/controls —
                      // matching the "Jaiye Sajana" reference exactly,
                      // where the grey panel has zero artwork bleed-through.
                      final artHeight = constraints.maxHeight * 0.58;
                      return Stack(
                        children: [
                          // ── Artwork: fixed-height top section ──
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: artHeight,
                            child: Hero(
                              tag: 'aurum_art_${song.id}',
                              child: song.artworkUrl.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: song.artworkUrl,
                                      fit: BoxFit.cover,
                                      fadeInDuration: const Duration(milliseconds: 220),
                                      errorWidget: (_, __, ___) =>
                                          Container(color: AurumTheme.darkBgElevated),
                                    )
                                  : Container(color: AurumTheme.darkBgElevated),
                            ),
                          ),

                          // ── Solid flat panel: bottom section, no
                          // gradient, no artwork bleed-through ──
                          Positioned(
                            top: artHeight,
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(color: _panelColor),
                            ),
                          ),

                          // ── Short blend seam where art meets the panel,
                          // so the transition isn't a hard visible line ──
                          Positioned(
                            top: artHeight - 28,
                            left: 0,
                            right: 0,
                            height: 28,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    _panelColor.withOpacity(0.0),
                                    _panelColor,
                                  ],
                                ),
                              ),
                            ),
                          ),

                          // ── Foreground content ──
                          SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 26),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  const Spacer(),
                                  _TitleRow(song: song),
                                  const SizedBox(height: 32),
                                  _ScrubBar(player: player),
                                  const SizedBox(height: 16),
                                  _TransportRow(player: player),
                                  const SizedBox(height: 26),
                                  _VolumeRow(player: player),
                                  const SizedBox(height: 32),
                                  _BottomIconRow(player: player, song: song),
                                  const SizedBox(height: 20),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    return Consumer<FavoritesProvider>(
      builder: (context, fav, _) {
        final isLiked = fav.isFavorite(song.id);
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            _CircleIconButton(
              icon: Icons.more_vert_rounded,
              onTap: () => showAurumFullPlayerOptionsSheet(
                context,
                song,
                accentColor: AurumTheme.gold,
              ),
            ),
            const SizedBox(width: 14),
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.14),
              ),
              alignment: Alignment.center,
              child: AurumLikeButton(
                isLiked: isLiked,
                onTap: () => fav.toggleFavorite(song),
                size: 20,
                unlikedColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.14),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

class _ScrubBar extends StatefulWidget {
  const _ScrubBar({required this.player});
  final PlayerProvider player;

  @override
  State<_ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<_ScrubBar> {
  double? _dragValue;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (Duration, Duration)>(
      selector: (_, p) => (p.position, p.duration),
      builder: (context, data, _) {
        final (pos, dur) = data;
        final total = dur.inMilliseconds == 0 ? 1 : dur.inMilliseconds;
        final ratio = _dragValue ?? (pos.inMilliseconds / total).clamp(0.0, 1.0);
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white.withOpacity(0.32),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: ratio,
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  widget.player.seek(v);
                  setState(() => _dragValue = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(pos), style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12)),
                  Text(_fmt(dur), style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.player});
  final PlayerProvider player;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (bool, bool)>(
      selector: (_, p) => (p.isPlaying, p.isLoading),
      builder: (context, data, _) {
        final (isPlaying, isLoading) = data;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              iconSize: 38,
              icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
              onPressed: () {
                AurumHaptics.light();
                player.skipPrev();
              },
            ),
            GestureDetector(
              onTap: () {
                AurumHaptics.medium();
                player.togglePlay();
              },
              child: Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.35),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(22),
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          valueColor: AlwaysStoppedAnimation(Colors.black87),
                        ),
                      )
                    : AurumPlayPauseIcon(isPlaying: isPlaying, color: Colors.black87, size: 40),
              ),
            ),
            IconButton(
              iconSize: 38,
              icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
              onPressed: () {
                AurumHaptics.light();
                player.skipNext();
              },
            ),
          ],
        );
      },
    );
  }
}

class _VolumeRow extends StatefulWidget {
  const _VolumeRow({required this.player});
  final PlayerProvider player;

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
  int _level = 0;
  int _max = 15;
  bool _loaded = false;
  int? _fadeGen; // increments to cancel an in-flight fade if user interacts again

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final mv = await widget.player.engine.getMediaVolume();
      if (!mounted) return;
      setState(() {
        _level = mv.level;
        _max = mv.max == 0 ? 15 : mv.max;
        _loaded = true;
      });
    } catch (_) {
      // Device volume read failed — hide the slider rather than show a
      // stuck/incorrect value.
    }
  }

  void _onChanged(double v) {
    _fadeGen = (_fadeGen ?? 0) + 1; // cancel any in-progress fade
    final level = v.round();
    setState(() => _level = level);
    widget.player.engine.setMediaVolume(level);
  }

  /// Tapping the mute icon: smoothly steps volume down to 0, one tick at
  /// a time, instead of an instant jump — reads as a deliberate "fade
  /// out" rather than a hard cut.
  Future<void> _fadeToMute() async {
    final gen = (_fadeGen ?? 0) + 1;
    _fadeGen = gen;
    AurumHaptics.light();
    var v = _level;
    while (v > 0 && _fadeGen == gen && mounted) {
      v = (v - 1).clamp(0, _max);
      setState(() => _level = v);
      widget.player.engine.setMediaVolume(v);
      await Future.delayed(const Duration(milliseconds: 35));
    }
  }

  /// Tapping the speaker/max icon: jumps straight to full volume — no
  /// fade, immediate.
  void _jumpToMax() {
    _fadeGen = (_fadeGen ?? 0) + 1; // cancel any in-progress fade
    AurumHaptics.light();
    setState(() => _level = _max);
    widget.player.engine.setMediaVolume(_max);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox(height: 20);
    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _fadeToMute,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              _level == 0 ? Icons.volume_off_rounded : Icons.volume_mute_rounded,
              color: Colors.white.withOpacity(0.7),
              size: 20,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Colors.white.withOpacity(0.9),
              inactiveTrackColor: Colors.white.withOpacity(0.22),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: _level.toDouble().clamp(0, _max.toDouble()),
              min: 0,
              max: _max.toDouble(),
              onChanged: _onChanged,
            ),
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _jumpToMax,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.volume_up_rounded, color: Colors.white.withOpacity(0.7), size: 20),
          ),
        ),
      ],
    );
  }
}

class _BottomIconRow extends StatefulWidget {
  const _BottomIconRow({required this.player, required this.song});
  final PlayerProvider player;
  final Song song;

  @override
  State<_BottomIconRow> createState() => _BottomIconRowState();
}

class _BottomIconRowState extends State<_BottomIconRow> {
  @override
  void initState() {
    super.initState();
    // Rebuild when the sleep timer starts/ticks/ends so the moon icon's
    // filled/outline state always matches SleepTimerService.instance —
    // same mechanism _PremiumOptionsSheet uses for its own sleep row.
    SleepTimerService.instance.addListener(_onSleepTick);
  }

  @override
  void dispose() {
    SleepTimerService.instance.removeListener(_onSleepTick);
    super.dispose();
  }

  void _onSleepTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sleepActive = SleepTimerService.instance.isActive;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.reorder_rounded, color: Colors.white, size: 24),
              onPressed: () => _openQueueSheet(context),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.chat_bubble_outline_rounded, color: Colors.white, size: 22),
              onPressed: () => _openLyricsSheet(context),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(
                sleepActive ? Icons.bedtime_rounded : Icons.dark_mode_outlined,
                color: Colors.white,
                size: 22,
              ),
              onPressed: () => showSleepTimerForSong(context, widget.player),
            ),
          ],
        ),
        Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.14),
            borderRadius: BorderRadius.circular(19),
          ),
          child: GestureDetector(
            onTap: () => showAudioOutputSheet(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speaker_group_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 6),
                  Text('Speaker', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openQueueSheet(BuildContext context) {
    AurumHaptics.light();
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF141414),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: const _EdgeToEdgeQueueList(),
        ),
      ),
    );
  }

  void _openLyricsSheet(BuildContext context) {
    AurumHaptics.light();
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF141414),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: _EdgeToEdgeLyricsSheet(
            player: widget.player,
            song: widget.song,
            scrollController: scrollController,
          ),
        ),
      ),
    );
  }
}

/// Minimal, self-contained lyrics viewer for the Edge to Edge sheet —
/// fetches plain lyrics via PlayerProvider.fetchLyrics() (same API the
/// Card layout's immersive lyrics view uses) without depending on that
/// view's own animation-controller machinery.
class _EdgeToEdgeLyricsSheet extends StatefulWidget {
  const _EdgeToEdgeLyricsSheet({
    required this.player,
    required this.song,
    required this.scrollController,
  });
  final PlayerProvider player;
  final Song song;
  final ScrollController scrollController;

  @override
  State<_EdgeToEdgeLyricsSheet> createState() => _EdgeToEdgeLyricsSheetState();
}

class _EdgeToEdgeLyricsSheetState extends State<_EdgeToEdgeLyricsSheet> {
  String? _lyrics;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await widget.player.fetchLyrics();
      if (!mounted) return;
      setState(() {
        _lyrics = text;
        _loading = false;
        _failed = text == null || text.trim().isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Lyrics',
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: Colors.white54))
              : _failed
                  ? Center(
                      child: Text(
                        'Lyrics not available for this song',
                        style: TextStyle(color: Colors.white.withOpacity(0.6)),
                      ),
                    )
                  : SingleChildScrollView(
                      controller: widget.scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                      child: Text(
                        _lyrics ?? '',
                        style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.6),
                      ),
                    ),
        ),
      ],
    );
  }
}

/// Minimal, self-contained queue list for the Edge to Edge sheet — avoids
/// depending on full_player_screen.dart's private _QueuePage.
class _EdgeToEdgeQueueList extends StatelessWidget {
  const _EdgeToEdgeQueueList();

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, ({List<Song> queue, int? current})>(
      selector: (_, p) => (queue: p.queue, current: p.currentIndex),
      builder: (context, data, _) {
        final queue = data.queue;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 12),
          itemCount: queue.length,
          itemBuilder: (context, i) {
            final s = queue[i];
            final isCurrent = i == data.current;
            return ListTile(
              onTap: () => context.read<PlayerProvider>().skipToIndex(i),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: s.artworkUrl,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              ),
              title: Text(
                s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isCurrent ? AurumTheme.gold : Colors.white,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              subtitle: Text(
                s.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
              ),
            );
          },
        );
      },
    );
  }
}
