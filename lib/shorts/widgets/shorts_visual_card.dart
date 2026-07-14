import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/shorts_palette.dart';
import 'shorts_native_surface.dart';

/// Premium visual treatment for a Shorts card. The base layer is
/// always the artwork with a slow Ken Burns zoom/pan — the
/// guaranteed-to-work loading/fallback look. Once the native
/// AurumShortsEngine has the matching YouTube stream ready for the
/// active card, its SurfaceView crossfades in on top, Reels-style.
///
/// v3: video decode/render is fully native now (ExoPlayer -> SurfaceView
/// via AurumShortsEngine) — no VideoPlayerController, no Dart-side video
/// texture. `videoReady` is driven by the controller's videoStatus
/// (mirrored from native), not a local controller's initialized flag.
class ShortsVisualCard extends StatefulWidget {
  final String artworkUrl;
  final bool isActive; // only the current on-screen card animates
  final bool videoReady; // true once native reports status == ready

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
    final showVideo = widget.isActive && widget.videoReady;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Blurred fill layer behind — cheap way to cover edges the
        // zoomed/panned foreground doesn't reach, no letterboxing.
        Positioned.fill(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
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
        // Base artwork with slow Ken Burns zoom/pan — always present
        // underneath so the crossfade to video (and the fallback
        // while loading/on failure) is seamless either way.
        AnimatedBuilder(
          animation: _zoomCtrl,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_zoomCtrl.value);
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
        // Native video surface — crossfades in once the native engine
        // reports the active card's stream as ready. Audio+video both
        // come from the same native ExoPlayer instance now (unified
        // stream, not a muted overlay).
        AnimatedOpacity(
          opacity: showVideo ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOut,
          child: showVideo
              ? const IgnorePointer(child: ShortsNativeSurface())
              : const SizedBox.shrink(),
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
