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
  static const Color accent      = Color(0xFF9B7EDE);
  static const Color accentLight = Color(0xFFB69FEE);
  static const Color accentDark  = Color(0xFF7A5FC4);

  // ── Dark Theme ──
  // ECHO NIGHTLY MATCH ("ekdam dark na rahe"): Echo's default dark mode
  // is NOT flat black — its base theme (Base.Theme.Echo) extends
  // Material3's DynamicColors, so echoBackground = ?colorSurface, a
  // Material You tonal surface that carries a subtle hue from the
  // seed/wallpaper color rather than being neutral grey. Flat true-black
  // only exists as Echo's separate opt-in "Amoled" style
  // (echoBackground = @color/amoled_bg) — the two are deliberately
  // different tones, not the same black at two names.
  //
  // Astra's old darkBg (0xFF050508) and amoledBg (0xFF000000) were only
  // 5 units apart — indistinguishable in practice, so "Dark" mode never
  // actually looked different from Amoled. Rebuilt below the same way
  // Echo derives its palette: one shared hue (258°, the app's own brand
  // violet — accent/accentLight/accentDark above), stepped lightness per tier,
  // low-but-perceptible saturation (~16%) so the cast reads as a
  // deliberate charcoal-violet surface rather than a color error, while
  // AMOLED below stays exactly the flat true-black it always was.
  // hianime.at reference match ("complete dark na ho"): the user pointed
  // at hianime's dark forum UI — a clearly-tinted navy-violet surface, not
  // near-black. Previous darkBg (0xFF08070A) was only marginally lighter
  // than pure black and read as flat/AMOLED-like at a glance. Retuned to
  // sit visibly higher in lightness while keeping the same 258° brand hue,
  // so "Dark" now reads as a deliberate navy surface the way hianime's does,
  // and stays clearly distinct from the separate (still flat-black) AMOLED
  // mode below.
  static const Color darkBg          = Color(0xFF13121C);
  static const Color darkBgCard      = Color(0xFF1B1927);
  static const Color darkBgElevated  = Color(0xFF201E2E);
  static const Color darkBgSurface   = Color(0xFF272433);
  static const Color darkTextPrimary = Color(0xFFF0EBD8);
  static const Color darkTextSecondary = Color(0xFF8A8A9A);
  static const Color darkTextMuted   = Color(0xFF4A4A5E);
  static const Color darkDivider     = Color(0xFF2E2B3C);

  // ── AMOLED Theme ──
  static const Color amoledBg          = Color(0xFF000000);
  static const Color amoledBgCard      = Color(0xFF0A0A0A);
  static const Color amoledBgElevated  = Color(0xFF0F0F0F);
  static const Color amoledBgSurface   = Color(0xFF141414);
  static const Color amoledDivider     = Color(0xFF1A1A1A);

  // ── Light Theme ──
  // Echo Nightly parity: its light mode never hand-picks a separate
  // "cream" vs "white" pair — every surface (echoBackground = colorSurface,
  // navBackground = colorSurfaceContainer, cards = colorSurfaceContainerHigh)
  // is derived from ONE Material3 tonal palette, stepping lightness by only
  // a couple of points per tier. That's why gaps between Echo's cards never
  // read as a patch: base/nav/card are the same hue within a tight ~2-4%
  // lightness band, not two different hues (cream vs pure white) 5%+ apart.
  // Reworked here the same way — one warm-neutral hue across all four
  // tiers, in Echo's own base→nav→card lightness order (base darkest,
  // card lightest, matching colorSurface → colorSurfaceContainerHigh):
  //   lightBg (base, darkest) → lightBgSurface (nav/sections)
  //   → lightBgElevated → lightBgCard (cards, lightest)
  static const Color lightBg           = Color(0xFFF5F3ED);
  static const Color lightBgSurface    = Color(0xFFEEEBE2);
  static const Color lightBgElevated   = Color(0xFFF2F0E8);
  static const Color lightBgCard       = Color(0xFFF9F7F1);
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
  static const LinearGradient accentGradient = LinearGradient(
    colors: [accentDark, accent, accentLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Dynamic-theme-aware version of accentGradient — uses the live
  /// wallpaper-derived accent shades when Dynamic Color mode is active,
  /// otherwise falls back to the fixed accentGradient above.
  static LinearGradient accentGradientOf(BuildContext context) => LinearGradient(
    colors: [accentDarkOf(context), accentOf(context), accentLightOf(context)],
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
  /// by Android 12+) instead of Aurum's fixed purple/accent palette. `dynamic`
  /// must be a real scheme obtained from DynamicColorBuilder; there is no
  /// fallback here on purpose — callers (ThemeProvider) are responsible for
  /// falling back to _dark()/_light() when the platform doesn't support it.
  static ThemeData dynamicTheme(ColorScheme dynamic) {
    final isLight = dynamic.brightness == Brightness.light;

    // FIX v3 — over-saturated "whole screen looks tinted pink" (round 3):
    // v2's satBoost of 0.10-0.15 was applied to background/card surfaces,
    // not just the accent — on a vivid wallpaper hue that pushes bg
    // saturation up alongside its lightness cut, so every surface (not
    // just buttons/icons) reads as one solid wash of the wallpaper color.
    // Google's own Material You never boosts *background* saturation this
    // aggressively — surfaces stay near-neutral/subtle even against a
    // vivid wallpaper; only small accent elements (buttons, active icons,
    // highlights) are allowed to read as vividly colored. Backgrounds now
    // only deepen lightness (the part that actually fixed v1's "washed
    // out/flat" complaint) with a much smaller satBoost — just enough to
    // avoid looking gray, not enough to look painted. Accent below is
    // unchanged — it is a small element by design, so a stronger boost
    // there is still correct. Dark mode is untouched — Android's dark
    // tonal palette is already low-key and reads as premium as-is.
    Color enrich(Color c, {required double lightness, required double satBoost}) {
      final hsl = HSLColor.fromColor(c);
      return hsl
          .withSaturation((hsl.saturation + satBoost).clamp(0.0, 1.0))
          .withLightness(lightness.clamp(0.0, 1.0))
          .toColor();
    }

    // FIX v2 — muddy/terracotta-looking accent in light mode: Android's
    // raw dynamic `primary` tone is tuned for text-on-tint contrast, not
    // for reading as a vivid brand accent — against Aurum's enriched
    // (still fairly light) card surfaces it came across desaturated and
    // brownish rather than a clean wallpaper-purple/whatever-hue accent.
    // Pull saturation up and lightness into a fixed, more vivid band so
    // the accent pops the same way the fixed-purple theme's accent does,
    // while still tracking the wallpaper's actual hue.
    Color punchUpAccent(Color c, {required double lightness, required double minSat}) {
      final hsl = HSLColor.fromColor(c);
      final sat = hsl.saturation < minSat ? minSat : hsl.saturation;
      return hsl.withSaturation(sat).withLightness(lightness).toColor();
    }

    // FIX v4 — "whole screen looks like one pink wash" (round 4): v3 still
    // put a non-zero satBoost on EVERY surface tier (0.02→0.05, increasing
    // as lightness dropped), which is exactly backwards — lower lightness
    // + rising saturation compounds into a visibly tinted card/surface/
    // elevated stack, not a neutral one. Google's own dynamic-color apps
    // (Files, Photos, etc.) keep every background tier at ~0 added
    // saturation and only step lightness a few points apart — color only
    // shows up on accent elements (icons, buttons, chips), never as a wash
    // across the whole screen. satBoost is now 0 on all four tiers; the
    // lightness band is also flattened (0.99→0.90 instead of 0.93→0.83) so
    // tiers stay close together the way Files' base/nav/card tiers do,
    // rather than sinking into a visibly darker pink at each step.
    final bg = isLight
        ? enrich(dynamic.surface, lightness: 0.99, satBoost: 0.0)
        : dynamic.surface;
    final bgCard = isLight
        ? enrich(dynamic.surfaceContainer, lightness: 0.96, satBoost: 0.0)
        : dynamic.surfaceContainer;
    final bgSurface = isLight
        ? enrich(dynamic.surfaceContainerHigh, lightness: 0.93, satBoost: 0.0)
        : dynamic.surfaceContainerHigh;
    final bgElevated = isLight
        ? enrich(dynamic.surfaceContainerHighest, lightness: 0.90, satBoost: 0.0)
        : dynamic.surfaceContainerHighest;

    // Text/divider tones — no satBoost either, same reasoning as above.
    // Lightness targets unchanged from v3 (these were fine — the earlier
    // "collapsed contrast" bug this fixed is about darkness, not hue).
    final textMuted = isLight
        ? enrich(dynamic.onSurfaceVariant, lightness: 0.38, satBoost: 0.0)
        : dynamic.onSurfaceVariant;
    final divider = isLight
        ? enrich(dynamic.outlineVariant, lightness: 0.72, satBoost: 0.0)
        : dynamic.outlineVariant;

    // Accent (primary/secondary) — punched up in light mode only, for the
    // same "reads as a real accent, not a muddy tint" reason as bg above.
    final accentPrimary = isLight
        ? punchUpAccent(dynamic.primary, lightness: 0.46, minSat: 0.45)
        : dynamic.primary;
    final accentSecondary = isLight
        ? punchUpAccent(dynamic.secondary, lightness: 0.58, minSat: 0.30)
        : dynamic.secondary;

    final enrichedScheme = dynamic.copyWith(
      primary: accentPrimary,
      // onPrimary/onSecondary must stay readable against the NEW punched-up
      // primary/secondary above, not the raw (usually much lighter) dynamic
      // ones the original onPrimary/onSecondary were calculated for — both
      // enriched tones sit well below 0.5 lightness in light mode, so white
      // text/icons on top is the correct contrast choice there.
      onPrimary: isLight ? Colors.white : dynamic.onPrimary,
      secondary: accentSecondary,
      onSecondary: isLight ? Colors.white : dynamic.onSecondary,
      surfaceContainerHighest: bgElevated,
      surfaceContainerHigh: bgSurface,
      onSurfaceVariant: textMuted,
      outlineVariant: divider,
    );

    return _build(
      brightness: dynamic.brightness,
      bg: bg,
      bgCard: bgCard,
      bgSurface: bgSurface,
      textPrimary: dynamic.onSurface,
      textMuted: textMuted,
      divider: divider,
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
    // (wallpaper-derived) replace Aurum's fixed accent everywhere below —
    // that's the whole point of this mode. Otherwise fall back to accent.
    final primary   = dynamicScheme?.primary ?? accent;
    final secondary = dynamicScheme?.secondary ?? accentLight;
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
      // FIX — "3-dot menu open karte hi white/grey layer flash hoti hai"
      // (Downloads screen, Playlist song-row menu): PopupMenuButton never
      // had a global PopupMenuThemeData, so Material 3 fell back to its
      // own default surfaceTintColor (colorScheme.surfaceTint) and painted
      // an elevation-tint overlay UNDER the per-call `color:` on every
      // PopupMenuButton in the app during the open animation — that
      // overlay was the flash. The per-call `color:` only sets the final
      // fill, it never touched this tint layer. Killing surfaceTintColor
      // (and shadowColor, for the same reason on the elevation shadow)
      // globally here removes the flash everywhere PopupMenuButton is
      // used, not just Downloads/Playlist.
      popupMenuTheme: PopupMenuThemeData(
        color: bgCard,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 4,
      ),
      // FIX — same surfaceTint/shadow flash as popupMenuTheme above, but
      // for every OTHER Material 3 surface that opens on top of the app
      // without an explicit theme: AlertDialog/showDialog, any raw
      // showModalBottomSheet call that doesn't pass backgroundColor,
      // DropdownMenu, and Menu/MenuAnchor/MenuBar. None of these had a
      // theme entry before, so all of them independently fell back to
      // Material 3's default surfaceTint-over-surface painting — the
      // exact same untethered white/grey flash bug as the popup menu,
      // just on different widgets. Centralizing all of them here means
      // no future screen can reintroduce this class of bug by adding a
      // new dialog/sheet/dropdown without explicitly opting back into a
      // tint (which nothing in this app's design wants).
      dialogTheme: DialogThemeData(
        backgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 8,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: bgCard,
        modalBackgroundColor: bgCard,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: Colors.black.withAlpha(115),
        shadowColor: Colors.transparent,
        elevation: 8,
        modalElevation: 8,
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(bgCard),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(4),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(bgCard),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(4),
        ),
      ),
      // FIX — THE actual, confirmed source of the "ghost pill": this
      // theme sets bottomNavigationBarTheme.backgroundColor to a solid
      // card color (navBar). Even though the app's own bottom bar widget
      // (AurumBottomNavBar) paints nothing itself, Flutter's Scaffold
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
      // FIX — toggle switches nearly invisible in light dynamic mode:
      // with no switchTheme set, Flutter's Material 3 default paints the
      // OFF-state track from the ambient ColorScheme's surfaceVariant-ish
      // tone, which in the (already fairly light) dynamic light scheme
      // sat only a few percent off the card background it usually sits
      // on — track and card blended together. Explicit colors here tie
      // the switch to the same enriched bg/text tones the rest of the
      // theme uses, so OFF reads as a clearly visible muted track and ON
      // reads as the accent, in both light and dark, dynamic or fixed.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primary;
          return isDark ? darkTextMuted : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primary.withOpacity(0.5);
          }
          return isDark ? bgSurface : divider;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return divider;
        }),
      ),
      // FIX — default IconThemeData ignored the dynamic scheme entirely,
      // always falling back to the fixed static darkTextSecondary/
      // lightTextSecondary constants even in Material You mode, so
      // generic icons (anything not explicitly colored by a widget)
      // never picked up the wallpaper hue the rest of the screen did.
      iconTheme: IconThemeData(
        color: dynamicScheme != null ? textMuted : (isDark ? darkTextSecondary : lightTextSecondary),
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
  /// chosen accent (or accent by default). Screens that currently reference
  /// the `accent` constant directly can switch to this to pick up dynamic
  /// theming automatically; existing `AurumTheme.accent` references keep
  /// working unchanged (they just won't react to wallpaper color).
  static Color accentOf(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// Lighter accent variant for the current theme — the wallpaper-derived
  /// Material You secondary color when Dynamic Color mode is active,
  /// otherwise the fixed accentLight constant. Use alongside accentOf()
  /// wherever a gradient/lerp needs a light-tone companion to the accent.
  static Color accentLightOf(BuildContext context) =>
      Theme.of(context).extension<_DynamicMarker>() != null
          ? Theme.of(context).colorScheme.secondary
          : accentLight;

  /// Darker accent variant for the current theme — derived from the
  /// active ColorScheme's primary when Dynamic Color mode is active
  /// (darkened, since Material You schemes don't expose a distinct
  /// "dark" tier the way the fixed palette does), otherwise the fixed
  /// accentDark constant.
  static Color accentDarkOf(BuildContext context) {
    if (Theme.of(context).extension<_DynamicMarker>() == null) return accentDark;
    final hsl = HSLColor.fromColor(Theme.of(context).colorScheme.primary);
    return hsl.withLightness((hsl.lightness - 0.15).clamp(0.0, 1.0)).toColor();
  }

  // ── Decorations ──
  static BoxDecoration cardDecorationOf(BuildContext context) => BoxDecoration(
    color: bgCardOf(context),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: dividerOf(context), width: 0.5),
  );

  static BoxDecoration accentCardDecorationOf(BuildContext context) => BoxDecoration(
    color: bgCardOf(context),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: accent.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: accent.withOpacity(0.08),
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

  static BoxDecoration get accentCardDecoration => BoxDecoration(
    color: bgCard,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: accent.withOpacity(0.3), width: 0.5),
    boxShadow: [
      BoxShadow(
        color: accent.withOpacity(0.08),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ],
  );
}
