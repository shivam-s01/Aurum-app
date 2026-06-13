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
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: _cacheSize,
          errorBuilder: (_, __, ___) => _placeholder(context),
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
      child: Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        cacheWidth: (widget.size.isFinite && widget.size > 0)
            ? (widget.size * 2).toInt()
            : null,
        errorBuilder: (_, __, ___) => widget.placeholder,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shimmer pulse
// ─────────────────────────────────────────────────────────────────────────────
class _ShimmerPulse extends StatefulWidget {
  const _ShimmerPulse();

  @override
  State<_ShimmerPulse> createState() => _ShimmerPulseState();
}

class _ShimmerPulseState extends State<_ShimmerPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween(begin: 0.03, end: 0.10).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) =>
          Container(color: Colors.white.withOpacity(_anim.value)),
    );
  }
}
