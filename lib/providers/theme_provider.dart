import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AurumThemeMode { dark, light, amoled, system }

class ThemeProvider extends ChangeNotifier {
  static const _key = 'aurum_theme_mode';
  AurumThemeMode _mode = AurumThemeMode.dark;

  AurumThemeMode get mode => _mode;

  ThemeMode get themeMode {
    switch (_mode) {
      case AurumThemeMode.system:
        return ThemeMode.system;
      case AurumThemeMode.light:
        return ThemeMode.light;
      default:
        return ThemeMode.dark;
    }
  }

  bool get isAmoled => _mode == AurumThemeMode.amoled;

  ThemeProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final val = prefs.getString(_key);
    if (val != null) {
      _mode = AurumThemeMode.values.firstWhere(
        (e) => e.name == val,
        orElse: () => AurumThemeMode.dark,
      );
      notifyListeners();
    }
  }

  Future<void> setMode(AurumThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }
}
