import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/languages.dart';

// The full language list (kSupportedLocales, kLocaleDisplayNames,
// kLocaleEnglishNames, kLocaleFlags) now lives in lib/config/languages.dart
// — the single place to edit when adding a new language. This re-export
// keeps every existing `import '.../locale_provider.dart'` (main.dart,
// settings_language_screen.dart, etc.) working unchanged: they still see
// these same names in scope, just sourced from one shared file instead of
// being duplicated here.
export '../config/languages.dart';

class LocaleProvider extends ChangeNotifier {
  static const _key = 'app_locale';

  // null = follow system locale (falls back to English if the system
  // locale isn't one Aurum ships translations for — see main.dart's
  // localeResolutionCallback).
  Locale? _locale;

  Locale? get locale => _locale;

  LocaleProvider() { _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_key);
    if (saved != null && kSupportedLocales.any((l) => l.languageCode == saved)) {
      _locale = Locale(saved);
      notifyListeners();
    }
  }

  Future<void> setLocale(Locale? locale) async {
    _locale = locale;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    if (locale == null) {
      await p.remove(_key);
    } else {
      await p.setString(_key, locale.languageCode);
    }
  }
}
