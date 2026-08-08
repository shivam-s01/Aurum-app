import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/aurum_theme.dart';

/// Unified artwork widget — handles:
///   • Network URLs  (https://...)
///   • content:// URIs from MediaStore (album art via MethodChannel)
///   • Absolute file paths (/storage/emulated/0/...)
///   • file:// paths
///   • Empty / null  → gold music-note placeholder
///
/// PREMIUM POLISH: every path now fades in (220–280ms, easeOut) instead of
/// popping in abruptly once bytes are ready. CachedNetworkImage's built-in
/// fadeInDuration handles the network case; local file/content URI cases
/// are wrapped in AnimatedSwitcher so the same fade applies everywhere.
class AurumArtwork extends StatelessWidget {
  final String url;
  final double size;
  final double borderRadius;

  // BUGFIX (perf): default true preserves existing behavior everywhere
  // (song tiles, mini player, etc. still get the polish fade). Set false
  // for instances that are already hidden behind their own opacity/blur
  // layer — e.g. the full player's blurred background — where the fade is
  // invisible to the user but still costs a re-composite of whatever
  // filter sits on top of it every single frame for its duration.
  final bool fadeIn;

  // FIX (white flash on cold-start full-player open): the shimmer loading
  // placeholder (_ShimmerPulse) is a subtle, low-opacity pulse tuned to
  // look right on a normal thumbnail-sized tile. The full player's
  // blurred background (_BgLayer in full_player_screen.dart) renders
  // AurumArtwork at size:double.infinity and then applies
  // Transform.scale(1.55) + a heavy Gaussian blur on top — at that scale
  // the same subtle pulse stretches into a flat, bright white wash across
  // the ENTIRE screen for however long the real artwork takes to arrive
  // (worse on a cold start with nothing cached yet, and worse still for
  // local/downloaded songs going through the content:// MediaStore path,
  // which has no cache warm-up at all). The themed base/vignette layers
  // already painted underneath this in full_player_screen.dart are the
  // correct "nothing loaded yet" background for that specific context, so
  // this flag lets ONLY that one call site opt out of the shimmer pulse
  // while every other artwork usage (tiles, mini player, the full
  // player's own non-blurred disc artwork, etc.) keeps it exactly as
  // before. Deliberately a separate flag from `size`/`fadeIn` — those are
  // both also used by the full player's non-background disc artwork
  // (size:double.infinity to fill its parent, fadeIn:true for a smooth
  // song-change crossfade), so neither can safely stand in as "is this
  // the blurred background" on its own.
  final bool isBlurredBackground;

  const AurumArtwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.fadeIn = true,
    this.isBlurredBackground = false,
  });

  int? get _cacheSize {
    // When size is non-finite (e.g. blurred full-screen background layers
    // that pass size: double.infinity), decoding at full original
    // resolution is pure waste — a heavy blur (40σ+) destroys all detail
    // anyway. Cap to a small fixed decode width; visually identical after
    // blur, but far cheaper to decode and blur.
    if (!size.isFinite) return 220;
    if (size <= 0) return null;
    return (size * 2).toInt();
  }

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder(context);

    // ── content:// URI (MediaStore album art) ──────────────────────────────
    if (url.startsWith('content://')) {
      return _ContentUriImage(
        uri: url,
        size: size,
        borderRadius: borderRadius,
        placeholder: _placeholder(context),
        fadeIn: fadeIn,
        isBlurredBackground: isBlurredBackground,
      );
    }

    // ── Local file path ────────────────────────────────────────────────────
    if (url.startsWith('/') || url.startsWith('file://')) {
      final path =
          url.startsWith('file://') ? url.replaceFirst('file://', '') : url;
      final fileImage = Image.file(
        File(path),
        key: ValueKey(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: _cacheSize,
        errorBuilder: (_, __, ___) => _placeholder(context),
      );
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: fadeIn ? _FadeInImage(child: fileImage) : fileImage,
      );
    }

    // ── Network URL ────────────────────────────────────────────────────────
    // BUGFIX: YouTube's maxresdefault.jpg (used for the HD full-player
    // artwork upgrade) doesn't exist for every video — it 404s for
    // anything without a 720p+ source upload, which is common. Since
    // youtube_explode_dart's maxResUrl is a fixed string built from the
    // video ID (never actually verified against YouTube), there was no
    // way to detect this ahead of time — it always looked "available".
    // _RetryableNetworkImage below catches the load failure and retries
    // once with hqdefault.jpg (guaranteed to exist for every YouTube
    // video) before falling through to the placeholder, so a missing
    // maxres thumbnail no longer means a blank gray box.
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: _RetryableNetworkImage(
        url: url,
        size: size,
        cacheSize: _cacheSize,
        fadeIn: fadeIn,
        placeholder: _shimmer(context),
        errorWidget: _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AurumTheme.bgSurfaceOf(context),
              AurumTheme.bgElevatedOf(context),
            ],
          ),
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: AurumTheme.textMutedOf(context),
          size: size * 0.38,
        ),
      );

  // FIX (white flash on cold-start full-player open): the full-player's
  // blurred background (_BlurredArtworkCore) passes isBlurredBackground:
  // true because it's rendering this as a Transform.scale(1.55) +
  // ImageFilter.blur(sigma 20-22) full-screen layer, not a normal
  // thumbnail. _ShimmerPulse's white pulse (0.03-0.10 opacity) is subtle
  // and fine at tile scale, but stretched 1.55x and heavily blurred
  // across the whole screen it reads as a flat, bright white wash for
  // however long the real artwork takes to decode on a cold start (no
  // cache yet) — exactly the "flash before full player opens" report.
  // The themed vignette/base layers already painted underneath this in
  // full_player_screen.dart (_buildLight/_buildDark) are the correct
  // "nothing loaded yet" background for this context — the shimmer pulse
  // adds nothing but the flash at this scale, so skip it here and fall
  // back to a plain themed surface instead. Gated on the explicit flag,
  // NOT size.isFinite — the full player's own non-blurred disc artwork
  // also renders at size:double.infinity (to fill its parent box) and
  // still wants its normal shimmer while loading.
  Widget _shimmer(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: isBlurredBackground ? null : const _ShimmerPulse(),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// _RetryableNetworkImage — wraps CachedNetworkImage with one specific
// fallback: a failed maxresdefault.jpg load (YouTube's 1280x720 tier,
// which 404s for any video without a 720p+ source upload) retries once
// against hqdefault.jpg (480x360, guaranteed to exist for every YouTube
// video) before giving up to the placeholder. Non-YouTube URLs, or a
// URL that isn't a maxresdefault variant, just go straight to the
// normal CachedNetworkImage error path — this only adds a retry for
// the one specific case that's actually recoverable.
// ─────────────────────────────────────────────────────────────────────────────
class _RetryableNetworkImage extends StatefulWidget {
  final String url;
  final double size;
  final int? cacheSize;
  final bool fadeIn;
  final Widget placeholder;
  final Widget errorWidget;

  const _RetryableNetworkImage({
    required this.url,
    required this.size,
    required this.cacheSize,
    required this.fadeIn,
    required this.placeholder,
    required this.errorWidget,
  });

  @override
  State<_RetryableNetworkImage> createState() =>
      _RetryableNetworkImageState();
}

class _RetryableNetworkImageState extends State<_RetryableNetworkImage> {
  static final RegExp _maxResPattern =
      RegExp(r'/maxresdefault\.jpg$');

  late String _activeUrl = widget.url;
  bool _triedFallback = false;

  @override
  void didUpdateWidget(_RetryableNetworkImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _activeUrl = widget.url;
      _triedFallback = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      // Keyed by the ORIGINAL url (not _activeUrl) so switching between
      // songs is still recognized as a new image by any parent
      // AnimatedSwitcher/keyed list — only this widget's internal state
      // tracks which tier is currently being attempted.
      key: ValueKey(widget.url),
      imageUrl: _activeUrl,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      memCacheWidth: widget.cacheSize,
      fadeInDuration:
          widget.fadeIn ? const Duration(milliseconds: 280) : Duration.zero,
      fadeInCurve: Curves.easeOut,
      fadeOutDuration:
          widget.fadeIn ? const Duration(milliseconds: 120) : Duration.zero,
      fadeOutCurve: Curves.easeIn,
      placeholder: (_, __) => widget.placeholder,
      errorWidget: (_, __, ___) {
        if (!_triedFallback && _maxResPattern.hasMatch(_activeUrl)) {
          // Defer the retry to after this build — errorWidget runs
          // during build, and calling setState synchronously here would
          // trigger "setState during build" for the frame that first
          // discovers the 404.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _triedFallback = true;
                _activeUrl =
                    _activeUrl.replaceFirst(_maxResPattern, '/hqdefault.jpg');
              });
            }
          });
          // Show the placeholder for this one frame while the retry kicks in.
          return widget.placeholder;
        }
        return widget.errorWidget;
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _FadeInImage — wraps a resolved Image widget so it fades in (220ms,
// easeOut) on first paint instead of popping in. Used for local file /
// content URI paths where CachedNetworkImage's built-in fadeIn isn't
// available. Keyed by the image's own key so AnimatedSwitcher only
// re-triggers the fade when the underlying image actually changes.
// ─────────────────────────────────────────────────────────────────────────────
class _FadeInImage extends StatelessWidget {
  final Widget child;

  const _FadeInImage({required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.center,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// content:// loader  —  reads bytes via MethodChannel, caches in-process
// ─────────────────────────────────────────────────────────────────────────────
class _ContentUriImage extends StatefulWidget {
  final String uri;
  final double size;
  final double borderRadius;
  final Widget placeholder;
  final bool fadeIn;
  final bool isBlurredBackground;

  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.placeholder,
    this.fadeIn = true,
    this.isBlurredBackground = false,
  });

  @override
  State<_ContentUriImage> createState() => _ContentUriImageState();
}

class _ContentUriImageState extends State<_ContentUriImage> {
  // Shared across all instances — avoids duplicate platform calls.
  // MEMORY-LEAK FIX ("UI lag/memory grows on large local libraries" —
  // production gap): this was an unbounded Map. Every unique content://
  // URI ever displayed (every distinct local/downloaded song's album art,
  // as raw decoded bytes — not a thumbnail, the full MediaStore art blob)
  // stayed in memory for the rest of the app session, no eviction, ever.
  // A user with a large local library scrolling their library/queue
  // repeatedly over a long session would accumulate hundreds of these
  // permanently, which is exactly the kind of slow memory growth that
  // shows up as the app "getting laggier the longer it's open" without
  // an obvious single cause. ArtworkPaletteCache (artwork_palette_cache.
  // dart) already solved this identical problem for palette data with a
  // capped, drop-oldest policy — reusing that same bound here (60 entries,
  // consistent with the rest of the codebase) fixes it the same way.
  static const int _maxEntries = 60;
  static final Map<String, Uint8List?> _cache = {};

  static void _cachePut(String uri, Uint8List? bytes) {
    if (_cache.length >= _maxEntries && !_cache.containsKey(uri)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[uri] = bytes;
  }

  static const _channel = MethodChannel('com.aurum.music/media_store');

  Uint8List? _bytes;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ContentUriImage old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) {
      setState(() {
        _loaded = false;
        _bytes = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    // Serve from cache immediately
    if (_cache.containsKey(widget.uri)) {
      if (mounted) {
        setState(() {
          _bytes = _cache[widget.uri];
          _loaded = true;
        });
      }
      return;
    }

    try {
      final result = await _channel.invokeMethod<Uint8List>(
        'getAlbumArt',
        {'uri': widget.uri},
      );
      _cachePut(widget.uri, result);
      if (mounted) setState(() { _bytes = result; _loaded = true; });
    } catch (_) {
      _cachePut(widget.uri, null);
      if (mounted) setState(() { _bytes = null; _loaded = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      // FIX (white flash on cold-start full-player open for local/
      // downloaded songs): this is the content:// (MediaStore) artwork
      // path — exactly what offline/local songs use. Same root cause as
      // the network-image _shimmer() in AurumArtwork above: the full
      // player's blurred background renders this with
      // isBlurredBackground:true, then Transform.scale(1.55) +
      // blur(sigma 20-22) stretches whatever paints here across the
      // entire screen. _ShimmerPulse's white pulse is subtle on a real
      // tile but reads as a full-screen white wash at that scale for
      // however long the MethodChannel album-art fetch takes — worse
      // than the network case since this was never gated at all. Gated
      // on the explicit flag, NOT size — the full player's own
      // non-blurred disc artwork also renders content:// art at
      // size:double.infinity (to fill its parent box) and still wants
      // its normal shimmer while loading.
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: widget.isBlurredBackground ? null : const _ShimmerPulse(),
      );
    }

    if (_bytes == null || _bytes!.isEmpty) return widget.placeholder;

    final memImage = Image.memory(
      _bytes!,
      key: ValueKey(widget.uri),
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      cacheWidth: (widget.size.isFinite && widget.size > 0)
          ? (widget.size * 2).toInt()
          : null,
      errorBuilder: (_, __, ___) => widget.placeholder,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.fadeIn ? _FadeInImage(child: memImage) : memImage,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shimmer pulse — ONE shared AnimationController for all instances.
// Previously each _ShimmerPulse had its own controller → 20-30 controllers
// running simultaneously during list scroll. Now all instances share one
// ValueNotifier driven by a single app-level ticker.
// ─────────────────────────────────────────────────────────────────────────────
class _ShimmerPulse extends StatelessWidget {
  const _ShimmerPulse();

  // Single shared notifier — value oscillates 0.03↔0.10 at 900ms
  static final ValueNotifier<double> _opacity = ValueNotifier(0.03);
  static AnimationController? _ctrl;
  static int _refCount = 0;

  static void _attach(TickerProvider vsync) {
    _refCount++;
    if (_ctrl != null) return;
    _ctrl = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _ctrl!.addListener(() {
      final t = _ctrl!.value;
      // FIX (same glitch as full_player_screen.dart's Ken Burns pan):
      // _ctrl already reverses direction on its own via
      // repeat(reverse: true). Layering Curves.easeInOut.transform() on
      // that raw value re-eases something already changing direction —
      // at each turnaround the controller's own velocity flip and the
      // curve's steep slope combine into a visible snap in the shimmer
      // pulse, most noticeable on the return stroke. A raised-cosine is
      // smooth at both ends of a reversing triangle wave.
      final curved = (1 - math.cos(t * math.pi)) / 2;
      _opacity.value = 0.03 + curved * 0.07;
    });
  }

  static void _detach() {
    _refCount--;
    if (_refCount <= 0) {
      _ctrl?.dispose();
      _ctrl = null;
      _refCount = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ShimmerPulseInstance();
  }
}

class _ShimmerPulseInstance extends StatefulWidget {
  @override
  State<_ShimmerPulseInstance> createState() => _ShimmerPulseInstanceState();
}

class _ShimmerPulseInstanceState extends State<_ShimmerPulseInstance>
    with SingleTickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    _ShimmerPulse._attach(this);
  }

  @override
  void dispose() {
    _ShimmerPulse._detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _ShimmerPulse._opacity,
      builder: (_, opacity, __) =>
          Container(color: Colors.white.withOpacity(opacity)),
    );
  }
}
