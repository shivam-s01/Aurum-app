// =============================================================================
// FILE: lib/utils/artwork_palette_cache.dart
// PROJECT: Aurum Music
// DESCRIPTION: Small in-memory cache + fast extractor for artwork-derived
//   palette colors, shared by the Full Player screen (and available to
//   Album/Mix screens too).
//
//   Why this exists: PaletteGenerator.fromImageProvider decodes the image
//   and runs quantization every single call — for a song the user has
//   already played (skip back, replay, shuffle loop) or one whose artwork
//   was just pre-warmed from the queue, that's wasted work and wasted time.
//   Caching by artwork URL makes every repeat-look instant, and shrinking
//   the decode target from 120x120 to 40x40 (plenty for 4 flat palette
//   swatches — this isn't rendering the image, just averaging colors)
//   cuts the cold-path decode time down substantially too.
//
//   Capped at 60 entries (an LRU-ish drop-oldest policy) so a long
//   listening session doesn't grow this unboundedly — palette colors are
//   four small Color values each, so even 60 entries is trivial memory,
//   but there's no reason not to bound it.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';

class ArtworkPalette {
  final Color vibrant;
  final Color dominant;
  final Color darkMuted;
  final Color lightVibrant;

  const ArtworkPalette({
    required this.vibrant,
    required this.dominant,
    required this.darkMuted,
    required this.lightVibrant,
  });
}

class ArtworkPaletteCache {
  ArtworkPaletteCache._();

  static const int _maxEntries = 60;
  static final Map<String, ArtworkPalette> _cache = {};

  // Tracks in-flight extractions so a rapid double-trigger (e.g. the
  // screen building twice on the same frame) doesn't kick off two
  // redundant decodes for the same URL.
  static final Map<String, Future<ArtworkPalette>> _inFlight = {};

  static ArtworkPalette? peek(String url) => _cache[url];

  /// Returns the cached palette instantly if present, otherwise decodes
  /// (deduped against any identical in-flight request) and caches it.
  static Future<ArtworkPalette> get(String url) {
    final cached = _cache[url];
    if (cached != null) return Future.value(cached);

    final existing = _inFlight[url];
    if (existing != null) return existing;

    final future = _extract(url).then((palette) {
      _inFlight.remove(url);
      if (palette == null) return const ArtworkPalette(
        vibrant: Color(0xFF1A1630),
        dominant: Color(0xFF120F24),
        darkMuted: Color(0xFF080810),
        lightVibrant: Color(0xFF1A1630),
      );
      _put(url, palette);
      return palette;
    });
    _inFlight[url] = future;
    return future;
  }

  /// Fire-and-forget warm-up — used to pre-decode the next queued song's
  /// artwork while the current one is still playing, so by the time
  /// playback actually reaches it the palette is already sitting in
  /// cache and the background morph is instant.
  static void warm(String url) {
    if (url.isEmpty || _cache.containsKey(url) || _inFlight.containsKey(url)) {
      return;
    }
    // Deliberately not awaited — this is opportunistic background work.
    get(url);
  }

  static void _put(String url, ArtworkPalette palette) {
    if (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[url] = palette;
  }

  static Future<ArtworkPalette?> _extract(String url) async {
    if (url.isEmpty || !url.startsWith('http')) return null;
    try {
      // 40x40 is plenty for averaged palette swatches (this never renders
      // the decoded bitmap, just quantizes it into a handful of colors),
      // and decodes noticeably faster than the previous 120x120 target.
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(40, 40),
        maximumColorCount: 12,
      );
      return ArtworkPalette(
        vibrant: pg.vibrantColor?.color ??
            pg.lightVibrantColor?.color ??
            pg.dominantColor?.color ??
            const Color(0xFF1A1630),
        dominant: pg.dominantColor?.color ??
            pg.mutedColor?.color ??
            const Color(0xFF120F24),
        darkMuted: pg.darkMutedColor?.color ??
            pg.mutedColor?.color ??
            const Color(0xFF080810),
        lightVibrant: pg.lightVibrantColor?.color ??
            pg.vibrantColor?.color ??
            pg.lightMutedColor?.color ??
            const Color(0xFF1A1630),
      );
    } catch (_) {
      return null;
    }
  }
}
