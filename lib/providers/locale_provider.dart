import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Languages Aurum's UI is available in. Keep this list in sync with the
/// .arb files under lib/l10n/ (app_<code>.arb) and l10n.yaml.
const List<Locale> kSupportedLocales = [
  Locale('en'), // English
  Locale('hi'), // Hindi
  Locale('ta'), // Tamil
  Locale('fr'), // French
  Locale('ja'), // Japanese
  Locale('ru'), // Russian
  Locale('es'), // Spanish
  Locale('ur'), // Urdu
  Locale('zh'), // Chinese (Simplified)
];

/// Human-readable names shown in the language picker, in each language's
/// own script (not translated into the currently-selected app language) —
/// this matches how most apps present a language list, so a Japanese
/// speaker can find "日本語" even if the app is currently showing Russian.
const Map<String, String> kLocaleDisplayNames = {
  'en': 'English',
  'hi': 'हिन्दी',
  'ta': 'தமிழ்',
  'fr': 'Français',
  'ja': '日本語',
  'ru': 'Русский',
  'es': 'Español',
  'ur': 'اردو',
  'zh': '中文',
};

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
