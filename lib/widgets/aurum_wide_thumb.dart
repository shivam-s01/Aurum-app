// =============================================================================
// FILE: lib/widgets/aurum_wide_thumb.dart
// PROJECT: Astra Music
// DESCRIPTION: 16:9-style cropped thumbnail used by the Mix screen's track
//   rows and the compact track options sheet (YT Music-style wide covers).
//
//   Decodes the square cover at 1.4x the display width so the center crop
//   stays sharp, then center-crops it to the requested box via FittedBox
//   (cover) — no extra network request, same cached image every other
//   AurumArtwork on the page already uses.
// =============================================================================

import 'package:flutter/material.dart';
import 'aurum_artwork.dart';

class AurumWideThumb extends StatelessWidget {
  final String url;
  final double width;
  final double height;
  final double borderRadius;

  const AurumWideThumb({
    super.key,
    required this.url,
    this.width = 80,
    this.height = 45,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    final src = width * 1.4;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: src,
            height: src,
            child: AurumArtwork(url: url, size: src, borderRadius: 0),
          ),
        ),
      ),
    );
  }
}
