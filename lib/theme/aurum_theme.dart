import 'package:flutter/material.dart';

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

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color bgCard,
    required Color bgSurface,
    required Color textPrimary,
    required Color textMuted,
    required Color divider,
    required Color navBar,
  }) {
    final isDark = brightness == Brightness.dark;
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
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: gold,
        onPrimary: bg,
        secondary: goldLight,
        onSecondary: bg,
        surface: bgCard,
        onSurface: textPrimary,
        background: bg,
        onBackground: textPrimary,
        error: Colors.redAccent,
        onError: Colors.white,
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
        selectedItemColor: gold,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: gold,
        inactiveTrackColor: bgSurface,
        thumbColor: gold,
        overlayColor: gold.withOpacity(0.2),
        trackHeight: 3,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      iconTheme: IconThemeData(
        color: isDark ? darkTextSecondary : lightTextSecondary,
      ),
      dividerColor: divider,
      cardColor: bgCard,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkTextMuted : lightTextMuted;
  }

  static Color dividerOf(BuildContext context) =>
      Theme.of(context).dividerColor;

  static Color bgElevatedOf(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBgElevated : lightBgElevated;
  }

  static Color bgSurfaceOf(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? darkBgSurface : lightBgSurface;
  }

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
