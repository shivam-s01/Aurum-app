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

import 'dart:ui';

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
import 'full_player_screen.dart'
    show showAurumFullPlayerOptionsSheet, showSleepTimerForSong, AurumLyricsPage;
import 'settings_player_screen.dart' show SleepTimerService;

class EdgeToEdgeFullPlayer extends StatefulWidget {
  const EdgeToEdgeFullPlayer({super.key});

  @override
  State<EdgeToEdgeFullPlayer> createState() => _EdgeToEdgeFullPlayerState();
}

class _EdgeToEdgeFullPlayerState extends State<EdgeToEdgeFullPlayer> {
  double _dragY = 0;
  bool _dragging = false;

  // Song-specific gradient stops — all four extracted from the current
  // artwork's palette (same ArtworkPaletteCache the Card layout's "Solid"
  // background style uses), each contrast-clamped for white text/icons on
  // top. Starts as safe dark neutrals before the first extraction resolves,
  // then updates per-song via _loadPaletteFor(). Kept as a single object so
  // the whole set animates together via TweenAnimationBuilder below.
  _PanelPalette _panel = const _PanelPalette(
    top: Color(0xFF1E1B2E),
    mid: Color(0xFF17141F),
    bottom: Color(0xFF0C0A12),
    glow: Color(0xFF2A2440),
  );
  // Previous palette, kept purely so the mesh/glow can tween FROM it to
  // the new _panel whenever the song (and therefore the palette) changes,
  // instead of _panel.glow being passed as both tween endpoints below.
  _PanelPalette _prevPanel = const _PanelPalette(
    top: Color(0xFF1E1B2E),
    mid: Color(0xFF17141F),
    bottom: Color(0xFF0C0A12),
    glow: Color(0xFF2A2440),
  );
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

  /// Boosts a color's saturation and pulls its brightness toward a target,
  /// the same way ArchiveTune's PlayerColorExtractor (Palette.Swatch →
  /// HSV boost) turns a flat/muted extracted swatch into a rich, punchy
  /// mesh-gradient color instead of a washed-out grey-red. Operates in
  /// HSV rather than lerping toward black/white, so hue is fully preserved.
  ///
  /// Deliberately has NO satFloor — Material You/Google's own dynamic
  /// color never invents saturation an image doesn't have; a genuinely
  /// pastel/desaturated cover (sketch art, a mostly-white poster) should
  /// still produce a neutral grey panel, not a forced-colorful one. Only a
  /// gentle multiplier (`satBoost`, ~1.15-1.3x) lifts a swatch that's
  /// already somewhat colorful into "rich" territory — it can't manufacture
  /// color that wasn't there, only sharpen what is.
  Color _boostColor(
    Color c, {
    required double satBoost,
    required double valueTarget,
    required double valueMin,
    required double valueMax,
  }) {
    final hsv = HSVColor.fromColor(c);
    final sat = (hsv.saturation * satBoost).clamp(0.0, 1.0);
    final val = (hsv.value * 0.6 + valueTarget * 0.4).clamp(valueMin, valueMax);
    return hsv.withSaturation(sat).withValue(val).toColor();
  }

  _PanelPalette _paletteFrom(ArtworkPalette p) {
    // Anchor everything on vibrant/lightVibrant (the actually-colorful
    // swatches) rather than `dominant`, which on a poster/photo cover can
    // just as easily land on a background sky, skin tone, or neutral —
    // nothing close to the rich thematic color (e.g. the poster's red)
    // that should be driving the mesh. `darkMuted` is kept only as the
    // deepest anchor for the bottom stop, same role the Kotlin extractor
    // gives its darkMutedSwatch.
    // `vibrant` already carries its own fallback chain in
    // artwork_palette_cache.dart (vibrant → lightVibrant → dominant), so
    // it's always a usable, real color here — no extra null/zero check
    // needed.
    final hueSource = p.vibrant;

    final top = ensureContrastSafe(
      _boostColor(
        hueSource,
        satBoost: 1.25,
        valueTarget: 0.58,
        valueMin: 0.14,
        valueMax: 0.58,
      ),
      isLight: false,
    );
    final mid = ensureContrastSafe(
      _boostColor(
        Color.lerp(hueSource, p.darkMuted, 0.35)!,
        satBoost: 1.2,
        valueTarget: 0.40,
        valueMin: 0.09,
        valueMax: 0.40,
      ),
      isLight: false,
    );
    final bottom = ensureContrastSafe(
      _boostColor(
        Color.lerp(hueSource, p.darkMuted, 0.7)!,
        satBoost: 1.15,
        valueTarget: 0.20,
        valueMin: 0.04,
        valueMax: 0.22,
      ),
      isLight: false,
    );
    // Glow stays bright — it's blurred/translucent, so it can sit well
    // outside the dark contrast-safe range the panel text needs, same as
    // the Kotlin extractor's separate un-clamped accent use. Still no
    // satFloor: a pastel cover gets a soft, pale glow, not a neon one.
    final glow = _boostColor(
      Color.lerp(hueSource, p.lightVibrant, 0.4)!,
      satBoost: 1.2,
      valueTarget: 0.85,
      valueMin: 0.5,
      valueMax: 0.95,
    );
    return _PanelPalette(top: top, mid: mid, bottom: bottom, glow: glow);
  }

  void _loadPaletteFor(String url) {
    if (url.isEmpty || url == _paletteUrl) return;
    _paletteUrl = url;

    // Cache hit — apply instantly, no flash of the fallback color.
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _prevPanel = _panel;
          _panel = _paletteFrom(cached);
        });
      }
      return;
    }

    ArtworkPaletteCache.get(url).then((palette) {
      if (!mounted || _paletteUrl != url) return;
      setState(() {
        _prevPanel = _panel;
        _panel = _paletteFrom(palette);
      });
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
                      // Reference design keeps art filling roughly the top
                      // ~58% of the screen, but the panel underneath is now
                      // an animated 3-stop mesh gradient (derived from the
                      // artwork's own palette) instead of a flat color —
                      // matches ArchiveTune's Material Extended-style
                      // artwork-driven theming instead of a single solid.
                      final artHeight = constraints.maxHeight * 0.58;
                      return Stack(
                        children: [
                          // ── Ambient glow: soft, oversized blurred blob
                          // of the extracted "glow" swatch sitting behind
                          // the artwork, bleeding light past its edges —
                          // this is what reads as "premium" vs a flat
                          // rectangle of art. Animates with the palette.
                          TweenAnimationBuilder<Color?>(
                            key: ValueKey('glow_${_panel.hashCode}'),
                            tween: ColorTween(begin: _prevPanel.glow, end: _panel.glow),
                            duration: const Duration(milliseconds: 600),
                            builder: (context, glow, _) => Positioned(
                              top: -60,
                              left: -40,
                              right: -40,
                              height: artHeight + 160,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: RadialGradient(
                                      center: const Alignment(0, -0.2),
                                      radius: 0.95,
                                      colors: [
                                        (glow ?? _panel.glow).withOpacity(0.55),
                                        (glow ?? _panel.glow).withOpacity(0.0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

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

                          // ── Top status-bar scrim: artwork now runs
                          // edge-to-edge under the status bar, so a short
                          // dark fade keeps the clock/battery legible on
                          // bright/busy covers without a hard bar. ──
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: MediaQuery.of(context).padding.top + 36,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withOpacity(0.45),
                                      Colors.black.withOpacity(0.0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // ── Glass blend zone: art and panel now merge
                          // into one continuous surface instead of a hard
                          // cut. Two stacked effects, both anchored just
                          // above the art/panel boundary and fading
                          // upward into nothing:
                          //   1) a real optical blur (BackdropFilter) over
                          //      the art itself, growing stronger toward
                          //      the bottom — this is the "haze/dhundhla"
                          //      frosted-glass look, not just a color fade.
                          //   2) the panel's own top color, semi-
                          //      transparent up top and solidifying into
                          //      the panel below, so the mesh's hue visibly
                          //      bleeds upward onto the artwork instead of
                          //      the two areas reading as separate blocks.
                          Positioned(
                            top: artHeight - 190,
                            left: 0,
                            right: 0,
                            height: 190,
                            child: IgnorePointer(
                              child: ClipRect(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.transparent,
                                          Colors.transparent,
                                          _panel.top.withOpacity(0.55),
                                          _panel.top,
                                        ],
                                        stops: const [0.0, 0.25, 0.75, 1.0],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // ── Animated 3-stop mesh panel: bottom section.
                          // Cross-fades smoothly between songs instead of
                          // snapping to the new palette instantly. ──
                          Positioned(
                            top: artHeight,
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: TweenAnimationBuilder<double>(
                              key: ValueKey('mesh_${_panel.hashCode}'),
                              tween: Tween(begin: 0, end: 1),
                              duration: const Duration(milliseconds: 500),
                              curve: Curves.easeOut,
                              builder: (context, t, __) => DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color.lerp(_prevPanel.top, _panel.top, t)!,
                                      Color.lerp(_prevPanel.mid, _panel.mid, t)!,
                                      Color.lerp(_prevPanel.bottom, _panel.bottom, t)!,
                                    ],
                                    stops: const [0.0, 0.45, 1.0],
                                  ),
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
                                  _ScrubBar(player: player, accent: _panel.glow),
                                  const SizedBox(height: 16),
                                  _TransportRow(
                                    player: player,
                                    accent: _panel.glow,
                                    prevAccent: _prevPanel.glow,
                                  ),
                                  const SizedBox(height: 26),
                                  _VolumeRow(player: player),
                                  const SizedBox(height: 32),
                                  _BottomIconRow(player: player, song: song, panel: _panel),
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

/// Bundles the three mesh-gradient stops plus a brighter "glow" swatch
/// used for the ambient blur and accent tints, so the whole set can be
/// swapped and animated together per-song instead of as four loose colors.
class _PanelPalette {
  const _PanelPalette({
    required this.top,
    required this.mid,
    required this.bottom,
    required this.glow,
  });
  final Color top;
  final Color mid;
  final Color bottom;
  final Color glow;

  @override
  bool operator ==(Object other) =>
      other is _PanelPalette &&
      other.top == top &&
      other.mid == mid &&
      other.bottom == bottom &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(top, mid, bottom, glow);
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
  const _ScrubBar({required this.player, required this.accent});
  final PlayerProvider player;
  final Color accent;

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
        // Active track/thumb pick up the artwork's accent color (lifted
        // toward white so it always reads clearly against the dark mesh)
        // instead of plain white — same idea as ArchiveTune's palette-tinted
        // player chrome, applied to the scrub bar specifically.
        final tint = Color.lerp(widget.accent, Colors.white, 0.35)!;
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                overlayColor: tint.withOpacity(0.2),
                activeTrackColor: tint,
                inactiveTrackColor: Colors.white.withOpacity(0.22),
                thumbColor: tint,
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
                  // Center codec-style pill — same slot the ArchiveTune
                  // reference fills with "OPUS"; this app doesn't expose a
                  // codec badge, so it's relabeled to the app's own name
                  // as a simple center brand mark instead of leaving the
                  // slot empty (which would put the two time labels far
                  // apart with nothing to visually anchor the middle).
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.graphic_eq_rounded, color: Colors.white.withOpacity(0.85), size: 13),
                        const SizedBox(width: 5),
                        Text(
                          'Astra',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
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
  const _TransportRow({
    required this.player,
    required this.accent,
    required this.prevAccent,
  });
  final PlayerProvider player;
  final Color accent;
  final Color prevAccent;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (bool, bool)>(
      selector: (_, p) => (p.isPlaying, p.isLoading),
      builder: (context, data, _) {
        final (isPlaying, isLoading) = data;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // Double-chevron rewind — matches the reference's "◀◀" seek/
            // skip-back glyph instead of the single skip_previous triangle.
            IconButton(
              iconSize: 34,
              icon: const Icon(Icons.fast_rewind_rounded, color: Colors.white),
              onPressed: () {
                AurumHaptics.light();
                player.skipPrev();
              },
            ),
            // Play/pause: reference uses a small thin-outline circle (no
            // fill, no shadow) rather than a big solid white disc — the
            // artwork-derived glow now lives in the ring stroke color
            // instead of a drop shadow, so it still visually "belongs" to
            // the current cover without competing with the mesh panel.
            TweenAnimationBuilder<Color?>(
              key: ValueKey('play_glow_${accent.value}'),
              tween: ColorTween(begin: prevAccent, end: accent),
              duration: const Duration(milliseconds: 500),
              builder: (context, animatedAccent, _) {
                final ringColor = Color.lerp(animatedAccent ?? accent, Colors.white, 0.55)!;
                return GestureDetector(
                  onTap: () {
                    AurumHaptics.medium();
                    player.togglePlay();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: ringColor.withOpacity(0.9), width: 2),
                    ),
                    alignment: Alignment.center,
                    child: isLoading
                        ? const Padding(
                            padding: EdgeInsets.all(15),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : AurumPlayPauseIcon(isPlaying: isPlaying, color: Colors.white, size: 26),
                  ),
                );
              },
            ),
            // Double-chevron fast-forward — matches the reference's "▶▶".
            IconButton(
              iconSize: 34,
              icon: const Icon(Icons.fast_forward_rounded, color: Colors.white),
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
  const _BottomIconRow({required this.player, required this.song, required this.panel});
  final PlayerProvider player;
  final Song song;
  final _PanelPalette panel;

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
    // Old sheet is gone — lyrics now open as a dedicated full-screen,
    // animated overlay (see _EdgeToEdgeImmersiveLyrics) instead of a
    // bottom sheet, matching the reference: small top-left artwork, X to
    // close, blurred palette background, and synced lines that scroll/
    // highlight live with playback — not a drawer sliding up from the
    // bottom.
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 340),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => _EdgeToEdgeImmersiveLyrics(
          song: widget.song,
          panel: widget.panel,
        ),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }
}

/// Full-screen immersive lyrics view for the Edge to Edge player —
/// replaces the old bottom-sheet lyrics drawer entirely. Matches the
/// reference: a small top-left artwork thumbnail (not the big hero art),
/// title/artist next to it, X-to-close and a ••• menu on the top-right,
/// a blurred version of the current mesh palette as the full-screen
/// background, and the actual lyrics content reusing AurumLyricsPage —
/// the same self-contained fetch/sync/scroll/glow-highlight widget the
/// Card layout's own immersive lyrics view is built on, so line-by-line
/// highlighting and auto-scroll behave identically here.
class _EdgeToEdgeImmersiveLyrics extends StatefulWidget {
  const _EdgeToEdgeImmersiveLyrics({
    required this.song,
    required this.panel,
  });
  final Song song;
  final _PanelPalette panel;

  @override
  State<_EdgeToEdgeImmersiveLyrics> createState() => _EdgeToEdgeImmersiveLyricsState();
}

class _EdgeToEdgeImmersiveLyricsState extends State<_EdgeToEdgeImmersiveLyrics>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Drives the entrance choreography below (background fade-in, thumbnail
    // settle, lyrics rise-in) — one shared timeline so every piece lands in
    // the same coordinated beat instead of several independent implicit
    // animations starting/finishing at slightly different times.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    AurumHaptics.light();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(_controller.value);
            return Stack(
              fit: StackFit.expand,
              children: [
                // ── Blurred palette background: same mesh gradient the
                // player itself is showing, so the lyrics screen reads as
                // a continuation of the same surface rather than a
                // different screen — then a heavy blur on top of that
                // gradient plus a softly blurred, oversized copy of the
                // artwork gives it real depth instead of a flat color.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [widget.panel.top, widget.panel.mid, widget.panel.bottom],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
                if (widget.song.artworkUrl.isNotEmpty)
                  Opacity(
                    opacity: 0.35,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
                      child: CachedNetworkImage(
                        imageUrl: widget.song.artworkUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                // Darkening scrim so lyrics text stays legible regardless
                // of how bright the blurred artwork underneath is.
                DecoratedBox(decoration: BoxDecoration(color: Colors.black.withOpacity(0.38))),

                // ── Foreground: header row + lyrics, fading/rising in
                // together as the overlay opens. ──
                Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * 16),
                    child: SafeArea(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                            child: Row(
                              children: [
                                // Small top-left artwork thumbnail — a
                                // Hero back to the same tag the main
                                // player's big artwork uses, so closing
                                // this screen morphs it back smoothly
                                // instead of a hard cut.
                                Hero(
                                  tag: 'aurum_art_${widget.song.id}',
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: widget.song.artworkUrl.isNotEmpty
                                        ? CachedNetworkImage(
                                            imageUrl: widget.song.artworkUrl,
                                            width: 52,
                                            height: 52,
                                            fit: BoxFit.cover,
                                          )
                                        : Container(
                                            width: 52,
                                            height: 52,
                                            color: AurumTheme.darkBgElevated,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        widget.song.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        widget.song.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.7),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _CircleIconButton(
                                  icon: Icons.close_rounded,
                                  onTap: _close,
                                ),
                                const SizedBox(width: 10),
                                _CircleIconButton(
                                  icon: Icons.more_horiz_rounded,
                                  onTap: () => showAurumFullPlayerOptionsSheet(
                                    context,
                                    widget.song,
                                    accentColor: AurumTheme.gold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Reuses the exact same self-contained widget the
                          // Card layout's immersive lyrics view uses — full
                          // fetch/sync/scroll/highlight/glow behavior comes
                          // along for free and stays in sync between both
                          // full-player layouts automatically.
                          const Expanded(child: AurumLyricsPage()),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
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
