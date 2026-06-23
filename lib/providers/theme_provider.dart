import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';

enum AurumThemeMode { dark, light, amoled, system }

class ThemeProvider extends ChangeNotifier {
  static const _key     = 'aurum_theme_mode';
  static const _fontKey = 'font_style';

  AurumThemeMode _mode      = AurumThemeMode.dark;
  String         _fontStyle = 'Default';

  AurumThemeMode get mode      => _mode;
  String         get fontStyle => _fontStyle;

  ThemeMode get themeMode {
    switch (_mode) {
      case AurumThemeMode.system: return ThemeMode.system;
      case AurumThemeMode.light:  return ThemeMode.light;
      default:                    return ThemeMode.dark;
    }
  }

  bool get isAmoled => _mode == AurumThemeMode.amoled;

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
    notifyListeners();
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
