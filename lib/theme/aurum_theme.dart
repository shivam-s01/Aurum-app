import 'package:flutter/material.dart';

/// Zero-data marker stashed in ThemeData.extensions only when a theme was
/// built via AurumTheme.dynamicTheme(). Lets context-aware color helpers
/// (textMutedOf, bgSurfaceOf, etc.) detect "we're in Material You mode"
/// without threading an extra bool through every call site — they just
/// check Theme.of(context).extensions for this key.
class _DynamicMarker extends ThemeExtension<_DynamicMarker> {
  const _DynamicMarker();
  @override
  _DynamicMarker copyWith() => this;
  @override
  _DynamicMarker lerp(ThemeExtension<_DynamicMarker>? other, double t) => this;
}

class AurumTheme {
  // ── Brand Colors (fixed, theme-independent) ──
  static const Color gold      = Color(0xFF9B7EDE);
  static const Color goldLight = Color(0xFFB69FEE);
  static const Color goldDark  = Color(0xFF7A5FC4);

  // ── Dark Theme ──
  static const Color darkBg          = Color(0xFF050508);
  static const Color darkBgCard      = Color(0xFF0D0D14);
  static const Color darkBgElevated  = Color(0xFF12121C);
  static const Color darkBgSurface   = Color(0xFF1A1A28);
  static const Color darkTextPrimary = Color(0xFFF0EBD8);
  static const Color darkTextSecondary = Color(0xFF8A8A9A);
  static const Color darkTextMuted   = Color(0xFF4A4A5E);
  static const Color darkDivider     = Color(0xFF1E1E2E);

  // ── AMOLED Theme ──
  static const Color amoledBg          = Color(0xFF000000);
  static const Color amoledBgCard      = Color(0xFF0A0A0A);
  static const Color amoledBgElevated  = Color(0xFF0F0F0F);
  static const Color amoledBgSurface   = Color(0xFF141414);
  static const Color amoledDivider     = Color(0xFF1A1A1A);

  // ── Light Theme ──
  static const Color lightBg           = Color(0xFFF8F6F0);
  static const Color lightBgCard       = Color(0xFFFFFFFF);
  static const Color lightBgElevated   = Color(0xFFF0EDE4);
  static const Color lightBgSurface    = Color(0xFFE8E4D8);
  static const Color lightTextPrimary  = Color(0xFF1A1610);
  static const Color lightTextSecondary = Color(0xFF6B6456);
  static const Color lightTextMuted    = Color(0xFFAA9F8E);
  static const Color lightDivider      = Color(0xFFE0D8C8);

  // ── Legacy aliases (keep for backward compat) ──
  static const Color bg           = darkBg;
  static const Color bgCard       = darkBgCard;
  static const Color bgElevated   = darkBgElevated;
  static const Color bgSurface    = darkBgSurface;
  static const Color textPrimary  = darkTextPrimary;
  static const Color textSecondary = darkTextSecondary;
  static const Color textMuted    = darkTextMuted;
  static const Color divider      = darkDivider;

  // ── Gradients ──
  static const LinearGradient goldGradient = LinearGradient(
    colors: [goldDark, gold, goldLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient bgGradient = LinearGradient(
    colors: [darkBg, darkBgCard],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  // ── Theme Builders ──
  static ThemeData get theme      => _dark();
  static ThemeData get darkTheme  => _dark();
  static ThemeData get amoledTheme => _amoled();
  static ThemeData get lightTheme => _light();

  static ThemeData _dark() => _build(
    brightness: Brightness.dark,
    bg: darkBg,
    bgCard: darkBgCard,
    bgSurface: darkBgSurface,
    textPrimary: darkTextPrimary,
    textMuted: darkTextMuted,
    divider: darkDivider,
    navBar: darkBgCard,
  );

  static ThemeData _amoled() => _build(
    brightness: Brightness.dark,
    bg: amoledBg,
    bgCard: amoledBgCard,
    bgSurface: amoledBgSurface,
    textPrimary: darkTextPrimary,
    textMuted: darkTextMuted,
    divider: amoledDivider,
    navBar: amoledBgCard,
  );

  static ThemeData _light() => _build(
    brightness: Brightness.light,
    bg: lightBg,
    bgCard: lightBgCard,
    bgSurface: lightBgSurface,
    textPrimary: lightTextPrimary,
    textMuted: lightTextMuted,
    divider: lightDivider,
    navBar: lightBgCard,
  );

  /// Material You / "wallpaper theme" builder — derives every surface from
  /// the system's dynamic ColorScheme (harvested from the device wallpaper
  /// by Android 12+) instead of Aurum's fixed purple/gold palette. `dynamic`
  /// must be a real scheme obtained from DynamicColorBuilder; there is no
  /// fallback here on purpose — callers (ThemeProvider) are responsible for
  /// falling back to _dark()/_light() when the platform doesn't support it.
  static ThemeData dynamicTheme(ColorScheme dynamic) {
    final isLight = dynamic.brightness == Brightness.light;

    // FIX — "washed out" light dynamic mode: Android's raw light-mode
    // tonal palette (surface/surfaceContainer/surfaceContainerHigh) sits
    // at ~96-99% lightness by design — it's built for text-heavy system
    // UI, not for a media app's premium feel. Used as-is, every surface
    // reads as near-white with barely a tint, which is why it looked
    // flat/cheap next to the dark theme's rich low-lightness surfaces.
    // Google's own apps (Gmail, Photos) don't use the raw tones directly
    // either — they deepen them for a "premium tinted paper" look. We
    // recreate that here by re-deriving each surface from the scheme's
    // own hue/saturation but pulling lightness down and saturation up a
    // little — same wallpaper hue, richer execution. Dark mode is left
    // untouched since Android's dark tonal palette is already low-key and
    // reads as premium as-is (confirmed working from earlier screenshots).
    Color enrich(Color c, {required double lightness, required double satBoost}) {
      final hsl = HSLColor.fromColor(c);
      return hsl
          .withSaturation((hsl.saturation + satBoost).clamp(0.0, 1.0))
          .withLightness(lightness)
          .toColor();
    }

    final bg = isLight
        ? enrich(dynamic.surface, lightness: 0.93, satBoost: 0.08)
        : dynamic.surface;
    final bgCard = isLight
        ? enrich(dynamic.surfaceContainer, lightness: 0.88, satBoost: 0.10)
        : dynamic.surfaceContainer;
    final bgSurface = isLight
        ? enrich(dynamic.surfaceContainerHigh, lightness: 0.83, satBoost: 0.12)
        : dynamic.surfaceContainerHigh;
    // Primary/secondary (buttons, accents) also get a small richness pass
    // in light mode — Android's light-mode primary tone is tuned for
    // 4.5:1 text contrast on white, which reads a bit chalky as a solid
    // accent fill. A touch more saturation and a bit less lightness makes
    // it pop the way it already does in dark mode.
    final primary = isLight
        ? enrich(dynamic.primary, lightness: 0.42, satBoost: 0.10)
        : dynamic.primary;
    final secondary = isLight
        ? enrich(dynamic.secondary, lightness: 0.40, satBoost: 0.08)
        : dynamic.secondary;

    final enrichedScheme = isLight
        ? dynamic.copyWith(
            primary: primary,
            onPrimary: Colors.white,
            secondary: secondary,
            onSecondary: Colors.white,
          )
        : dynamic;

    return _build(
      brightness: dynamic.brightness,
      bg: bg,
      bgCard: bgCard,
      bgSurface: bgSurface,
      textPrimary: dynamic.onSurface,
      textMuted: dynamic.onSurfaceVariant,
      divider: dynamic.outlineVariant,
      navBar: bgCard,
      dynamicScheme: enrichedScheme,
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color bgCard,
    required Color bgSurface,
    required Color textPrimary,
    required Color textMuted,
    required Color divider,
    required Color navBar,
    ColorScheme? dynamicScheme,
  }) {
    final isDark = brightness == Brightness.dark;
    // When a real Material You scheme is supplied, its own primary/secondary
    // (wallpaper-derived) replace Aurum's fixed gold everywhere below —
    // that's the whole point of this mode. Otherwise fall back to gold.
    final primary   = dynamicScheme?.primary ?? gold;
    final secondary = dynamicScheme?.secondary ?? goldLight;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      // FIX — belt-and-suspenders alongside bottomNavigationBarTheme
      // below: `canvasColor` is the actual fallback color Material
      // widgets paint when nothing more specific is set, and it's what
      // the Scaffold's implicit bottomNavigationBar-wrapping Material
      // falls back to whenever Material 3's elevation/surface-tint
      // resolution kicks in on a given frame (this varies frame-to-frame
      // depending on animation/elevation state, which is exactly why the
      // pill appeared to come and go "randomly" instead of consistently).
      // Forcing this transparent removes that fallback fill everywhere
      // it could apply, not just on the one theme property.
      canvasColor: Colors.transparent,
      colorScheme: (dynamicScheme ?? ColorScheme(
        brightness: brightness,
        primary: primary,
        onPrimary: bg,
        secondary: secondary,
        onSecondary: bg,
        surface: bgCard,
        onSurface: textPrimary,
        background: bg,
        onBackground: textPrimary,
        error: Colors.redAccent,
        onError: Colors.white,
      )).copyWith(
        // Always keep Aurum's own surface/background mapping regardless of
        // scheme source, since bgCard/bg here already encode the AMOLED vs
        // dark vs dynamic bg choice made by the caller above.
        surface: bgCard,
        onSurface: textPrimary,
        background: bg,
        onBackground: textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      // FIX — THE actual, confirmed source of the "ghost pill": this
      // theme sets bottomNavigationBarTheme.backgroundColor to a solid
      // card color (navBar). Even though the app's own bottom bar widget
      // (_AurumBottomNavBar) paints nothing itself, Flutter's Scaffold
      // wraps whatever is passed to `bottomNavigationBar:` in its own
      // Material, and that Material's default fill comes from THIS exact
      // theme property. That's why the pill was solid `lightBgCard`/
      // `darkBgCard` colored, appeared independent of any widget code
      // change, and only ever needed a full app restart to "go away"
      // (a theme rebuild reapplying this same value doesn't fix it,
      // since it was never the widget tree at fault). Setting it to
      // transparent here removes the fill at its actual source.
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        selectedItemColor: primary,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: bgSurface,
        thumbColor: primary,
        overlayColor: primary.withOpacity(0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      iconTheme: IconThemeData(
        color: isDark ? darkTextSecondary : lightTextSecondary,
      ),
      dividerColor: divider,
      cardColor: bgCard,
      extensions: dynamicScheme != null ? const [_DynamicMarker()] : const [],
    );
  }

  // ── Context-aware helpers ──
  static Color bgOf(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;

  static Color bgCardOf(BuildContext context) =>
      Theme.of(context).colorScheme.surface;

  static Color textPrimaryOf(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  static Color textSecondaryOf(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkTextSecondary : lightTextSecondary;
  }

  static Color textMutedOf(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Dynamic (Material You) schemes carry a real onSurfaceVariant tone
    // derived from the wallpaper — use it instead of the fixed static
    // muted-gray constants so "muted" text still reads as part of the
    // wallpaper palette instead of falling back to the old gray.
    if (_isDynamic(context)) return scheme.onSurfaceVariant;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkTextMuted : lightTextMuted;
  }

  static Color dividerOf(BuildContext context) =>
      Theme.of(context).dividerColor;

  static Color bgElevatedOf(BuildContext context) {
    if (_isDynamic(context)) return Theme.of(context).colorScheme.surfaceContainerHighest;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBgElevated : lightBgElevated;
  }

  static Color bgSurfaceOf(BuildContext context) {
    if (_isDynamic(context)) return Theme.of(context).colorScheme.surfaceContainerHigh;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBgSurface : lightBgSurface;
  }

  /// True when the currently active ThemeData was built by dynamicTheme()
  /// — detected via a marker we stash on extensions rather than threading
  /// a flag through every helper call site.
  static bool _isDynamic(BuildContext context) =>
      Theme.of(context).extension<_DynamicMarker>() != null;

  /// Accent color for the current theme — the wallpaper-derived Material
  /// You color when Dynamic Color mode is active, otherwise the user's
  /// chosen accent (or gold by default). Screens that currently reference
  /// the `gold` constant directly can switch to this to pick up dynamic
  /// theming automatically; existing `AurumTheme.gold` references keep
  /// working unchanged (they just won't react to wallpaper color).
  static Color accentOf(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  // ── Decorations ──
  static BoxDecoration cardDecorationOf(BuildContext context) => BoxDecoration(
    color: bgCardOf(context),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: dividerOf(context), width: 0.5),
  );

  static BoxDecoration goldCardDecorationOf(BuildContext context) => BoxDecoration(
    color: bgCardOf(context),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: gold.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: gold.withOpacity(0.08),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );

  // ── Legacy static decorations (backward compat) ──
  static BoxDecoration get cardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: divider, width: 0.5),
  );

  static BoxDecoration get goldCardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: gold.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: gold.withOpacity(0.08),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
