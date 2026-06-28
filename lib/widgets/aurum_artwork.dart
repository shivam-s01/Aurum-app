import 'dart:io';
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

  const AurumArtwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
  });

  int? get _cacheSize {
    if (!size.isFinite || size <= 0) return null;
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
      );
    }

    // ── Local file path ────────────────────────────────────────────────────
    if (url.startsWith('/') || url.startsWith('file://')) {
      final path =
          url.startsWith('file://') ? url.replaceFirst('file://', '') : url;
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: _FadeInImage(
          child: Image.file(
            File(path),
            key: ValueKey(path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: _cacheSize,
            errorBuilder: (_, __, ___) => _placeholder(context),
          ),
        ),
      );
    }

    // ── Network URL ────────────────────────────────────────────────────────
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: _cacheSize,
        fadeInDuration: const Duration(milliseconds: 280),
        fadeInCurve: Curves.easeOut,
        fadeOutDuration: const Duration(milliseconds: 120),
        fadeOutCurve: Curves.easeIn,
        placeholder: (_, __) => _shimmer(context),
        errorWidget: (_, __, ___) => _placeholder(context),
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

  Widget _shimmer(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: const _ShimmerPulse(),
      );
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

  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.placeholder,
  });

  @override
  State<_ContentUriImage> createState() => _ContentUriImageState();
}

class _ContentUriImageState extends State<_ContentUriImage> {
  // Shared across all instances — avoids duplicate platform calls
  static final Map<String, Uint8List?> _cache = {};

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
      _cache[widget.uri] = result;
      if (mounted) setState(() { _bytes = result; _loaded = true; });
    } catch (_) {
      _cache[widget.uri] = null;
      if (mounted) setState(() { _bytes = null; _loaded = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: const _ShimmerPulse(),
      );
    }

    if (_bytes == null || _bytes!.isEmpty) return widget.placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: _FadeInImage(
        child: Image.memory(
          _bytes!,
          key: ValueKey(widget.uri),
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          cacheWidth: (widget.size.isFinite && widget.size > 0)
              ? (widget.size * 2).toInt()
              : null,
          errorBuilder: (_, __, ___) => widget.placeholder,
        ),
      ),
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
      final curved = Curves.easeInOut.transform(t);
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
