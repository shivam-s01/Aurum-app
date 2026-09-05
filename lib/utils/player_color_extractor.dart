// =============================================================================
// FILE: lib/utils/player_color_extractor.dart
// PROJECT: Astra Music
// DESCRIPTION: 1:1 Dart port of ArchiveTune's PlayerColorExtractor.kt
//   (moe.rukamori.archivetune.ui.theme.PlayerColorExtractor).
//
//   Ported line-for-line from the original Kotlin: same swatch set (7:
//   vibrant/lightVibrant/darkVibrant/dominant/muted/darkMuted/lightMuted),
//   same population*vibrancy weighting, same similarity-dedup thresholds,
//   same greyscale-image fallback ramp, same hue-shift mesh-fill for when
//   fewer than 6 genuinely distinct swatches exist. This is what makes
//   ArchiveTune land on a *specific* swatch (sometimes dominant, sometimes
//   muted, not always "the vibrant one") depending on which swatch has the
//   biggest population*vibrancyBonus score for that particular image crop —
//   copying that scoring, not just picking `vibrant` unconditionally, is
//   what makes this app's colors match ArchiveTune's for the same artwork.
//
//   flutter's `palette_generator` package exposes the same swatch shape
//   Android's androidx.palette library does (PaletteColor.color +
//   PaletteColor.population), so every swatch used by the original Kotlin
//   has a direct equivalent here.
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class PlayerColorExtractor {
  PlayerColorExtractor._();

  /// Extracts up to 6 gradient-ready colors from a [PaletteGenerator]
  /// result, in the same rank order and via the same scoring/derivation
  /// rules as ArchiveTune's Kotlin `extractGradientColors`.
  static List<Color> extractGradientColors(
    PaletteGenerator palette, {
    required Color fallbackColor,
  }) {
    // ── Collect every non-null swatch, same 7-swatch set + priority order
    // as the Kotlin `listOfNotNull(...)`, deduped by exact rgb like
    // `.distinctBy { it.rgb }`. ──
    final allSwatches = <PaletteColor>[];
    final seenRgb = <int>{};
    void addSwatch(PaletteColor? s) {
      if (s == null) return;
      final rgb = s.color.value;
      if (seenRgb.add(rgb)) allSwatches.add(s);
    }

    addSwatch(palette.vibrantColor);
    addSwatch(palette.lightVibrantColor);
    addSwatch(palette.darkVibrantColor);
    addSwatch(palette.dominantColor);
    addSwatch(palette.mutedColor);
    addSwatch(palette.darkMutedColor);
    addSwatch(palette.lightMutedColor);

    if (allSwatches.isEmpty) {
      return [_tuneColorForMesh(fallbackColor, 0.62, 1.08, 0.75, 0.38, 0.9)];
    }

    // ── Rank by population * vibrancyBonus, same as `calculateColorWeight`. ──
    final rankedSwatches = [...allSwatches]
      ..sort((a, b) => _colorWeight(b).compareTo(_colorWeight(a)));

    final availableColors = <Color>[];

    void addIfUnique(Color color, double saturationFactor) {
      if (!_isSimilarToAny(color, availableColors)) {
        availableColors.add(_enhanceColorVividness(color, saturationFactor));
      }
    }

    for (final swatch in rankedSwatches) {
      final hsv = HSVColor.fromColor(swatch.color);
      final satFactor = hsv.saturation > 0.3 ? 1.25 : 1.05;
      addIfUnique(swatch.color, satFactor);
      if (availableColors.length >= 6) break;
    }

    // ── Weighted saturation across all swatches (population-weighted),
    // same as the Kotlin `weightedExtractedSaturation`. ──
    final totalPopulation = math.max(
      1,
      allSwatches.fold<int>(0, (sum, s) => sum + s.population),
    );
    double weightedSatSum = 0;
    for (final s in allSwatches) {
      final hsv = HSVColor.fromColor(s.color);
      weightedSatSum += hsv.saturation * s.population;
    }
    final weightedExtractedSaturation = weightedSatSum / totalPopulation;

    final dominantColor =
        availableColors.isNotEmpty ? availableColors.first : fallbackColor;
    final isGreyscaleImage =
        weightedExtractedSaturation < 0.22 || _isNearGray(dominantColor);

    if (isGreyscaleImage) {
      availableColors.clear();
      double baseBrightness = 0.10;
      if (allSwatches.isNotEmpty) {
        final biggest =
            allSwatches.reduce((a, b) => a.population >= b.population ? a : b);
        baseBrightness = HSVColor.fromColor(biggest.color).value;
      }
      final greyStops = <double>[
        (baseBrightness * 1.2).clamp(0.06, 0.40),
        (baseBrightness * 0.9).clamp(0.04, 0.28),
        (baseBrightness * 0.6).clamp(0.02, 0.16),
        (baseBrightness * 1.4).clamp(0.08, 0.44),
        (baseBrightness * 0.7).clamp(0.03, 0.20),
        (baseBrightness * 0.5).clamp(0.01, 0.12),
      ];
      while (availableColors.length < 6) {
        final v = greyStops[availableColors.length % greyStops.length];
        availableColors.add(
          const HSVColor.fromAHSV(1.0, 0, 0, 0).withValue(v).toColor(),
        );
      }
      return availableColors;
    }

    Color fallbackSeed = fallbackColor;
    if (_isNearGray(fallbackSeed)) {
      final dom = palette.dominantColor?.color;
      fallbackSeed =
          (dom != null && !_isNearGray(dom)) ? dom : Colors.grey.shade800;
    }

    final seed = availableColors.isNotEmpty ? availableColors.first : fallbackSeed;
    const targets = [25.0, -25.0, 55.0, -55.0, 120.0, -120.0, 180.0, 150.0, -150.0];
    const valueTargets = [0.82, 0.74, 0.68, 0.6, 0.86, 0.7];

    final baseCandidates = <Color>{...availableColors, seed}.toList();
    var baseIndex = 0;
    var targetIndex = 0;
    while (availableColors.length < 6) {
      final baseColor = baseCandidates[baseIndex % baseCandidates.length];
      final hueShiftDegrees = targets[targetIndex % targets.length];
      final valueTarget = valueTargets[availableColors.length % valueTargets.length];
      final derived = _tuneColorForMesh(
        _hueShift(baseColor, hueShiftDegrees),
        0.62,
        1.08,
        valueTarget,
        0.38,
        0.9,
      );
      if (!_isSimilarToAny(derived, availableColors)) {
        availableColors.add(derived);
      }
      baseIndex++;
      targetIndex++;
      if (baseIndex > 40) break;
    }

    if (availableColors.isEmpty) {
      availableColors.add(_tuneColorForMesh(fallbackSeed, 0.62, 1.08, 0.75, 0.38, 0.9));
    }

    return availableColors;
  }

  static Color _enhanceColorVividness(Color color, [double saturationFactor = 1.4]) {
    final hsv = HSVColor.fromColor(color);
    final sat = (hsv.saturation * saturationFactor).clamp(0.0, 1.0);
    final val = (hsv.value * 1.02).clamp(0.32, 0.88);
    return hsv.withSaturation(sat).withValue(val).toColor();
  }

  static double _colorWeight(PaletteColor? swatch) {
    if (swatch == null) return 0;
    final population = swatch.population.toDouble();
    final hsv = HSVColor.fromColor(swatch.color);
    final saturation = hsv.saturation;
    final brightness = hsv.value;
    final vibrancyBonus =
        (saturation > 0.3 && brightness >= 0.2 && brightness <= 0.9) ? 1.3 : 1.0;
    return population * vibrancyBonus;
  }

  static bool _isSimilarColor(Color? c1, Color? c2) {
    if (c1 == null || c2 == null) return false;
    final hsv1 = HSVColor.fromColor(c1);
    final hsv2 = HSVColor.fromColor(c2);

    final hueDiffRaw = (hsv1.hue - hsv2.hue).abs();
    final hueDiff = math.min(hueDiffRaw, 360 - hueDiffRaw);
    final satDiff = (hsv1.saturation - hsv2.saturation).abs();
    final valueDiff = (hsv1.value - hsv2.value).abs();
    if (hueDiff < 12 && satDiff < 0.12 && valueDiff < 0.12) return true;

    const threshold = 28;
    final r1 = (c1.r * 255).round();
    final g1 = (c1.g * 255).round();
    final b1 = (c1.b * 255).round();
    final r2 = (c2.r * 255).round();
    final g2 = (c2.g * 255).round();
    final b2 = (c2.b * 255).round();

    return (r1 - r2).abs() < threshold &&
        (g1 - g2).abs() < threshold &&
        (b1 - b2).abs() < threshold;
  }

  static bool _isSimilarToAny(Color color, List<Color> colors) =>
      colors.any((c) => _isSimilarColor(color, c));

  static Color _hueShift(Color color, double degrees) {
    final hsv = HSVColor.fromColor(color);
    final newHue = ((hsv.hue + degrees) % 360 + 360) % 360;
    return hsv.withHue(newHue).toColor();
  }

  static Color _tuneColorForMesh(
    Color color,
    double saturationMin,
    double saturationBoost,
    double valueTarget,
    double valueMin,
    double valueMax,
  ) {
    final hsv = HSVColor.fromColor(color);
    final sat = (math.max(hsv.saturation, saturationMin) * saturationBoost).clamp(0.0, 1.0);
    final val = (hsv.value * 0.85 + valueTarget * 0.15).clamp(valueMin, valueMax);
    return hsv.withSaturation(sat).withValue(val).toColor();
  }

  static bool _isNearGray(Color color) {
    final hsv = HSVColor.fromColor(color);
    return hsv.saturation < 0.15 || hsv.value < 0.08;
  }
}
