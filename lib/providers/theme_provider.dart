import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/aurum_theme.dart';

enum AurumThemeMode { dark, light, amoled, system, dynamic }

class ThemeProvider extends ChangeNotifier {
  static const _key       = 'aurum_theme_mode';
  static const _fontKey   = 'font_style';
  static const _accentKey = 'accent_color';
  static const _btnColorKey = 'player_button_colors';
  static const _sliderStyleKey = 'player_slider_style';

  AurumThemeMode _mode      = AurumThemeMode.dark;
  String         _fontStyle = 'Default';
  Color          _accentColor = AurumTheme.gold;
  String         _playerButtonColorMode = 'Primary';
  String         _playerSliderStyle = 'Rounded';

  AurumThemeMode get mode      => _mode;
  String         get fontStyle => _fontStyle;

  /// Premium accent color override. Used by the player screen, player
  /// buttons, and sliders. Defaults to AurumTheme.gold so the rest of
  /// the app (which references AurumTheme.gold as a const) is unaffected.
  Color get accentColor => _accentColor;

  /// 'Primary' (default, white) | 'White' | 'Accent' — drives the color
  /// of the main play/pause button on the full player screen.
  String get playerButtonColorMode => _playerButtonColorMode;

  /// 'Slim' | 'Thick' | 'Rounded' (default) — seek bar track/thumb size.
  String get playerSliderStyle => _playerSliderStyle;

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
    if (identical(light, _dynamicLight) && identical(dark, _dynamicDark)) return;
    _dynamicLight = light;
    _dynamicDark = dark;
    if (_mode == AurumThemeMode.dynamic) notifyListeners();
  }

  ThemeMode get themeMode {
    switch (_mode) {
      case AurumThemeMode.system:  return ThemeMode.system;
      case AurumThemeMode.light:   return ThemeMode.light;
      case AurumThemeMode.dynamic: return ThemeMode.system;
      default:                     return ThemeMode.dark;
    }
  }

  bool get isAmoled => _mode == AurumThemeMode.amoled;
  bool get isDynamic => _mode == AurumThemeMode.dynamic;

  ThemeProvider() { _load(); }

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
      default:
        return base; // system default
    }
  }
}
