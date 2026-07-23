import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/shorts_palette.dart';

/// Premium visual treatment for a Shorts card. The artwork with a slow
/// Ken Burns zoom/pan IS the permanent visual — Shorts are audio-only
/// 30-second clips now (native AurumShortsEngine plays a Saavn/YouTube
/// audio stream via ExoPlayer, no video track/surface involved at
/// all). `videoReady`/`isActive` still gate the zoom animation (only
/// the on-screen card animates, for battery), but there is no video
/// layer to crossfade in anymore.
class ShortsVisualCard extends StatefulWidget {
  final String artworkUrl;
  final bool isActive; // only the current on-screen card animates
  final bool videoReady; // true once native reports audio status == ready

  const ShortsVisualCard({
    super.key,
    required this.artworkUrl,
    required this.isActive,
    this.videoReady = false,
  });

  @override
  State<ShortsVisualCard> createState() => _ShortsVisualCardState();
}

class _ShortsVisualCardState extends State<ShortsVisualCard>
    with TickerProviderStateMixin {
  late final AnimationController _zoomCtrl;
  late final AnimationController _orbCtrl;
  ShortsPalette _palette = ShortsPalette.fallback;

  @override
  void initState() {
    super.initState();
    // Slow 14s zoom cycle — subtle, not flashy, per spec.
    _zoomCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    );
    // Independent slower cycle for orb drift so it doesn't feel
    // mechanically synced to the zoom.
    _orbCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    if (widget.isActive) {
      _zoomCtrl.repeat(reverse: true);
      _orbCtrl.repeat();
    }
    _loadPalette();
  }

  @override
  void didUpdateWidget(covariant ShortsVisualCard old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _zoomCtrl.repeat(reverse: true);
      _orbCtrl.repeat();
    } else if (!widget.isActive && old.isActive) {
      // Pause animation for off-screen cards — battery/perf, per spec
      // ("battery efficient", "no unnecessary rebuilds").
      _zoomCtrl.stop();
      _orbCtrl.stop();
    }
    if (widget.artworkUrl != old.artworkUrl) {
      _loadPalette();
    }
  }

  Future<void> _loadPalette() async {
    final p = await ShortsPalette.extract(widget.artworkUrl);
    if (mounted) setState(() => _palette = p);
  }

  @override
  void dispose() {
    _zoomCtrl.dispose();
    _orbCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred fill layer behind — cheap way to cover edges the
        // zoomed/panned foreground doesn't reach, no letterboxing.
        //
        // BUGFIX (battery/perf): this layer previously had no
        // RepaintBoundary. _zoomCtrl and _orbCtrl both run continuous
        // repeat() loops for as long as this card is the active one on
        // screen — 14s and 20s cycles respectively, ticking forever, not
        // just during a transition. Without a boundary isolating this
        // static blur from those animated siblings in the Stack, Flutter
        // was repainting this expensive 30σ blur on every single animation
        // frame (~60x/sec) the whole time a card was visible, instead of
        // once when the artwork loads. On a feed you can sit on for a
        // while, or scroll through quickly, that's a continuous and
        // completely unnecessary GPU/battery cost. The blur's source
        // image never changes while active, so it only needs to be
        // painted once.
        RepaintBoundary(
          child: Positioned.fill(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: CachedNetworkImage(
                imageUrl: widget.artworkUrl,
                fit: BoxFit.cover,
                // Blurred this heavily, full artwork resolution is
                // wasted decode work on every single swipe — a much
                // smaller decode target looks identical once blurred
                // this hard, and cuts real CPU/GPU cost per card.
                memCacheWidth: 200,
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        // Base artwork with slow Ken Burns zoom/pan — always present
        // underneath so the crossfade to video (and the fallback
        // while loading/on failure) is seamless either way.
        AnimatedBuilder(
          animation: _zoomCtrl,
          builder: (context, child) {
            // FIX (same glitch as full_player_screen.dart's Ken Burns
            // pan): _zoomCtrl already reverses direction on its own via
            // repeat(reverse: true). Layering Curves.easeInOut.transform()
            // on top of that raw value re-eases a value that's already
            // changing direction — right at each turnaround the
            // controller's own velocity flip and the curve's steep slope
            // combine into a visible snap, most noticeable on the return
            // ("back") stroke. A raised-cosine is smooth at both ends of
            // a reversing triangle wave, so the zoom/pan now reverses
            // with no visible glitch.
            final t = (1 - math.cos(_zoomCtrl.value * math.pi)) / 2;
            final scale = 1.06 + (t * 0.05); // 1.06 → 1.11, gentle
            final dx = (t - 0.5) * 14; // slight horizontal drift
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: CachedNetworkImage(
            imageUrl: widget.artworkUrl,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 250),
            placeholder: (_, __) => Container(color: const Color(0xFF0A0A0A)),
            errorWidget: (_, __, ___) => Container(
              color: const Color(0xFF0A0A0A),
              child: const Icon(Icons.music_note,
                  color: Colors.white24, size: 48),
            ),
          ),
        ),
        // Ambient glow orbs — palette-colored, drifting slowly.
        AnimatedBuilder(
          animation: _orbCtrl,
          builder: (context, _) {
            final t = _orbCtrl.value * 6.28318; // 0..2π
            return Stack(
              children: [
                Positioned(
                  top: 80 + (40 * (0.5 + 0.5 * _fastSin(t))),
                  left: -60 + (30 * (0.5 + 0.5 * _fastCos(t))),
                  child: _GlowOrb(color: _palette.glow, size: 220),
                ),
                Positioned(
                  bottom: 160 + (50 * (0.5 + 0.5 * _fastCos(t))),
                  right: -70 + (35 * (0.5 + 0.5 * _fastSin(t))),
                  child: _GlowOrb(color: _palette.highlight, size: 260),
                ),
              ],
            );
          },
        ),
        // Palette-tinted darkening scrim — keeps foreground legible
        // while still reading as "colored by the song" rather than a
        // flat black overlay.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _palette.anchor.withOpacity(0.35),
                Colors.black.withOpacity(0.20),
                _palette.anchor.withOpacity(0.55),
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ],
    );
  }

  double _fastSin(double x) =>
      x - (x * x * x) / 6 + (x * x * x * x * x) / 120;
  double _fastCos(double x) => 1 - (x * x) / 2 + (x * x * x * x) / 24;
}

class _GlowOrb extends StatelessWidget {
  final Color color;
  final double size;
  const _GlowOrb({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.35),
              color.withOpacity(0.0),
            ],
          ),
        ),
      ),
    );
  }
}
