import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';

/// AurumStageBackdrop — Echo Nightly-style home background.
///
/// Echo's actual "makkhan" look is NOT a color glow — it's the current
/// track's own album art, blurred and grain-textured, sitting behind the
/// top of the screen (Coil's one-shot BlurTransformation, drawn once,
/// composited with a noise bitmap so it reads as tactile material instead
/// of a flat gradient PNG).
///
/// Two things make this both "ekdum makkhan" AND lightweight/fast:
///   1. The expensive blur shader runs ONCE per song, not every frame.
///      It's baked to a static bitmap via RenderRepaintBoundary.toImage()
///      (same technique already proven in full_player_screen.dart's
///      _BlurredArtworkCore) and from then on it's just a RawImage blit —
///      as cheap as drawing any other photo, however long the song plays.
///   2. The grain texture is a tiny (64x64) procedurally generated noise
///      bitmap, built once per app session and tiled — no bundled asset,
///      no extra APK weight, no per-frame cost.
class AurumStageBackdrop extends StatelessWidget {
  final double height;
  const AurumStageBackdrop({super.key, this.height = 260});

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final isLight = Theme.of(context).brightness == Brightness.light;
    // FIX ("wallpaper theme mein awkward patch dikh raha hai"): this used
    // to blend into the hardcoded AurumTheme.darkBg/lightBg constants,
    // which is correct for the fixed Dark/Light themes but WRONG for
    // Material You "wallpaper" mode (AurumTheme.dynamicTheme()) — that
    // mode's actual page background is a device-specific dynamic.surface
    // color that has nothing to do with darkBg/lightBg. Blending to the
    // wrong color is exactly what created the visible seam/patch right
    // where this backdrop's scrim meets the page underneath it. bgOf()
    // reads the THEME'S OWN resolved scaffoldBackgroundColor (same value
    // the Scaffold itself is already painted with, whichever theme is
    // active), so this now always blends into whatever's actually behind
    // it — Dark, Light, or wallpaper-derived — instead of a fixed guess.
    final pageBg = AurumTheme.bgOf(context);

    return RepaintBoundary(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Base fallback (idle / no artwork) ──
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [AurumTheme.gold.withOpacity(isLight ? 0.14 : 0.20), pageBg],
                ),
              ),
            ),
            // ── Baked blurred artwork (the actual Echo-style photo wash) ──
            if (song != null && song.artworkUrl.isNotEmpty)
              _BakedBlurStage(
                key: ValueKey('${song.id}_${song.artworkUrl}'),
                song: song,
                isLight: isLight,
              ),
            // ── Grain texture — the ingredient that stops this from
            // reading as a flat gradient. Multiplied on top, cheap tile. ──
            const _GrainOverlay(),
            // ── Readability scrim: fades this stage into the flat page
            // background underneath the scroll content. ──
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    pageBg.withOpacity(0.55),
                    pageBg,
                  ],
                  stops: const [0.0, 0.72, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Bakes the blur once per song (ValueKey at the call site guarantees this
// only rebuilds on a real song change) instead of running a live shader
// every composited frame. Same technique as full_player_screen.dart's
// _BlurredArtworkCore, tuned lighter for a background-strip use case:
// smaller decode target, lower sigma, no Ken Burns pan (this sits behind
// scrolling content, not a focused full-screen stage).
// ─────────────────────────────────────────────────────────────────────────
class _BakedBlurStage extends StatefulWidget {
  final Song song;
  final bool isLight;
  const _BakedBlurStage({super.key, required this.song, required this.isLight});

  @override
  State<_BakedBlurStage> createState() => _BakedBlurStageState();
}

class _BakedBlurStageState extends State<_BakedBlurStage> {
  final GlobalKey _repaintKey = GlobalKey();
  ui.Image? _snapshot;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void dispose() {
    _snapshot?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_capturing || !mounted) return;
    _capturing = true;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _capturing = false;
      return;
    }
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) {
        _capturing = false;
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
        }
        return;
      }
      // pixelRatio 1.0 — same reasoning as the full player: the source
      // decodes at a small capped width already, and a heavy blur
      // destroys detail a higher-res capture would've preserved anyway.
      final image = await boundary.toImage(pixelRatio: 1.0);
      if (!mounted) {
        image.dispose();
        _capturing = false;
        return;
      }
      final old = _snapshot;
      setState(() => _snapshot = image);
      old?.dispose();
    } catch (_) {
      // Live blur just stays on screen if a capture attempt fails —
      // never worse than not baking, never a crash.
    } finally {
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, if (currentChild != null) currentChild],
        ),
        child: snapshot != null
            // Post-bake: plain bitmap blit, zero shader cost from here on.
            ? SizedBox.expand(
                key: const ValueKey('baked'),
                child: RawImage(image: snapshot, fit: BoxFit.cover),
              )
            // Pre-bake: the one time the real blur shader runs for this song.
            : RepaintBoundary(
                key: _repaintKey,
                child: _LiveBlur(song: widget.song, isLight: widget.isLight),
              ),
      ),
    );
  }
}

class _LiveBlur extends StatelessWidget {
  final Song song;
  final bool isLight;
  const _LiveBlur({required this.song, required this.isLight});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 1.15, // small overscan so the blur's soft edge never shows a hard boundary
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: isLight ? 26 : 30,
          sigmaY: isLight ? 26 : 30,
          tileMode: TileMode.clamp,
        ),
        // Uses the existing cached artwork provider — no extra network
        // fetch, this is the same image the mini player/hero already hold.
        child: _ArtworkFill(url: song.artworkUrl),
      ),
    );
  }
}

class _ArtworkFill extends StatelessWidget {
  final String url;
  const _ArtworkFill({required this.url});

  @override
  Widget build(BuildContext context) {
    // Reuses AurumArtwork's own resolution paths (network/content/file)
    // via the app's existing widget so cache hits are shared with every
    // other place this song's art is already displayed on screen.
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          // Small fixed decode size — matches AurumArtwork's own
          // "why decode more than the blur can preserve" logic.
          width: 200,
          height: 200,
          child: _NoFadeArtwork(url: url),
        ),
      ),
    );
  }
}

// Thin wrapper so this file doesn't need to import aurum_artwork.dart's
// full surface — kept local and minimal since this call site never needs
// fade/placeholder polish (it's hidden behind the blur immediately).
class _NoFadeArtwork extends StatelessWidget {
  final String url;
  const _NoFadeArtwork({required this.url});

  @override
  Widget build(BuildContext context) {
    return Image(
      image: resolveAurumImageProvider(url),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const SizedBox.expand(),
    );
  }
}

/// Shared resolver so this widget and AurumArtwork agree on how a URL maps
/// to an ImageProvider — kept tiny and dependency-free here.
ImageProvider resolveAurumImageProvider(String url) {
  if (url.startsWith('http')) {
    return NetworkImage(url);
  }
  if (url.startsWith('file://')) {
    return FileImage(_fileFromUri(url));
  }
  if (url.startsWith('/')) {
    return FileImage(_fileFromUri(url));
  }
  // content:// URIs have no direct ImageProvider — fall back to a 1x1
  // transparent placeholder; the flat base gradient beneath still shows.
  return MemoryImage(_kTransparentPixel);
}

File _fileFromUri(String url) =>
    File(url.startsWith('file://') ? url.replaceFirst('file://', '') : url);

final Uint8List _kTransparentPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

// ─────────────────────────────────────────────────────────────────────────
// _GrainOverlay — Echo's grain_noise ingredient, built procedurally so
// there's no bundled asset (zero extra APK weight). A tiny 64x64 RGBA
// noise bitmap is generated ONCE per app session (static cache) and tiled
// across the stage at very low opacity — this is what stops the backdrop
// reading as a flat gradient PNG and makes it feel like tactile material,
// exactly like Echo's DST_IN noise composite in GradientDrawable.kt.
// ─────────────────────────────────────────────────────────────────────────
class _GrainOverlay extends StatelessWidget {
  const _GrainOverlay();

  static ui.Image? _cached;
  static Future<ui.Image>? _pending;

  static Future<ui.Image> _generate() {
    if (_cached != null) return Future.value(_cached);
    return _pending ??= _build().then((img) {
      _cached = img;
      return img;
    });
  }

  static Future<ui.Image> _build() async {
    const size = 64;
    final rnd = math.Random(7); // fixed seed — identical texture every run
    final bytes = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final v = rnd.nextInt(256);
      bytes[i * 4] = v;
      bytes[i * 4 + 1] = v;
      bytes[i * 4 + 2] = v;
      bytes[i * 4 + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image>(
      future: _generate(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();
        return Opacity(
          opacity: 0.035, // subtle — texture, not visible static
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _GrainPainter(snap.data!),
            ),
          ),
        );
      },
    );
  }
}

class _GrainPainter extends CustomPainter {
  final ui.Image tile;
  const _GrainPainter(this.tile);

  @override
  void paint(Canvas canvas, Size size) {
    final shader = ImageShader(
      tile,
      TileMode.repeated,
      TileMode.repeated,
      Matrix4.identity().storage,
    );
    final paint = Paint()
      ..shader = shader
      ..blendMode = BlendMode.overlay;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) => old.tile != tile;
}
