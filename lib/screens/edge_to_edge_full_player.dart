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
import '../widgets/aurum_seek_bar.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/aurum_play_pause_icon.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/audio_output_sheet.dart';
import '../widgets/aurum_artwork.dart' show AurumArtwork;
import '../services/native_engine_bridge.dart'
    show MediaVolume, AudioOutputDevice, AudioOutputDeviceKind, AudioOutputDevices;
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
import '../l10n/generated/app_localizations.dart';
import '../widgets/premium_gate.dart';
import 'full_player_screen.dart'
    show showAurumFullPlayerOptionsSheet, showSleepTimerForSong, showSongInfoDialog, AurumLyricsPage;
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

  // FIX (screen can get stuck mid-drag): if the gesture arena takes the
  // pointer away mid-drag (e.g. a competing scroll/list inside the sheet
  // wins resolution) with no onVerticalDragEnd ever firing, _dragging and
  // _dragY had no way back to a clean state — the player would sit
  // visually frozen half-dismissed (partially scaled/faded/translated)
  // until another drag happened to reset it. Same class of bug the Card
  // layout's FullPlayerScreen already guards against with its own
  // onVerticalDragCancel handler; this treats it exactly like a
  // below-threshold release — spring back to fully open.
  void _handleDragCancel() {
    if (!mounted) return;
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
    // Anchor on the top-ranked color from PlayerColorExtractor —
    // ArchiveTune's own population*vibrancyBonus-weighted winner (see
    // player_color_extractor.dart, ported 1:1 from PlayerColorExtractor.kt)
    // — instead of unconditionally using `vibrant`. On any given artwork
    // crop the winning swatch might be dominant, muted, or darkVibrant
    // rather than vibrant; hardcoding `vibrant` here is exactly why this
    // app's mesh color could disagree with ArchiveTune's own player for
    // the *same* artwork. Falls back to the old vibrant-chain only if
    // gradientColors somehow came back empty (shouldn't happen — the
    // extractor always returns at least one color).
    final hueSource =
        p.gradientColors.isNotEmpty ? p.gradientColors.first : p.vibrant;

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
        // FIX ("YouTube jaisa akward lag raha hai" part 2): opacity used
        // to start dropping from the very first pixel of drag (1 -
        // dragY/500), so by the time the card had moved barely 60-70px it
        // was already visibly fading — well before the card was anywhere
        // near actually leaving the screen. That reads as a translucent,
        // half-there card for most of the gesture instead of a solid card
        // that slides cleanly away. YouTube's own full-player dismiss
        // keeps the card fully opaque for almost the whole drag and only
        // fades right at the very end, once it's basically already
        // off-screen — same "hold opacity, then fade at the finish" curve
        // the Card layout (full_player_screen.dart's _DragTransform)
        // already uses, scaled here to this screen's own max drag range
        // (600, from _handleDragUpdate's clamp) rather than the dismiss
        // threshold — using the threshold directly would make the card
        // vanish mid-drag any time someone holds past 140px without
        // releasing, which is worse than the original bug.
        final dismissProgress = (_dragY / 500).clamp(0.0, 1.0);
        final opacity = 1.0 - ((dismissProgress - 0.75) / 0.25).clamp(0.0, 1.0);

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: Scaffold(
            // FIX (swipe-down shows solid black instead of the Home screen
            // behind it): this was `Colors.black`. The route this screen is
            // pushed on is `opaque: false` specifically so Home keeps
            // rendering live frames underneath during the drag (see
            // home_screen.dart's PageRouteBuilder comment) — but a fully
            // opaque black Scaffold background here painted over that live
            // Home frame on every single frame regardless, so the "reveal
            // Home while dragging" effect never had anywhere to show
            // through. Transparent lets Home itself be what's visible
            // around/behind the shrinking, fading player card as it's
            // dragged down, instead of a black void.
            backgroundColor: Colors.transparent,
            body: GestureDetector(
              onVerticalDragUpdate: _handleDragUpdate,
              onVerticalDragEnd: _handleDragEnd,
              onVerticalDragCancel: _handleDragCancel,
              child: AnimatedContainer(
                duration: _dragging ? Duration.zero : const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                // FIX ("YouTube jaisa drag akward lag raha hai" — root
                // cause): transformAlignment was Alignment.center, so the
                // scale-down during drag shrunk the card equally from ALL
                // four edges — that opens up a visible gap at the TOP too
                // as you drag down, which reads as the whole card
                // floating/detaching from the top of the screen instead
                // of just sliding down and off. YouTube's own full-player
                // dismiss never opens a top gap — the card stays pinned to
                // the top edge and only the BOTTOM edge recedes as it
                // shrinks, so it reads as one continuous downward slide,
                // not a shape floating in space. topCenter anchors the
                // scale there instead of the middle, which is the exact
                // fix: same translate-down + shrink motion, just anchored
                // at the edge that should never move.
                transform: Matrix4.translationValues(0, _dragY, 0)..scale(scale, scale),
                transformAlignment: Alignment.topCenter,
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
                                      // Upgrades the list-sized artworkUrl
                                      // to a sharper version for this
                                      // full-width edge-to-edge hero image
                                      // — see AurumArtwork.upgradeForFullPlayer.
                                      imageUrl: AurumArtwork.upgradeForFullPlayer(song.artworkUrl),
                                      fit: BoxFit.cover,
                                      fadeInDuration: const Duration(milliseconds: 220),
                                      errorWidget: (_, __, ___) =>
                                          Container(color: AurumTheme.bgElevatedOf(context)),
                                    )
                                  : Container(color: AurumTheme.bgElevatedOf(context)),
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

                          // ── Blend zone: art and panel merge into one
                          // continuous surface via a pure color fade — no
                          // optical blur (BackdropFilter removed; it was
                          // smearing busy/high-detail artwork into an
                          // awkward muddy band right at the seam). Tall,
                          // gradual 6-stop fade (mirrors ArchiveTune's own
                          // scrim: art stays crisp almost all the way down,
                          // then eases into the panel color with no visible
                          // edge/line) — starts nearly invisible, ends
                          // exactly on _panel.top so there's zero color
                          // jump at the artHeight boundary where the solid
                          // mesh panel picks up.
                          Positioned(
                            top: artHeight - 280,
                            left: 0,
                            right: 0,
                            height: 280,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      _panel.top.withOpacity(0.06),
                                      _panel.top.withOpacity(0.20),
                                      _panel.top.withOpacity(0.45),
                                      _panel.top.withOpacity(0.78),
                                      _panel.top,
                                    ],
                                    stops: const [0.0, 0.35, 0.55, 0.72, 0.87, 1.0],
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
                accentColor: AurumTheme.accentOf(context),
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

/// Smaller sibling of _CircleIconButton for the bottom icon row (queue /
/// lyrics / sleep) — same flat, borderless, translucent circle-pill
/// treatment as the top ••• / heart buttons and the Speaker pill, just
/// sized to sit comfortably in a tighter row of three instead of two.
/// Reference screenshot has all of these — top corner actions, bottom row
/// icons, and the output pill — sharing one consistent "soft dark circle"
/// language; this was the one row still rendering as bare icons with no
/// pill at all.
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(0.14),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 19),
      ),
    );
  }
}

// Thin wrapper around the shared AurumSeekBar (see widgets/aurum_seek_bar.dart)
// so every "Player Slider Style" option (Slim/Thick/Rounded/Waveform) looks
// and behaves EXACTLY like the classic full player — this used to be its own
// hand-rolled Slider that ignored the setting entirely, so picking e.g.
// "Waveform" only ever applied on the classic full player screen, never here.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({required this.player, required this.accent});
  final PlayerProvider player;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // Active track/thumb pick up the artwork's accent color (lifted toward
    // white so it always reads clearly against the dark mesh) — same tint
    // logic the old implementation used, now just fed into AurumSeekBar.
    final tint = Color.lerp(accent, Colors.white, 0.35)!;
    return AurumSeekBar(
      player: player,
      hPad: 4,
      activeColor: tint,
      inactiveColor: Colors.white.withOpacity(0.22),
      timeColor: Colors.white.withOpacity(0.75),
      // Center codec-style pill — same slot the ArchiveTune reference fills
      // with "OPUS"; this app doesn't expose a codec badge, so it's
      // relabeled to the app's own name as a simple center brand mark
      // instead of leaving the slot empty (which would put the two time
      // labels far apart with nothing to visually anchor the middle).
      centerLabel: Container(
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
            // Play/pause: reference (ArchiveTune) shows the bare morphing
            // glyph directly in the row — no circle, no ring, no border —
            // sitting flush alongside the rewind/forward icons as one
            // clean set of three. Matches that exactly now: just the icon,
            // slightly larger since there's no ring to frame it anymore.
            GestureDetector(
              onTap: () {
                AurumHaptics.medium();
                player.togglePlay();
              },
              child: SizedBox(
                width: 56,
                height: 56,
                child: Center(
                  child: isLoading
                      ? const SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            valueColor: AlwaysStoppedAnimation(Colors.white),
                          ),
                        )
                      : AurumPlayPauseIcon(isPlaying: isPlaying, color: Colors.white, size: 34),
                ),
              ),
            ),
            // Double-chevron fast-forward — matches the reference's "▶▶".
            IconButton(
              iconSize: 34,
              icon: const Icon(Icons.fast_forward_rounded, color: Colors.white),
              onPressed: () {
                AurumHaptics.light();
                // FIX ("perfect work krega na" recheck — real gap found):
                // skipNext() returns false (without skipping) once the
                // free-tier skip limit is hit — see player_provider.dart's
                // own "caller shows PremiumGate" comment. The Card
                // layout's transport row already checks this and shows
                // the sign-in/upgrade sheet; this row was ignoring the
                // return value entirely, so on this layout hitting the
                // limit just silently did nothing — the button looked
                // unresponsive/broken with zero explanation instead of
                // telling the user why. Now matches Card layout exactly.
                player.skipNext().then((allowed) {
                  if (!allowed && context.mounted) {
                    PremiumGate.show(
                      context,
                      feature: AppLocalizations.of(context)!.fpUnlimitedSkipsFeature,
                      description: AppLocalizations.of(context)!.fpUnlimitedSkipsSignIn,
                      requiresLoginOnly: true,
                    );
                  }
                });
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
  // True only while the user's thumb/tap is actively driving the level —
  // guards against the live mediaVolumeStream (hardware keys, another
  // app, or this row's own setMediaVolume echoing back) yanking the
  // slider or fade-to-mute animation out from under an in-progress
  // interaction. Same pattern as audio_output_sheet.dart's _isDragging.
  bool _userDriving = false;

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
    setState(() => _userDriving = true);
    var v = _level;
    while (v > 0 && _fadeGen == gen && mounted) {
      v = (v - 1).clamp(0, _max);
      setState(() => _level = v);
      widget.player.engine.setMediaVolume(v);
      await Future.delayed(const Duration(milliseconds: 35));
    }
    if (mounted) setState(() => _userDriving = false);
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
    // LIVE FIX ("valum live ekdam sahi se connect kro" — volume row didn't
    // move when changed via hardware keys or another app, exactly the bug
    // already fixed for audio_output_sheet.dart's slider): wrap in the
    // same mediaVolumeStream StreamBuilder so this row updates instantly
    // from ANY source, not just its own onChanged. _userDriving keeps the
    // live value from fighting an active drag/fade the same way
    // audio_output_sheet.dart's _isDragging does.
    return StreamBuilder<MediaVolume?>(
      stream: widget.player.engine.mediaVolumeStream,
      builder: (context, snapshot) {
        final live = snapshot.data;
        final level = (!_userDriving && live != null) ? live.level : _level;
        final max = (!_userDriving && live != null && live.max > 0) ? live.max : _max;
        return Row(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _fadeToMute,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  level == 0 ? Icons.volume_off_rounded : Icons.volume_mute_rounded,
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
                  value: level.toDouble().clamp(0, max.toDouble()),
                  min: 0,
                  max: max.toDouble(),
                  onChangeStart: (_) => setState(() {
                    // Seed local state from whatever was showing (live or
                    // last-known) so the drag starts from the visible
                    // thumb position, not a possibly-stale _level.
                    _level = level;
                    _max = max;
                    _userDriving = true;
                  }),
                  onChanged: _onChanged,
                  onChangeEnd: (_) => setState(() => _userDriving = false),
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
      },
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
  AudioOutputDevices? _initialDevices;

  @override
  void initState() {
    super.initState();
    // Rebuild when the sleep timer starts/ticks/ends so the moon icon's
    // filled/outline state always matches SleepTimerService.instance —
    // same mechanism _PremiumOptionsSheet uses for its own sleep row.
    SleepTimerService.instance.addListener(_onSleepTick);
    // outputDevicesStream only carries LIVE change events (connect/
    // disconnect) — getAudioOutputDevices() is the one-shot snapshot call
    // and does not itself feed that stream (see native_engine_bridge.dart:
    // _outputDevices is only ever `.add()`-ed from the native EventChannel
    // listener). Without fetching + holding this locally, the pill would
    // sit on the "Speaker" fallback until the next connect/disconnect
    // happened to fire, or until the user opened the full output sheet
    // (which does its own separate fetch) at least once this session.
    widget.player.engine.getAudioOutputDevices().then((d) {
      if (mounted) setState(() => _initialDevices = d);
    });
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
            // FIX ("dusre app jaisa beautiful, top grade" — screenshot
            // shows queue/lyrics/sleep sitting inside their own soft
            // translucent circle pill, same as the ••• and heart buttons
            // up top — these were plain naked IconButtons with no
            // background at all, which is exactly the "less premium"
            // difference from the reference. Wrapped each in the same
            // flat circle-pill treatment _CircleIconButton already uses
            // above, just a touch smaller to match this row's icon size.
            _RoundIconButton(
              icon: Icons.reorder_rounded,
              onTap: () => _openQueueSheet(context),
            ),
            const SizedBox(width: 10),
            _RoundIconButton(
              icon: Icons.chat_bubble_outline_rounded,
              onTap: () => _openLyricsSheet(context),
            ),
            const SizedBox(width: 10),
            _RoundIconButton(
              icon: sleepActive ? Icons.bedtime_rounded : Icons.dark_mode_outlined,
              onTap: () => showSleepTimerForSong(context, widget.player),
            ),
          ],
        ),
        // LIVE FIX ("blootooth wala bhe connect kro jo connect ho wahi
        // show ho" — pill was hardcoded to the text "Speaker" regardless
        // of actual output): now reads engine.outputDevicesStream, the
        // same live device stream audio_output_sheet.dart already uses,
        // so this shows whichever device (phone speaker / wired / the
        // connected Bluetooth headset's real name) is actually selected,
        // and updates the instant a Bluetooth device connects or
        // disconnects — no need to reopen the sheet.
        StreamBuilder<AudioOutputDevices?>(
          stream: widget.player.engine.outputDevicesStream,
          builder: (context, snapshot) {
            // Live stream event (a connect/disconnect firing after mount)
            // takes priority once it arrives; until then, fall back to
            // the one-shot snapshot fetched in initState above.
            final devices = snapshot.data ?? _initialDevices;
            AudioOutputDevice? selected;
            for (final d in devices?.devices ?? const <AudioOutputDevice>[]) {
              if (d.selected) {
                selected = d;
                break;
              }
            }
            final icon = switch (selected?.kind) {
              AudioOutputDeviceKind.bluetooth => Icons.bluetooth_audio_rounded,
              AudioOutputDeviceKind.wired => Icons.headphones_rounded,
              AudioOutputDeviceKind.usb => Icons.usb_rounded,
              AudioOutputDeviceKind.speaker => Icons.smartphone_rounded,
              _ => Icons.speaker_group_rounded,
            };
            final label = selected?.name ?? 'Speaker';
            return Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(19),
              ),
              child: GestureDetector(
                onTap: () => showAudioOutputSheet(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 18),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 110),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _openQueueSheet(BuildContext context) {
    AurumHaptics.light();
    final song = context.read<PlayerProvider>().currentSong;
    // Snapshot the panel palette at open-time so the sheet's tint doesn't
    // jump mid-scroll if the underlying song happens to change while it's
    // open (matches the reference: the sheet carries the color of whatever
    // song was playing when it was opened).
    final panel = widget.panel;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        expand: false,
        builder: (context, scrollController) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: DecoratedBox(
            // Artwork-palette-tinted background — same top/mid/bottom mesh
            // the player itself is showing, so the sheet reads as a
            // continuation of the current song's color rather than a
            // separate flat-grey surface. Matches the reference exactly.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [panel.top, panel.mid, panel.bottom],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
            child: _EdgeToEdgeQueueSheetBody(
              scrollController: scrollController,
              currentSong: song,
              panel: panel,
            ),
          ),
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
                                            color: AurumTheme.bgElevatedOf(context),
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
                                    accentColor: AurumTheme.accentOf(context),
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
/// Full "Up Next" sheet body — header (artwork + title/artist + favorite),
/// action row (lock/menu/delete + song count & total duration), a 3-button
/// mode row (shuffle / move-mode toggle / repeat), a "Continue Playing"
/// section header, then the reorderable queue itself. Every control here is
/// wired to real PlayerProvider/FavoritesProvider state — nothing is
/// decorative filler copied from the reference screenshot without a real
/// action behind it.
class _EdgeToEdgeQueueSheetBody extends StatefulWidget {
  const _EdgeToEdgeQueueSheetBody({
    required this.scrollController,
    required this.currentSong,
    required this.panel,
  });

  final ScrollController scrollController;
  final Song? currentSong;
  final _PanelPalette panel;

  @override
  State<_EdgeToEdgeQueueSheetBody> createState() => _EdgeToEdgeQueueSheetBodyState();
}

class _EdgeToEdgeQueueSheetBodyState extends State<_EdgeToEdgeQueueSheetBody> {
  // Lock icon in the reference toggles whether rows can be dragged to
  // reorder at all — starts locked (matches the reference's default
  // padlock-closed state) so an accidental touch on the drag handle
  // doesn't reorder the queue.
  bool _reorderLocked = true;

  String _totalDuration(List<Song> queue) {
    final totalSeconds = queue.fold<int>(0, (sum, s) => sum + (s.duration ?? 0));
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    return '${m}m ${s}s';
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.currentSong;
    final panel = widget.panel;
    return Selector<PlayerProvider, ({List<Song> queue, int? current})>(
      selector: (_, p) => (queue: p.queue, current: p.currentIndex),
      builder: (context, data, _) {
        final queue = data.queue;
        return Column(
          children: [
            const SizedBox(height: 10),
            // ── Drag handle ──
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            // ── Header: artwork + title/artist + favorite ──
            if (song != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: song.artworkUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: song.artworkUrl,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            )
                          : Container(width: 64, height: 64, color: AurumTheme.bgElevatedOf(context)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                    Selector<FavoritesProvider, bool>(
                      selector: (_, f) => f.isFavorite(song.id),
                      builder: (context, isFav, _) => IconButton(
                        icon: Icon(
                          isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          AurumHaptics.light();
                          context.read<FavoritesProvider>().toggleFavorite(song);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            // ── Action row: lock / overflow / delete-queue + song count & duration ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _reorderLocked ? Icons.lock_outline_rounded : Icons.lock_open_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () {
                        AurumHaptics.light();
                        setState(() => _reorderLocked = !_reorderLocked);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        if (song != null) {
                          showAurumFullPlayerOptionsSheet(context, song, accentColor: panel.glow);
                        }
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, color: Colors.white.withOpacity(0.75), size: 20),
                      onPressed: queue.isEmpty
                          ? null
                          : () async {
                              AurumHaptics.medium();
                              // Clears every queued item except the one
                              // currently playing, mirroring the reference's
                              // trash icon (clear Up Next, not stop
                              // playback).
                              //
                              // FIX: this used to loop over a captured
                              // `data.current` index taken once before the
                              // loop started. removeFromQueue() shifts
                              // _currentIndex internally every time it
                              // removes an item that sits before the
                              // current song — so after even one removal,
                              // the stale `data.current` no longer pointed
                              // at the actually-playing song, and a
                              // subsequent iteration could delete the
                              // wrong item, including the song currently
                              // playing. Re-reading the live queue/current
                              // song by identity on every iteration instead
                              // of trusting a snapshot index avoids that
                              // entirely.
                              final player = context.read<PlayerProvider>();
                              final playingSong = player.currentSong;
                              for (var i = player.queue.length - 1; i >= 0; i--) {
                                if (!identical(player.queue[i], playingSong)) {
                                  await player.removeFromQueue(i);
                                }
                              }
                            },
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        '${queue.length} songs  •  ${_totalDuration(queue)}',
                        style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            // ── Mode row: shuffle / reorder-mode toggle / repeat ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Selector<PlayerProvider, (bool, LoopMode)>(
                selector: (_, p) => (p.shuffle, p.loopMode),
                builder: (context, data2, _) {
                  final (shuffleOn, loop) = data2;
                  return Row(
                    children: [
                      Expanded(
                        child: _QueueModeButton(
                          icon: Icons.shuffle_rounded,
                          active: shuffleOn,
                          panel: panel,
                          onTap: () {
                            AurumHaptics.light();
                            context.read<PlayerProvider>().toggleShuffle();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _QueueModeButton(
                          icon: Icons.swap_vert_rounded,
                          active: !_reorderLocked,
                          panel: panel,
                          onTap: () {
                            AurumHaptics.light();
                            setState(() => _reorderLocked = !_reorderLocked);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _QueueModeButton(
                          icon: loop == LoopMode.one
                              ? Icons.repeat_one_rounded
                              : Icons.all_inclusive_rounded,
                          active: loop != LoopMode.off,
                          panel: panel,
                          onTap: () {
                            AurumHaptics.light();
                            context.read<PlayerProvider>().toggleLoop();
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 22),
            // ── "Continue Playing" section header ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Continue Playing',
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Autoplaying similar music',
                    style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Divider(color: Colors.white.withOpacity(0.12), height: 1),
            // ── Reorderable queue ──
            Expanded(
              child: queue.isEmpty
                  ? Center(
                      child: Text(
                        'Queue is empty',
                        style: TextStyle(color: Colors.white.withOpacity(0.5)),
                      ),
                    )
                  : ReorderableListView.builder(
                      scrollController: widget.scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      buildDefaultDragHandles: false,
                      itemCount: queue.length,
                      onReorder: (oldIndex, newIndex) {
                        if (_reorderLocked) return;
                        AurumHaptics.light();
                        if (newIndex > oldIndex) newIndex -= 1;
                        context.read<PlayerProvider>().moveQueueItem(oldIndex, newIndex);
                      },
                      itemBuilder: (context, i) {
                        final s = queue[i];
                        final isCurrent = i == data.current;
                        final row = Container(
                          // FIX: keying by index (`queue_${s.id}_$i`) gave
                          // every item a NEW key on every reorder (since its
                          // index changed), which defeats the whole point of
                          // ReorderableListView's key-based item tracking —
                          // it uses the key to know which visual item is
                          // "the same one" moving to a new slot vs a
                          // genuinely new item, and a key that always
                          // changes on reorder produces wrong/glitchy drag
                          // animations, and outright duplicate-key crashes
                          // the moment the same song appears twice in the
                          // queue (two Up Next entries would share both id
                          // AND index-independent identity otherwise).
                          // identityHashCode is stable per Song *instance*
                          // (Song has no == override, so two queue entries
                          // for the same song are still distinct objects)
                          // and doesn't change when the list is reordered —
                          // exactly what ReorderableListView needs.
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          decoration: BoxDecoration(
                            color: isCurrent ? panel.glow.withOpacity(0.32) : Colors.transparent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: s.artworkUrl.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: s.artworkUrl,
                                        width: 52,
                                        height: 52,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(width: 52, height: 52, color: AurumTheme.bgElevatedOf(context)),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    AurumHaptics.light();
                                    context.read<PlayerProvider>().skipToIndex(i);
                                  },
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        s.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${s.artist} • ${s.durationString}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              // FIX ("up next panel mein kaam nahi kar raha"
                              // — real gap found: this row's ••• used to
                              // open the generic song-options sheet (Play
                              // Next / Add to Queue / Like / Share / Save to
                              // Playlist / Audio Effects / Sleep Timer /
                              // Download / Song Info) — NONE of which can
                              // remove a single song from the queue or move
                              // it to the top. The only removal path left
                              // was the trash icon, which nukes the ENTIRE
                              // queue, not just this one row. Swapped for a
                              // queue-specific quick-actions menu — same
                              // Play Next / Move to Top / Remove set the
                              // Card layout's own _QueueTile already offers
                              // — so a single unwanted song can actually be
                              // taken out.
                              IconButton(
                                icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 18),
                                onPressed: () => _showQueueItemActions(
                                  context,
                                  song: s,
                                  index: i,
                                  isCurrent: isCurrent,
                                  accentColor: panel.glow,
                                ),
                              ),
                              // Drag handle — only actually draggable when
                              // unlocked, matching the reference's lock icon
                              // gating whether the "=" handles do anything.
                              ReorderableDragStartListener(
                                index: i,
                                enabled: !_reorderLocked,
                                child: Icon(
                                  Icons.drag_handle_rounded,
                                  color: Colors.white.withOpacity(_reorderLocked ? 0.25 : 0.85),
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        );

                        // FIX (same gap as above, second half): rows had no
                        // swipe-to-delete either — Card layout's queue rows
                        // support a horizontal swipe as a fast one-song
                        // removal alongside the drag handle. The current
                        // song is excluded from Dismissible (removing the
                        // song that's actively playing out of the "Up
                        // Next" list isn't a meaningful action here) so it
                        // stays exactly as a plain, undismissible Container
                        // — everything else can be swiped away.
                        if (isCurrent) {
                          return KeyedSubtree(
                            key: ValueKey(identityHashCode(s)),
                            child: row,
                          );
                        }
                        return Dismissible(
                          key: ValueKey(identityHashCode(s)),
                          direction: DismissDirection.horizontal,
                          background: _dismissBackground(alignStart: true),
                          secondaryBackground: _dismissBackground(alignStart: false),
                          onDismissed: (_) {
                            AurumHaptics.medium();
                            context.read<PlayerProvider>().removeFromQueue(i);
                          },
                          child: row,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  /// Backdrop revealed behind a queue row while it's mid-swipe — a plain
  /// rounded red delete affordance, aligned to whichever edge the swipe
  /// is coming from so it never looks mirrored/wrong depending on swipe
  /// direction.
  Widget _dismissBackground({required bool alignStart}) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: alignStart ? Alignment.centerLeft : Alignment.centerRight,
      child: const Icon(Icons.delete_rounded, color: Colors.white, size: 22),
    );
  }

  /// Queue-specific quick actions for a single row — Play Next / Move to
  /// Top / Remove — the actions the generic showAurumFullPlayerOptionsSheet
  /// doesn't cover (that sheet has no concept of "this song's position in
  /// the queue" at all). Kept intentionally small/focused rather than
  /// merged into the generic sheet, matching how the Card layout's
  /// _QueueTile separates its own long-press menu from the shared
  /// song-options sheet.
  void _showQueueItemActions(
    BuildContext context, {
    required Song song,
    required int index,
    required bool isCurrent,
    required Color accentColor,
  }) {
    AurumHaptics.light();
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(150),
      builder: (sheetContext) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Container(
          color: AurumTheme.bgElevatedOf(context),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.skip_next_rounded, color: accentColor),
                  title: Text(song.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  subtitle: Text(song.artist,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withOpacity(0.6))),
                  dense: true,
                ),
                const Divider(color: Colors.white24, height: 1),
                ListTile(
                  leading: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                  title: const Text('Play Next', style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    if (isCurrent) return;
                    AurumHaptics.selection();
                    final p = context.read<PlayerProvider>();
                    await p.removeFromQueue(index);
                    await p.playNext(song);
                  },
                ),
                if (!isCurrent)
                  ListTile(
                    leading: const Icon(Icons.vertical_align_top_rounded, color: Colors.white),
                    title: const Text('Move to Top', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      AurumHaptics.selection();
                      final p = context.read<PlayerProvider>();
                      final target = p.currentIndex + 1;
                      p.moveQueueItem(index, index < target ? target - 1 : target);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
                  title: const Text('Song Info', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showSongInfoDialog(context, song);
                  },
                ),
                if (!isCurrent)
                  ListTile(
                    leading: const Icon(Icons.remove_circle_outline_rounded, color: Colors.redAccent),
                    title: const Text('Remove from Queue', style: TextStyle(color: Colors.redAccent)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      AurumHaptics.medium();
                      context.read<PlayerProvider>().removeFromQueue(index);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueModeButton extends StatelessWidget {
  const _QueueModeButton({
    required this.icon,
    required this.active,
    required this.panel,
    required this.onTap,
  });
  final IconData icon;
  final bool active;
  final _PanelPalette panel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: active ? panel.glow.withOpacity(0.38) : Colors.white.withOpacity(0.10),
          borderRadius: BorderRadius.circular(26),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}
