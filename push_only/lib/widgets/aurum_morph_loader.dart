// aurum_morph_loader.dart
// Aurum Music — M3 Expressive Shape-Morphing Loading Indicator
// Wraps the official Android M3 Expressive LoadingIndicator Dart port.
// Uses Aurum's gold color by default.
//
// Usage:
//   const AurumMorphLoader()           // 48px gold
//   const AurumMorphLoader(size: 32)
//   AurumMorphLoader(color: Colors.white)

import 'package:flutter/material.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';

const Color kAurumGold = Color(0xFFB89640);

class AurumMorphLoader extends StatelessWidget {
  const AurumMorphLoader({
    super.key,
    this.size = 48.0,
    this.color = kAurumGold,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: ExpressiveLoadingIndicator(
        color: color,
        constraints: BoxConstraints(
          minWidth: size,
          minHeight: size,
          maxWidth: size,
          maxHeight: size,
        ),
      ),
    );
  }
}
