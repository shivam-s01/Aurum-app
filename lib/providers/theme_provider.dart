import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/aurum_theme.dart';

enum AurumThemeMode { dark, light, amoled, system, dynamic }

// FIX ("system dark mode toggle karte huye app khula rehta hai toh dynamic
// theme switch nahi hota" — dynamic mode's themeMode getter below already
// reads WidgetsBinding.instance.platformDispatcher.platformBrightness LIVE,
// so the *value* was never stale — the bug was that nothing ever told
// Flutter to re-ask for it. DynamicColorBuilder in main.dart only rebuilds
// when the wallpaper-derived ColorScheme itself changes; a plain system
// dark/light toggle with no wallpaper change never fires that, and no
// other widget was listening for platform brightness changes either — so
// MaterialApp kept using whichever ThemeMode was last computed, frozen
// until *some* unrelated Provider happened to notifyListeners() and forced
// a rebuild. WidgetsBindingObserver's didChangePlatformBrightness() is the
// actual OS-level hook for this: implementing it here and calling
// notifyListeners() makes ThemeProvider itself push a rebuild the instant
// the system brightness flips, so dynamic mode (and system mode) react
// live while the app is open, exactly like Google's own dynamic-color apps.
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static const _key       = 'aurum_theme_mode';
  static const _fontKey   = 'font_style';
  static const _accentKey = 'accent_color';
  static const _btnColorKey = 'player_button_colors';
  static const _sliderStyleKey = 'player_slider_style';
  static const _fullPlayerStyleKey = 'full_player_style';

  AurumThemeMode _mode      = AurumThemeMode.dark;
  String         _fontStyle = 'Default';
  Color          _accentColor = AurumTheme.accent;
  String         _playerButtonColorMode = 'Primary';
  String         _playerSliderStyle = 'Rounded';
  String         _fullPlayerStyle = 'Classic';

  AurumThemeMode get mode      => _mode;
  String         get fontStyle => _fontStyle;

  /// Premium accent color override. Used by the player screen, player
  /// buttons, and sliders. Defaults to AurumTheme.accent so the rest of
  /// the app (which references AurumTheme.accent as a const) is unaffected.
  Color get accentColor => _accentColor;

  /// 'Primary' (default, white) | 'White' | 'Accent' — drives the color
  /// of the main play/pause button on the full player screen.
  String get playerButtonColorMode => _playerButtonColorMode;

  /// 'Slim' | 'Thick' | 'Rounded' (default) — seek bar track/thumb size.
  String get playerSliderStyle => _playerSliderStyle;

  /// 'Classic' (default, Astra-style full player) | 'Edge to Edge'
  /// (full-bleed edge-to-edge sheet style) — which full player screen
  /// opens when the user taps the mini player.
  String get fullPlayerStyle => _fullPlayerStyle;

  // Latest system Material You schemes, pushed in from DynamicColorBuilder
  // in main.dart on every rebuild (they change live if the user changes
  // wallpaper while the app is open — no restart needed). Null on Android
  // <12, other platforms, or devices that don't expose dynamic color; in
  // that case dynamic mode silently falls back to the normal dark theme
  // (see MainShell/AurumApp theme resolution).
  ColorScheme? _dynamicLight;
  ColorScheme? _dynamicDark;

  ColorScheme? get dynamicLight => _dynamicLight;
  ColorScheme? get dynamicDark  => _dynamicDark;

  /// True only when dynamic mode is selected AND the platform actually
  /// handed back a real wallpaper-derived scheme. Used to decide whether
  /// to render the theme as dynamic or silently fall back.
  bool get isDynamicAvailable =>
      _mode == AurumThemeMode.dynamic && _dynamicDark != null;

  void updateDynamicSchemes(ColorScheme? light, ColorScheme? dark) {
    // ColorScheme overrides == by value, but dynamic_color hands back a
    // freshly-allocated instance on every platform broadcast even when
    // nothing actually changed (e.g. the same wallpaper re-notifying, or
    // an unrelated system event). Using identical() here meant every one
    // of those no-op broadcasts still forced a full MaterialApp theme
    // rebuild — which is what was flickering the mini-player/hero artwork
    // to a blank placeholder for a frame while CachedNetworkImage briefly
    // re-resolved under the new (structurally identical) ThemeData. Value
    // equality skips the rebuild entirely when nothing really changed.
    if (light == _dynamicLight && dark == _dynamicDark) return;
    _dynamicLight = light;
    _dynamicDark = dark;
    if (_mode == AurumThemeMode.dynamic) notifyListeners();
  }

  // FIX — white/cream flash on cold start (confirmed root cause, not the
  // earlier DynamicColorBuilder-race theory): this getter used to return
  // ThemeMode.system for AurumThemeMode.dynamic. ThemeMode.system tells
  // Flutter's own MaterialApp to pick light-vs-dark by reading
  // platformBrightness ITSELF, completely independent of isDarkOf()'s
  // carefully-computed bool (which already folds in isDynamicAvailable,
  // isAmoled, etc.). So even when isDarkOf() correctly resolved "dark" for
  // this frame, MaterialApp could independently resolve "light" — and
  // since lightDynamic is very often still null this early (async platform
  // channel, see DynamicColorBuilder in main.dart), `theme:` at that point
  // is AurumTheme.lightTheme, whose lightBg (0xFFF8F6F0, cream) is exactly
  // the flash color reported. Longer async gaps (song loading) just widen
  // the window where MaterialApp's independent resolution can land on
  // "light" before dynamicDark/lightDynamic have arrived — matching
  // "sometimes never happens, sometimes shows, worse when loading is
  // slow". Returning an explicit dark/light here (never system) for
  // dynamic mode forces MaterialApp to use the SAME answer isDarkOf()
  // already computed, so there is no second, independent brightness
  // resolution left to race.
  ThemeMode get themeMode {
    switch (_mode) {
      case AurumThemeMode.system:  return ThemeMode.system;
      case AurumThemeMode.light:   return ThemeMode.light;
      case AurumThemeMode.dynamic:
        final platformBrightness =
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
        // Mirrors isDarkOf()'s dynamic branch exactly: dark unless the
        // platform is explicitly light AND we actually have a real
        // wallpaper-derived dark scheme to know that for sure. Before any
        // dynamic scheme has arrived (cold start / first frames), this
        // defaults to dark — never an independently-resolved "light".
        final isDark = platformBrightness != Brightness.light ||
            _dynamicDark == null;
        return isDark ? ThemeMode.dark : ThemeMode.light;
      default:
        return ThemeMode.dark;
    }
  }

  bool get isAmoled => _mode == AurumThemeMode.amoled;
  bool get isDynamic => _mode == AurumThemeMode.dynamic;

  // FIX (white/cream flash on first FullPlayerScreen open, "olash jaisa
  // white white aata hai" — production bug): pushFullPlayer() in
  // home_screen.dart and FullPlayerScreen's own Scaffold each used to
  // decide light-vs-dark by reading `Theme.of(context).brightness`
  // directly at their own build time. That's a DIFFERENT source of truth
  // than the `isDark` bool main.dart actually computes to pick
  // lightTheme/darkTheme in the first place (which also folds in isAmoled
  // and the isDynamic+platformBrightness special case below — brightness
  // alone doesn't capture those). Two independent call sites re-deriving
  // "is dark" from ambient Theme lookups is exactly the kind of thing that
  // goes stale for one frame: a route's pageBuilder can read Theme.of(
  // context) from a context whose nearest Theme ancestor hasn't yet
  // rebuilt with this frame's resolved theme (e.g. right after cold start
  // or a DynamicColorBuilder/Consumer2 rebuild pass that hasn't landed),
  // silently defaulting toward light — which is why the flash color seen
  // is the light cream (0xFFF5F0EA), never black, and why it only ever
  // shows on the FIRST open, not subsequent ones once the tree has
  // settled. Exposing the exact same boolean main.dart uses to choose the
  // MaterialApp theme means every other call site asks the one already-
  // resolved answer instead of re-deriving (and risking disagreeing with)
  // it independently.
  // FIX — themeMode (above) now resolves dynamic mode to an explicit
  // ThemeMode.dark/light itself (never .system), so it's already the
  // single source of truth for every mode including dynamic. Re-deriving
  // "is dark" here from platformBrightness/isDynamicAvailable a second
  // time was the other half of the original race: two independent
  // computations of the same fact, reading async state (platformBrightness,
  // _dynamicDark) at two different moments, could disagree for exactly one
  // frame. Delegating straight to themeMode removes that second
  // computation entirely.
  bool isDarkOf(BuildContext context) {
    if (themeMode == ThemeMode.dark) return true;
    if (themeMode == ThemeMode.light) return false;
    // Only AurumThemeMode.system reaches here (the only case still
    // mapping to ThemeMode.system) — that one legitimately follows the
    // OS setting.
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return platformBrightness == Brightness.dark;
  }

  ThemeProvider() {
    _load();
    WidgetsBinding.instance.addObserver(this);
  }

  // Fires whenever the OS-level brightness setting changes while the app
  // is running (system dark/light toggle, scheduled day/night switch,
  // battery-saver auto dark mode, etc.) — this is what was missing.
  // themeMode/isDarkOf() already compute the correct answer from
  // platformBrightness on every call; this just makes sure something
  // actually calls them again (via notifyListeners → MaterialApp rebuild)
  // the moment the OS reports the change, instead of waiting for an
  // unrelated rebuild to happen to pick up the new value.
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    // Only modes that actually derive from platform brightness need a
    // rebuild here — fixed dark/light/amoled selections are unaffected by
    // the OS setting, so skip the redundant notify for those.
    if (_mode == AurumThemeMode.system || _mode == AurumThemeMode.dynamic) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final val = p.getString(_key);
    if (val != null) {
      _mode = AurumThemeMode.values.firstWhere(
        (e) => e.name == val,
        orElse: () => AurumThemeMode.dark,
      );
    }
    _fontStyle = p.getString(_fontKey) ?? 'Default';
    final accentInt = p.getInt(_accentKey);
    if (accentInt != null) _accentColor = Color(accentInt);
    _playerButtonColorMode = p.getString(_btnColorKey) ?? _playerButtonColorMode;
    _playerSliderStyle = p.getString(_sliderStyleKey) ?? _playerSliderStyle;
    _fullPlayerStyle = p.getString(_fullPlayerStyleKey) ?? _fullPlayerStyle;
    notifyListeners();
  }

  Future<void> setPlayerButtonColorMode(String mode) async {
    _playerButtonColorMode = mode;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_btnColorKey, mode);
  }

  Future<void> setPlayerSliderStyle(String style) async {
    _playerSliderStyle = style;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_sliderStyleKey, style);
  }

  Future<void> setFullPlayerStyle(String style) async {
    _fullPlayerStyle = style;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_fullPlayerStyleKey, style);
  }

  Future<void> setAccentColor(Color color) async {
    _accentColor = color;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt(_accentKey, color.value);
  }

  Future<void> setMode(AurumThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, mode.name);
  }

  Future<void> setFontStyle(String style) async {
    _fontStyle = style;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setString(_fontKey, style);
  }

  /// Returns the TextTheme for current font selection
  TextTheme resolvedTextTheme(TextTheme base) {
    switch (_fontStyle) {
      case 'Rounded':
        return GoogleFonts.nunitoTextTheme(base);
      case 'Mono':
        return GoogleFonts.robotoMonoTextTheme(base);
      case 'Sans':
        return GoogleFonts.manropeTextTheme(base);
      case 'Serif':
        return GoogleFonts.playfairDisplayTextTheme(base);
      default:
        return base; // system default
    }
  }

  // FIX ("home page font playlist mai kaam nahi kar raha" — the font
  // picker in Settings only ever changed `ThemeData.textTheme`, via
  // resolvedTextTheme() above, which is what `Theme.of(context).textTheme`
  // reads. But the vast majority of Text widgets across the app —
  // including every playlist/home card title — use a hand-written
  // `const TextStyle(...)` instead of pulling from Theme.of(context)
  // .textTheme, and a raw TextStyle with no explicit fontFamily does NOT
  // inherit one from textTheme; it only inherits from
  // `ThemeData.fontFamily` (the app-wide default family used to resolve
  // ANY TextStyle that leaves fontFamily null), which nothing was ever
  // setting. So changing the font in Settings visibly updated the few
  // widgets that do read Theme.textTheme directly, while every hardcoded
  // TextStyle screen (home_screen.dart alone has 37 of them) silently
  // stayed on the system default font forever.
  //
  // Fix: expose the resolved GoogleFonts family name/fallback here so
  // main.dart can also set them as ThemeData.fontFamily /
  // fontFamilyFallback (see the .copyWith call in main.dart). That makes
  // the chosen font the fallback for every TextStyle in the app that
  // doesn't explicitly override fontFamily itself — including all the
  // hardcoded playlist-card / home-screen TextStyles — with zero need to
  // touch each of those call sites individually.
  String? get resolvedFontFamily {
    switch (_fontStyle) {
      case 'Rounded':
        return GoogleFonts.nunito().fontFamily;
      case 'Mono':
        return GoogleFonts.robotoMono().fontFamily;
      case 'Sans':
        return GoogleFonts.manrope().fontFamily;
      case 'Serif':
        return GoogleFonts.playfairDisplay().fontFamily;
      default:
        return null; // system default — don't override ThemeData.fontFamily
    }
  }

  List<String>? get resolvedFontFamilyFallback {
    switch (_fontStyle) {
      case 'Rounded':
        return GoogleFonts.nunito().fontFamilyFallback;
      case 'Mono':
        return GoogleFonts.robotoMono().fontFamilyFallback;
      case 'Sans':
        return GoogleFonts.manrope().fontFamilyFallback;
      case 'Serif':
        return GoogleFonts.playfairDisplay().fontFamilyFallback;
      default:
        return null;
    }
  }
}
