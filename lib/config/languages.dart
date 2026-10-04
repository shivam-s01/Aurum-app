// languages.dart
// Aurum Music — Single source of truth for every language the app can
// display its UI in.
//
// HOW THIS FILE WORKS WITH THE REST OF THE APP:
// Every screen (home, search, settings, player, everywhere) reads its
// strings through `AppLocalizations` (e.g. `l10n.navHome`) — never
// through this file directly. Screens never need to know how many
// languages exist or what they're called. That means adding a language
// here never requires touching home_screen.dart, search_screen.dart, or
// any other UI file — they already work in every language automatically.
//
// TO ADD A NEW LANGUAGE:
//   1. Add one `Locale('xx')` line to `kSupportedLocales` below.
//   2. Add its native-script name to `kLocaleDisplayNames`.
//   3. Add its English name to `kLocaleEnglishNames`.
//   4. Add its flag emoji to `kLocaleFlags`.
//   5. Commit and push. The CI workflow's auto-translate step
//      (.github/scripts/auto_translate.py) detects the new locale code,
//      auto-generates lib/l10n/app_xx.arb by machine-translating
//      app_en.arb, and the normal Flutter build picks it up from there.
//      You never hand-write or hand-edit an .arb file yourself.
//
// That's the entire workflow — one file, four short additions, no other
// file in the project needs to change.
import 'package:flutter/material.dart';

/// Every locale Aurum's UI can be displayed in. The auto-translate CI
/// step keys off this exact list to know which lib/l10n/app_<code>.arb
/// files must exist before the build runs.
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
  Locale('de'), // German
  Locale('it'), // Italian
  Locale('ko'), // Korean
  Locale('ar'), // Arabic
  Locale('tr'), // Turkish
  Locale('id'), // Indonesian
  Locale('vi'), // Vietnamese
  // HIDDEN (no app_bn.arb yet) — uncomment after adding the .arb file
  // Locale('bn'), // Bengali
  Locale('pt'), // Portuguese
  Locale('nl'), // Dutch
  Locale('pl'), // Polish
  Locale('th'), // Thai
  Locale('sv'), // Swedish
  Locale('el'), // Greek
  // HIDDEN (no app_he.arb yet) — uncomment after adding the .arb file
  // Locale('he'), // Hebrew
  Locale('uk'), // Ukrainian
  Locale('ro'), // Romanian
  // HIDDEN (no app_hu.arb yet) — uncomment after adding the .arb file
  // Locale('hu'), // Hungarian
  // HIDDEN (no app_cs.arb yet) — uncomment after adding the .arb file
  // Locale('cs'), // Czech
  // HIDDEN (no app_fi.arb yet) — uncomment after adding the .arb file
  // Locale('fi'), // Finnish
  // HIDDEN (no app_da.arb yet) — uncomment after adding the .arb file
  // Locale('da'), // Danish
  // HIDDEN (no app_no.arb yet) — uncomment after adding the .arb file
  // Locale('no'), // Norwegian
  // HIDDEN (no app_sk.arb yet) — uncomment after adding the .arb file
  // Locale('sk'), // Slovak
  // HIDDEN (no app_bg.arb yet) — uncomment after adding the .arb file
  // Locale('bg'), // Bulgarian
  // HIDDEN (no app_hr.arb yet) — uncomment after adding the .arb file
  // Locale('hr'), // Croatian
  // HIDDEN (no app_sr.arb yet) — uncomment after adding the .arb file
  // Locale('sr'), // Serbian
  // HIDDEN (no app_lt.arb yet) — uncomment after adding the .arb file
  // Locale('lt'), // Lithuanian
  // HIDDEN (no app_lv.arb yet) — uncomment after adding the .arb file
  // Locale('lv'), // Latvian
  // HIDDEN (no app_et.arb yet) — uncomment after adding the .arb file
  // Locale('et'), // Estonian
  // HIDDEN (no app_sl.arb yet) — uncomment after adding the .arb file
  // Locale('sl'), // Slovenian
  // HIDDEN (no app_ms.arb yet) — uncomment after adding the .arb file
  // Locale('ms'), // Malay
  // HIDDEN (no app_fil.arb yet) — uncomment after adding the .arb file
  // Locale('fil'), // Filipino
  // HIDDEN (no app_sw.arb yet) — uncomment after adding the .arb file
  // Locale('sw'), // Swahili
  // HIDDEN (no app_am.arb yet) — uncomment after adding the .arb file
  // Locale('am'), // Amharic
  Locale('fa'), // Persian
  Locale('pa'), // Punjabi
  // HIDDEN (no app_gu.arb yet) — uncomment after adding the .arb file
  // Locale('gu'), // Gujarati
  // HIDDEN (no app_mr.arb yet) — uncomment after adding the .arb file
  // Locale('mr'), // Marathi
  // HIDDEN (no app_kn.arb yet) — uncomment after adding the .arb file
  // Locale('kn'), // Kannada
  // HIDDEN (no app_ml.arb yet) — uncomment after adding the .arb file
  // Locale('ml'), // Malayalam
  // HIDDEN (no app_te.arb yet) — uncomment after adding the .arb file
  // Locale('te'), // Telugu
  // HIDDEN (no app_ne.arb yet) — uncomment after adding the .arb file
  // Locale('ne'), // Nepali
  // HIDDEN (no app_si.arb yet) — uncomment after adding the .arb file
  // Locale('si'), // Sinhala
  // HIDDEN (no app_my.arb yet) — uncomment after adding the .arb file
  // Locale('my'), // Burmese
  // HIDDEN (no app_km.arb yet) — uncomment after adding the .arb file
  // Locale('km'), // Khmer
  // HIDDEN (no app_az.arb yet) — uncomment after adding the .arb file
  // Locale('az'), // Azerbaijani
  // HIDDEN (no app_kk.arb yet) — uncomment after adding the .arb file
  // Locale('kk'), // Kazakh
  // HIDDEN (no app_uz.arb yet) — uncomment after adding the .arb file
  // Locale('uz'), // Uzbek
  // HIDDEN (no app_mn.arb yet) — uncomment after adding the .arb file
  // Locale('mn'), // Mongolian
  // HIDDEN (no app_is.arb yet) — uncomment after adding the .arb file
  // Locale('is'), // Icelandic
  // HIDDEN (no app_sq.arb yet) — uncomment after adding the .arb file
  // Locale('sq'), // Albanian
  // HIDDEN (no app_af.arb yet) — uncomment after adding the .arb file
  // Locale('af'), // Afrikaans
  // HIDDEN (no app_zu.arb yet) — uncomment after adding the .arb file
  // Locale('zu'), // Zulu
  // HIDDEN (no app_xh.arb yet) — uncomment after adding the .arb file
  // Locale('xh'), // Xhosa
  // HIDDEN (no app_ha.arb yet) — uncomment after adding the .arb file
  // Locale('ha'), // Hausa
  // HIDDEN (no app_yo.arb yet) — uncomment after adding the .arb file
  // Locale('yo'), // Yoruba
  // HIDDEN (no app_ig.arb yet) — uncomment after adding the .arb file
  // Locale('ig'), // Igbo
  // HIDDEN (no app_so.arb yet) — uncomment after adding the .arb file
  // Locale('so'), // Somali
];

/// Native-script names shown in the language picker (not translated into
/// the currently-selected app language) — matches how most apps present
/// a language list, so a Japanese speaker can find "日本語" even while
/// the app is currently showing Russian.
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
  'de': 'Deutsch',
  'it': 'Italiano',
  'ko': '한국어',
  'ar': 'العربية',
  'tr': 'Türkçe',
  'id': 'Bahasa Indonesia',
  'vi': 'Tiếng Việt',
  'bn': 'বাংলা',
  'pt': 'Português',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'th': 'ไทย',
  'sv': 'Svenska',
  'el': 'Ελληνικά',
  'he': 'עברית',
  'uk': 'Українська',
  'ro': 'Română',
  'hu': 'Magyar',
  'cs': 'Čeština',
  'fi': 'Suomi',
  'da': 'Dansk',
  'no': 'Norsk',
  'sk': 'Slovenčina',
  'bg': 'Български',
  'hr': 'Hrvatski',
  'sr': 'Српски',
  'lt': 'Lietuvių',
  'lv': 'Latviešu',
  'et': 'Eesti',
  'sl': 'Slovenščina',
  'ms': 'Bahasa Melayu',
  'fil': 'Filipino',
  'sw': 'Kiswahili',
  'am': 'አማርኛ',
  'fa': 'فارسی',
  'pa': 'ਪੰਜਾਬੀ',
  'gu': 'ગુજરાતી',
  'mr': 'मराठी',
  'kn': 'ಕನ್ನಡ',
  'ml': 'മലയാളം',
  'te': 'తెలుగు',
  'ne': 'नेपाली',
  'si': 'සිංහල',
  'my': 'မြန်မာ',
  'km': 'ខ្មែរ',
  'az': 'Azərbaycan',
  'kk': 'Қазақша',
  'uz': 'Oʻzbekcha',
  'mn': 'Монгол',
  'is': 'Íslenska',
  'sq': 'Shqip',
  'af': 'Afrikaans',
  'zu': 'isiZulu',
  'xh': 'isiXhosa',
  'ha': 'Hausa',
  'yo': 'Yorùbá',
  'ig': 'Igbo',
  'so': 'Soomaali',
};

/// English name shown as the secondary line under each native name in
/// the language picker (skipped for English itself, which has only one
/// line since native name == English name there).
const Map<String, String> kLocaleEnglishNames = {
  'hi': 'Hindi',
  'ta': 'Tamil',
  'fr': 'French',
  'ja': 'Japanese',
  'ru': 'Russian',
  'es': 'Spanish',
  'ur': 'Urdu',
  'zh': 'Chinese (Simplified)',
  'de': 'German',
  'it': 'Italian',
  'ko': 'Korean',
  'ar': 'Arabic',
  'tr': 'Turkish',
  'id': 'Indonesian',
  'vi': 'Vietnamese',
  'bn': 'Bengali',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'pl': 'Polish',
  'th': 'Thai',
  'sv': 'Swedish',
  'el': 'Greek',
  'he': 'Hebrew',
  'uk': 'Ukrainian',
  'ro': 'Romanian',
  'hu': 'Hungarian',
  'cs': 'Czech',
  'fi': 'Finnish',
  'da': 'Danish',
  'no': 'Norwegian',
  'sk': 'Slovak',
  'bg': 'Bulgarian',
  'hr': 'Croatian',
  'sr': 'Serbian',
  'lt': 'Lithuanian',
  'lv': 'Latvian',
  'et': 'Estonian',
  'sl': 'Slovenian',
  'ms': 'Malay',
  'fil': 'Filipino',
  'sw': 'Swahili',
  'am': 'Amharic',
  'fa': 'Persian',
  'pa': 'Punjabi',
  'gu': 'Gujarati',
  'mr': 'Marathi',
  'kn': 'Kannada',
  'ml': 'Malayalam',
  'te': 'Telugu',
  'ne': 'Nepali',
  'si': 'Sinhala',
  'my': 'Burmese',
  'km': 'Khmer',
  'az': 'Azerbaijani',
  'kk': 'Kazakh',
  'uz': 'Uzbek',
  'mn': 'Mongolian',
  'is': 'Icelandic',
  'sq': 'Albanian',
  'af': 'Afrikaans',
  'zu': 'Zulu',
  'xh': 'Xhosa',
  'ha': 'Hausa',
  'yo': 'Yoruba',
  'ig': 'Igbo',
  'so': 'Somali',
};

/// Real country flag emoji representing each language, keyed by language
/// code. Flag emoji are just two Regional Indicator Symbol code points,
/// so these render as the actual flag glyph on-device (Android's Noto
/// Color Emoji / Apple's Emoji font) — no bundled flag image assets
/// needed, no extra package weight, crisp at any text scale/density.
/// Each language is mapped to its principal/origin country's flag.
const Map<String, String> kLocaleFlags = {
  'en': '🇬🇧',
  'hi': '🇮🇳',
  'ta': '🇮🇳',
  'fr': '🇫🇷',
  'ja': '🇯🇵',
  'ru': '🇷🇺',
  'es': '🇪🇸',
  'ur': '🇵🇰',
  'zh': '🇨🇳',
  'de': '🇩🇪',
  'it': '🇮🇹',
  'ko': '🇰🇷',
  'ar': '🇸🇦',
  'tr': '🇹🇷',
  'id': '🇮🇩',
  'vi': '🇻🇳',
  'bn': '🇧🇩',
  'pt': '🇵🇹',
  'nl': '🇳🇱',
  'pl': '🇵🇱',
  'th': '🇹🇭',
  'sv': '🇸🇪',
  'el': '🇬🇷',
  'he': '🇮🇱',
  'uk': '🇺🇦',
  'ro': '🇷🇴',
  'hu': '🇭🇺',
  'cs': '🇨🇿',
  'fi': '🇫🇮',
  'da': '🇩🇰',
  'no': '🇳🇴',
  'sk': '🇸🇰',
  'bg': '🇧🇬',
  'hr': '🇭🇷',
  'sr': '🇷🇸',
  'lt': '🇱🇹',
  'lv': '🇱🇻',
  'et': '🇪🇪',
  'sl': '🇸🇮',
  'ms': '🇲🇾',
  'fil': '🇵🇭',
  'sw': '🇹🇿',
  'am': '🇪🇹',
  'fa': '🇮🇷',
  'pa': '🇮🇳',
  'gu': '🇮🇳',
  'mr': '🇮🇳',
  'kn': '🇮🇳',
  'ml': '🇮🇳',
  'te': '🇮🇳',
  'ne': '🇳🇵',
  'si': '🇱🇰',
  'my': '🇲🇲',
  'km': '🇰🇭',
  'az': '🇦🇿',
  'kk': '🇰🇿',
  'uz': '🇺🇿',
  'mn': '🇲🇳',
  'is': '🇮🇸',
  'sq': '🇦🇱',
  'af': '🇿🇦',
  'zu': '🇿🇦',
  'xh': '🇿🇦',
  'ha': '🇳🇬',
  'yo': '🇳🇬',
  'ig': '🇳🇬',
  'so': '🇸🇴',
};
