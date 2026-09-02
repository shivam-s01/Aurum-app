import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/aurum_image_cache.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_motion.dart';

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

  // NOTE: the loading state is now always a flat themed container with
  // no pulsing overlay of any kind (see _shimmer() and the
  // _ContentUriImage !_loaded branch below) — there is no shimmer left
  // to suppress. This flag is kept only so existing call sites passing
  // suppressWhiteShimmer: true/false elsewhere in the app don't need to
  // be touched; it has no effect on what's painted.
  final bool suppressWhiteShimmer;

  const AurumArtwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.fadeIn = true,
    this.isBlurredBackground = false,
    this.suppressWhiteShimmer = false,
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
    // FIX: same isBlurredBackground gap as the other three artwork
    // branches — an empty URL should not inject the gradient placeholder
    // into a full-screen blurred background. _BlurredArtworkCore in
    // full_player_screen.dart already checks song.artworkUrl.isEmpty
    // before this widget is even constructed for the blurred-background
    // call site, so this is currently unreachable with
    // isBlurredBackground:true in practice — kept as defense-in-depth for
    // any future call site.
    if (url.isEmpty) {
      return isBlurredBackground ? const SizedBox.expand() : _placeholder(context);
    }

    // ── content:// URI (MediaStore album art) ──────────────────────────────
    if (url.startsWith('content://')) {
      return _ContentUriImage(
        uri: url,
        size: size,
        borderRadius: borderRadius,
        placeholder: _placeholder(context),
        fadeIn: fadeIn,
        isBlurredBackground: isBlurredBackground,
        suppressWhiteShimmer: suppressWhiteShimmer,
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
        // FIX: same isBlurredBackground gap as the content:// and network
        // paths above — a failed local file read (deleted/moved file)
        // should not inject the gradient placeholder into a full-screen
        // blurred background either.
        errorBuilder: (_, __, ___) =>
            isBlurredBackground ? const SizedBox.expand() : _placeholder(context),
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
        placeholder: _shimmer(context, suppressWhiteShimmer),
        // FIX (same class as the content:// _bytes==null fix): a
        // genuinely failed network image (offline device, real 404, bad
        // URL) used to always fall through to _placeholder(context) — the
        // bgSurfaceOf→bgElevatedOf gradient + music-note icon — regardless
        // of isBlurredBackground. Stretched into the full player's blurred
        // background the same way the loading shimmer was, that gradient
        // is the same light wash for a failed load as for a slow one.
        // _BgLayer's theme-correct base is already the right "no artwork"
        // background here — stay transparent and let it show through.
        errorWidget:
            isBlurredBackground ? const SizedBox.expand() : _placeholder(context),
      ),
    );
  }

  // FIX ("grey/white layer on cold start, tap karte time, kuch bhi karke
  // na aaye"): _shimmer used AurumTheme.bgSurfaceOf(context), which is a
  // light warm-grey in LIGHT theme (lightBgSurface) — every single
  // AurumArtwork instance (Hero Now Playing card, mini player thumbnail,
  // song tiles) painted that light-grey block for as long as the network
  // fetch took, which is exactly the "white/grey flash" reported — worse
  // the slower the connection, since there was nothing bounding how long
  // it stayed visible. Same root class of bug already fixed once in
  // mini_player.dart's tint fallback (theme-dependent color leaking into
  // a loading state) — same fix here: a single FIXED dark neutral,
  // completely independent of Theme.of(context).brightness, so this can
  // never again render as a light/white block no matter what theme is
  // active or how long the fetch takes.
  static const Color _placeholderBase = Color(0xFF1A1714);

  Widget _placeholder(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_placeholderBase, Color(0xFF0F0D0B)],
          ),
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white.withValues(alpha: 0.35),
          size: size * 0.38,
        ),
      );

  // FIX (permanent removal of white/light shimmer flash): the loading
  // state now paints ONLY this flat theme-colored container — no
  // opacity-pulsing overlay on top of it at all. A pulsing layer, no
  // matter what color it's tinted, briefly lightens whatever it sits
  // over every animation cycle; the only way to guarantee it can never
  // read as a white/light flash in any theme or lighting state is to
  // not paint one. isBlurredBackground still stays transparent so the
  // full player's own themed base/vignette shows through underneath.
  Widget _shimmer(BuildContext context, [bool suppress = false]) {
    if (isBlurredBackground) return const SizedBox.expand();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: _placeholderBase,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
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
      // Echo Nightly match: routes disk caching through a size-bounded
      // CacheManager (AurumImageCache, 100MB-equivalent cap) instead of
      // the plugin's default unbounded-by-size cache — see that class's
      // own doc comment for why this matters on long-term disk usage.
      cacheManager: AurumImageCache(),
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
      duration: AurumMotion.durationOrZero(AurumMotion.medium1),
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
  final bool suppressWhiteShimmer;

  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.placeholder,
    this.fadeIn = true,
    this.isBlurredBackground = false,
    this.suppressWhiteShimmer = false,
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
      // FIX (white/gray wash on full-player open, root-caused — P0):
      // this used to return a Container with color: AurumTheme.bgSurfaceOf
      // (a light warm-grey, 0xFFE8E4D8 in light mode) regardless of
      // isBlurredBackground — that flag only ever gated the _ShimmerPulse
      // CHILD below, never this container's own background color. The
      // full player's blurred background (_BlurredArtworkCore in
      // full_player_screen.dart) wraps this widget in Transform.scale(1.55)
      // + ImageFilter.blur(sigma 20-22): a flat color survives that
      // untouched, so for however long the getAlbumArt MethodChannel call
      // takes to resolve (no disk cache on this path — worse on a cold
      // launch, worse than network art which at least has
      // CachedNetworkImageProvider's cache to shortcut), the ENTIRE full
      // player screen was a plain light wash.
      //
      // _BgLayer (full_player_screen.dart _buildLight/_buildDark) already
      // paints its own theme-correct base + vignette UNDERNEATH this
      // layer specifically to be the "nothing loaded yet" background —
      // this widget just needs to get out of the way and let it show
      // through, not paint a second, wrong-colored layer on top of it.
      // Returning transparent here does exactly that. The non-blurred
      // callers (tile art, mini player, full player's own disc artwork)
      // are unaffected — they still get the themed Container + shimmer
      // exactly as before, since this only changes the isBlurredBackground
      // branch.
      if (widget.isBlurredBackground) {
        return const SizedBox.expand();
      }
      // FIX (permanent removal of white/light shimmer flash): no
      // pulsing overlay child at all now — just the flat themed
      // container. A pulsing layer, whatever color it's tinted, briefly
      // lightens on every cycle; not painting one is the only way this
      // can never read as a white/light flash.
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: AurumArtwork._placeholderBase,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      );
    }

    // FIX (same class as the !_loaded branch above): _bytes == null here
    // means the MethodChannel call completed but genuinely found no album
    // art (not "still loading" — that's the !_loaded branch above). This
    // used to fall through to widget.placeholder unconditionally —
    // _placeholder(context) in aurum_artwork.dart, a bgSurfaceOf→
    // bgElevatedOf gradient + music-note icon. Same problem as the
    // loading case: stretched into the full player's blurred background
    // at Transform.scale(1.55) + blur(20-22), that gradient reads as a
    // light wash for a song that will simply never have artwork, not just
    // a transient one. _BgLayer's own theme-correct base/vignette is
    // already the correct "no artwork" background for this context —
    // stay transparent and let it show through, exactly like the loading
    // case above.
    if (_bytes == null || _bytes!.isEmpty) {
      return widget.isBlurredBackground
          ? const SizedBox.expand()
          : widget.placeholder;
    }

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
