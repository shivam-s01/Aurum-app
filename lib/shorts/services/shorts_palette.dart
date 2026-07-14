import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';

/// 4-role color palette extracted from artwork: glow / base / anchor /
/// highlight. Mirrors the extraction logic already proven in
/// full_player_screen.dart (same fallback chain), kept as its own
/// small utility here so the Shorts module stays self-contained.
class ShortsPalette {
  final Color glow;
  final Color base;
  final Color anchor;
  final Color highlight;

  const ShortsPalette({
    required this.glow,
    required this.base,
    required this.anchor,
    required this.highlight,
  });

  static const fallback = ShortsPalette(
    glow: Color(0xFF1A1630),
    base: Color(0xFF120F24),
    anchor: Color(0xFF080810),
    highlight: Color(0xFF9B7EDE),
  );

  /// Extracts a palette from a network artwork URL. Small target size
  /// (80x80) keeps decode cost low — Shorts swipes fast, so this must
  /// stay cheap even though it runs on every card, not just on
  /// explicit track change like the full player.
  static Future<ShortsPalette> extract(String artworkUrl) async {
    if (artworkUrl.isEmpty) return fallback;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(artworkUrl),
        size: const Size(80, 80),
        maximumColorCount: 12,
      );

      final glow = pg.vibrantColor?.color ??
          pg.lightVibrantColor?.color ??
          pg.dominantColor?.color ??
          fallback.glow;
      final base = pg.dominantColor?.color ??
          pg.mutedColor?.color ??
          fallback.base;
      final anchor = pg.darkMutedColor?.color ??
          pg.mutedColor?.color ??
          fallback.anchor;
      final highlight = pg.lightVibrantColor?.color ??
          pg.vibrantColor?.color ??
          pg.lightMutedColor?.color ??
          glow;

      return ShortsPalette(
        glow: glow,
        base: base,
        anchor: anchor,
        highlight: highlight,
      );
    } catch (_) {
      return fallback;
    }
  }
}
