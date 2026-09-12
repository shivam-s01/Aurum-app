// =============================================================================
// FILE: lib/config/region_catalog.dart
// PROJECT: Astra Music
// DESCRIPTION: Shared country/genre catalog + region-aware helpers, used by
//   BOTH the first-launch onboarding flow (onboarding_screen.dart) and the
//   Settings > Region & Music Preferences screen (settings_region_screen.dart)
//   so a user can change their country/genre/artist picks at any time after
//   onboarding, not just once on first launch. Extracted out of
//   onboarding_screen.dart into its own file specifically so both call sites
//   share one source of truth for country data, genre-priority-by-country,
//   and the artist search-seed builder — duplicating this data across two
//   files would have let them drift out of sync over time.
// =============================================================================

import 'dart:io' show Platform;
import 'dart:convert' show jsonDecode;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../services/api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Genre data
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingGenre {
  final String key;   // matches SessionGenre enum name where possible;
                       // international genres use new descriptive keys —
                       // RecommendationEngine's genre-weight map takes any
                       // string key, so these blend in safely alongside the
                       // original India-centric set.
  final String label;
  final IconData icon;
  // One or two short, genre-representative search terms used to scope the
  // live artist search for this genre (see _ArtistStep._loadArtists below).
  final String searchSeed;
  const OnboardingGenre(this.key, this.label, this.icon, this.searchSeed);
}

const List<OnboardingGenre> kOnboardingGenres = [
  OnboardingGenre('bollywood', 'Bollywood', Icons.movie_filter_rounded, 'bollywood'),
  OnboardingGenre('punjabi', 'Punjabi', Icons.celebration_rounded, 'punjabi'),
  OnboardingGenre('hiphop', 'Hip-Hop', Icons.graphic_eq_rounded, 'hip hop'),
  OnboardingGenre('english', 'English Pop', Icons.language_rounded, 'pop'),
  OnboardingGenre('lofi', 'Lo-Fi / Chill', Icons.nightlight_round, 'lofi chill'),
  OnboardingGenre('devotional', 'Devotional', Icons.self_improvement_rounded, 'devotional bhakti'),
  OnboardingGenre('bhojpuri', 'Bhojpuri', Icons.music_note_rounded, 'bhojpuri'),
  OnboardingGenre('rnb', 'R&B', Icons.mic_external_on_rounded, 'r&b'),
  OnboardingGenre('rock', 'Rock', Icons.electric_bolt_rounded, 'rock'),
  OnboardingGenre('country', 'Country', Icons.landscape_rounded, 'country music'),
  OnboardingGenre('jpop', 'J-Pop', Icons.flare_rounded, 'j-pop'),
  OnboardingGenre('jrnb', 'J-R&B', Icons.spa_rounded, 'japanese r&b'),
  OnboardingGenre('anime', 'Anime', Icons.animation_rounded, 'anime songs'),
  OnboardingGenre('kpop', 'K-Pop', Icons.star_rounded, 'k-pop'),
  OnboardingGenre('latin', 'Latin', Icons.local_fire_department_rounded, 'latin'),
  OnboardingGenre('afrobeats', 'Afrobeats', Icons.public_rounded, 'afrobeats'),
  OnboardingGenre('edm', 'EDM / Dance', Icons.equalizer_rounded, 'edm dance'),
  OnboardingGenre('indie', 'Indie', Icons.explore_rounded, 'indie'),
  OnboardingGenre('classical', 'Classical', Icons.piano_rounded, 'classical'),
  OnboardingGenre('other', 'Something Else', Icons.explore_rounded, 'popular'),
];

/// Country-code -> ordered list of genre keys (from kOnboardingGenres)
/// that are most locally relevant, first. Any genre key not present here
/// simply falls to the end in its original catalog order — so this map
/// only needs to cover the *priority* genres per region, not every genre.
///
/// Kept intentionally small and maintainable: a handful of major markets
/// plus one sensible default. Add more country codes here any time —
/// nothing else needs to change.
const Map<String, List<String>> kCountryGenrePriority = {
  'IN': ['bollywood', 'punjabi', 'english', 'hiphop', 'indie', 'devotional', 'bhojpuri', 'lofi'],
  'US': ['english', 'hiphop', 'rnb', 'rock', 'country', 'edm', 'latin', 'indie'],
  'GB': ['english', 'hiphop', 'edm', 'rock', 'indie', 'rnb'],
  'JP': ['jpop', 'rock', 'jrnb', 'anime', 'hiphop', 'indie'],
  'KR': ['kpop', 'hiphop', 'english', 'rnb', 'indie'],
  'PK': ['bollywood', 'english', 'hiphop', 'indie'],
  'BD': ['bollywood', 'english', 'devotional', 'indie'],
  'CA': ['english', 'hiphop', 'rnb', 'rock', 'country', 'edm'],
  'AU': ['english', 'hiphop', 'edm', 'rock', 'indie'],
  'BR': ['latin', 'hiphop', 'english', 'edm', 'rock'],
  'MX': ['latin', 'english', 'hiphop', 'edm'],
  'NG': ['afrobeats', 'hiphop', 'english', 'rnb'],
  'ZA': ['afrobeats', 'english', 'hiphop', 'edm'],
  'FR': ['english', 'hiphop', 'edm', 'rock', 'indie'],
  'DE': ['edm', 'english', 'hiphop', 'rock'],
  'AE': ['bollywood', 'english', 'hiphop', 'punjabi'],
  'SA': ['english', 'hiphop', 'edm'],
};

/// Default priority used when the selected/detected country has no
/// explicit entry above — mirrors the original catalog order.
const List<String> kDefaultGenrePriority = [
  'bollywood', 'punjabi', 'hiphop', 'english', 'lofi', 'devotional', 'bhojpuri', 'other',
];

/// Builds the live-search query fed into ApiService.searchArtists() for
/// one genre + the onboarding-selected country. This is the fix for
/// artist picks not actually matching the chosen country/genre: the old
/// version always used the same generic template ("<genre> <country>
/// artists"), which is a weak signal for a free-text search backend and
/// often let globally-popular-but-unrelated artists leak in. This adds
/// genre-native phrasing per major market (e.g. Bollywood -> "playback
/// singers", K-Pop -> "idol groups") so the query itself is much more
/// specific to what the user actually picked.
String buildArtistSearchSeed({
  required String genreSeed,
  String? countryName,
}) {
  // Genre-native descriptor overrides, keyed by genre seed text — only
  // added where a more specific regional phrase meaningfully narrows the
  // search versus the generic "<genre> artists" template.
  const nativePhrase = <String, String>{
    'bollywood': 'bollywood playback singers',
    'punjabi': 'punjabi singers',
    'bhojpuri': 'bhojpuri singers',
    'devotional bhakti': 'devotional bhajan singers',
    'j-pop': 'j-pop idols and bands',
    'japanese r&b': 'japanese r&b artists',
    'anime songs': 'anime theme song artists',
    'k-pop': 'k-pop idol groups',
    'afrobeats': 'afrobeats artists',
    'latin': 'latin music artists',
    'country music': 'country music singers',
  };

  final phrase = nativePhrase[genreSeed] ?? '$genreSeed artists';

  if (countryName == null) return phrase;

  // "top <phrase> from <country>" reads as a much stronger locality
  // signal to a text-search backend than bolting "<country> artists" on
  // the end, and avoids the country name being mis-parsed as part of an
  // artist/song title.
  return 'top $phrase from $countryName';
}

/// Returns [kOnboardingGenres] re-ordered so the country's priority
/// genres come first (in that priority order), followed by everything
/// else in its original catalog order. Pure, cheap, no I/O.
List<OnboardingGenre> genreOrderFor(String? countryCode) {
  final priority = kCountryGenrePriority[countryCode] ?? kDefaultGenrePriority;
  final byKey = {for (final g in kOnboardingGenres) g.key: g};
  final ordered = <OnboardingGenre>[];
  final used = <String>{};
  for (final key in priority) {
    final g = byKey[key];
    if (g != null && used.add(g.key)) ordered.add(g);
  }
  for (final g in kOnboardingGenres) {
    if (used.add(g.key)) ordered.add(g);
  }
  return ordered;
}

// ─────────────────────────────────────────────────────────────────────────────
// Country data — 195 countries, ISO 3166-1 alpha-2 code + name. Flag is
// computed at runtime from the code via Unicode regional indicator symbols
// (see Country.flag below) — no image assets or extra packages needed.
// ─────────────────────────────────────────────────────────────────────────────

class Country {
  final String code;
  final String name;
  const Country(this.code, this.name);

  String get flag =>
      String.fromCharCodes(code.codeUnits.map((c) => 0x1F1E6 + (c - 65)));
}

const List<Country> kCountries = [
  Country('AF', 'Afghanistan'),
  Country('AL', 'Albania'),
  Country('DZ', 'Algeria'),
  Country('AD', 'Andorra'),
  Country('AO', 'Angola'),
  Country('AG', 'Antigua and Barbuda'),
  Country('AR', 'Argentina'),
  Country('AM', 'Armenia'),
  Country('AU', 'Australia'),
  Country('AT', 'Austria'),
  Country('AZ', 'Azerbaijan'),
  Country('BS', 'Bahamas'),
  Country('BH', 'Bahrain'),
  Country('BD', 'Bangladesh'),
  Country('BB', 'Barbados'),
  Country('BY', 'Belarus'),
  Country('BE', 'Belgium'),
  Country('BZ', 'Belize'),
  Country('BJ', 'Benin'),
  Country('BT', 'Bhutan'),
  Country('BO', 'Bolivia'),
  Country('BA', 'Bosnia and Herzegovina'),
  Country('BW', 'Botswana'),
  Country('BR', 'Brazil'),
  Country('BN', 'Brunei'),
  Country('BG', 'Bulgaria'),
  Country('BF', 'Burkina Faso'),
  Country('BI', 'Burundi'),
  Country('CV', 'Cabo Verde'),
  Country('KH', 'Cambodia'),
  Country('CM', 'Cameroon'),
  Country('CA', 'Canada'),
  Country('CF', 'Central African Republic'),
  Country('TD', 'Chad'),
  Country('CL', 'Chile'),
  Country('CN', 'China'),
  Country('CO', 'Colombia'),
  Country('KM', 'Comoros'),
  Country('CG', 'Congo'),
  Country('CD', 'Congo (DRC)'),
  Country('CR', 'Costa Rica'),
  Country('CI', 'Cote d\'Ivoire'),
  Country('HR', 'Croatia'),
  Country('CU', 'Cuba'),
  Country('CY', 'Cyprus'),
  Country('CZ', 'Czechia'),
  Country('DK', 'Denmark'),
  Country('DJ', 'Djibouti'),
  Country('DM', 'Dominica'),
  Country('DO', 'Dominican Republic'),
  Country('EC', 'Ecuador'),
  Country('EG', 'Egypt'),
  Country('SV', 'El Salvador'),
  Country('GQ', 'Equatorial Guinea'),
  Country('ER', 'Eritrea'),
  Country('EE', 'Estonia'),
  Country('SZ', 'Eswatini'),
  Country('ET', 'Ethiopia'),
  Country('FJ', 'Fiji'),
  Country('FI', 'Finland'),
  Country('FR', 'France'),
  Country('GA', 'Gabon'),
  Country('GM', 'Gambia'),
  Country('GE', 'Georgia'),
  Country('DE', 'Germany'),
  Country('GH', 'Ghana'),
  Country('GR', 'Greece'),
  Country('GD', 'Grenada'),
  Country('GT', 'Guatemala'),
  Country('GN', 'Guinea'),
  Country('GW', 'Guinea-Bissau'),
  Country('GY', 'Guyana'),
  Country('HT', 'Haiti'),
  Country('HN', 'Honduras'),
  Country('HU', 'Hungary'),
  Country('IS', 'Iceland'),
  Country('IN', 'India'),
  Country('ID', 'Indonesia'),
  Country('IR', 'Iran'),
  Country('IQ', 'Iraq'),
  Country('IE', 'Ireland'),
  Country('IL', 'Israel'),
  Country('IT', 'Italy'),
  Country('JM', 'Jamaica'),
  Country('JP', 'Japan'),
  Country('JO', 'Jordan'),
  Country('KZ', 'Kazakhstan'),
  Country('KE', 'Kenya'),
  Country('KI', 'Kiribati'),
  Country('KP', 'North Korea'),
  Country('KR', 'South Korea'),
  Country('KW', 'Kuwait'),
  Country('KG', 'Kyrgyzstan'),
  Country('LA', 'Laos'),
  Country('LV', 'Latvia'),
  Country('LB', 'Lebanon'),
  Country('LS', 'Lesotho'),
  Country('LR', 'Liberia'),
  Country('LY', 'Libya'),
  Country('LI', 'Liechtenstein'),
  Country('LT', 'Lithuania'),
  Country('LU', 'Luxembourg'),
  Country('MG', 'Madagascar'),
  Country('MW', 'Malawi'),
  Country('MY', 'Malaysia'),
  Country('MV', 'Maldives'),
  Country('ML', 'Mali'),
  Country('MT', 'Malta'),
  Country('MH', 'Marshall Islands'),
  Country('MR', 'Mauritania'),
  Country('MU', 'Mauritius'),
  Country('MX', 'Mexico'),
  Country('FM', 'Micronesia'),
  Country('MD', 'Moldova'),
  Country('MC', 'Monaco'),
  Country('MN', 'Mongolia'),
  Country('ME', 'Montenegro'),
  Country('MA', 'Morocco'),
  Country('MZ', 'Mozambique'),
  Country('MM', 'Myanmar'),
  Country('NA', 'Namibia'),
  Country('NR', 'Nauru'),
  Country('NP', 'Nepal'),
  Country('NL', 'Netherlands'),
  Country('NZ', 'New Zealand'),
  Country('NI', 'Nicaragua'),
  Country('NE', 'Niger'),
  Country('NG', 'Nigeria'),
  Country('MK', 'North Macedonia'),
  Country('NO', 'Norway'),
  Country('OM', 'Oman'),
  Country('PK', 'Pakistan'),
  Country('PW', 'Palau'),
  Country('PS', 'Palestine'),
  Country('PA', 'Panama'),
  Country('PG', 'Papua New Guinea'),
  Country('PY', 'Paraguay'),
  Country('PE', 'Peru'),
  Country('PH', 'Philippines'),
  Country('PL', 'Poland'),
  Country('PT', 'Portugal'),
  Country('QA', 'Qatar'),
  Country('RO', 'Romania'),
  Country('RU', 'Russia'),
  Country('RW', 'Rwanda'),
  Country('KN', 'Saint Kitts and Nevis'),
  Country('LC', 'Saint Lucia'),
  Country('VC', 'Saint Vincent and the Grenadines'),
  Country('WS', 'Samoa'),
  Country('SM', 'San Marino'),
  Country('ST', 'Sao Tome and Principe'),
  Country('SA', 'Saudi Arabia'),
  Country('SN', 'Senegal'),
  Country('RS', 'Serbia'),
  Country('SC', 'Seychelles'),
  Country('SL', 'Sierra Leone'),
  Country('SG', 'Singapore'),
  Country('SK', 'Slovakia'),
  Country('SI', 'Slovenia'),
  Country('SB', 'Solomon Islands'),
  Country('SO', 'Somalia'),
  Country('ZA', 'South Africa'),
  Country('SS', 'South Sudan'),
  Country('ES', 'Spain'),
  Country('LK', 'Sri Lanka'),
  Country('SD', 'Sudan'),
  Country('SR', 'Suriname'),
  Country('SE', 'Sweden'),
  Country('CH', 'Switzerland'),
  Country('SY', 'Syria'),
  Country('TW', 'Taiwan'),
  Country('TJ', 'Tajikistan'),
  Country('TZ', 'Tanzania'),
  Country('TH', 'Thailand'),
  Country('TL', 'Timor-Leste'),
  Country('TG', 'Togo'),
  Country('TO', 'Tonga'),
  Country('TT', 'Trinidad and Tobago'),
  Country('TN', 'Tunisia'),
  Country('TR', 'Turkey'),
  Country('TM', 'Turkmenistan'),
  Country('TV', 'Tuvalu'),
  Country('UG', 'Uganda'),
  Country('UA', 'Ukraine'),
  Country('AE', 'United Arab Emirates'),
  Country('GB', 'United Kingdom'),
  Country('US', 'United States'),
  Country('UY', 'Uruguay'),
  Country('UZ', 'Uzbekistan'),
  Country('VU', 'Vanuatu'),
  Country('VA', 'Vatican City'),
  Country('VE', 'Venezuela'),
  Country('VN', 'Vietnam'),
  Country('YE', 'Yemen'),
  Country('ZM', 'Zambia'),
  Country('ZW', 'Zimbabwe'),
];

Country? countryByCode(String? code) {
  if (code == null) return null;
  for (final c in kCountries) {
    if (c.code == code) return c;
  }
  return null;
}

/// Detects the user's likely country from the device's system locale
/// (e.g. "en_IN" -> IN, "ja_JP" -> JP) — NOT GPS/network location, so
/// this is synchronous-fast (no permission prompt, no network round
/// trip). This is now used ONLY as a last-resort fallback (see
/// detectCountryReal below) because locale is frequently wrong: a lot
/// of devices report a generic "en_GB"/"en_US" locale regardless of
/// where the phone actually is (e.g. "English (UK)" chosen purely as a
/// language preference, or OEM firmware defaults), which is exactly the
/// "I'm in India but it shows UK" bug this file used to have when locale
/// was the ONLY signal.
Country? detectCountryFromLocale() {
  try {
    if (kIsWeb) return null;
    final raw = Platform.localeName; // e.g. "en_IN", "ja_JP", "en_US.UTF-8"
    final cleaned = raw.split('.').first; // strip encoding suffix if present
    final parts = cleaned.split(RegExp(r'[_-]'));
    if (parts.length < 2) return null;
    final region = parts[1].toUpperCase();
    return countryByCode(region);
  } catch (_) {
    return null;
  }
}

/// REAL country detection — the actual fix for the "I'm in India but it
/// shows UK" bug. Locale-only detection was the root cause: it reflects
/// the device's *language* setting, not where the SIM/network/user
/// actually is, so a phone set to "English (UK)" as a language would
/// misreport a country on the other side of the planet.
///
/// This resolves the real network-visible country the same way
/// Spotify/YouTube Music do it — via IP geolocation — with a short race
/// across a couple of free, no-key providers for reliability, and only
/// falls back to locale if every network attempt fails (e.g. no
/// internet yet during onboarding). Each provider is capped so a slow/
/// dead endpoint can never hang the UI — worst case this resolves to
/// locale (or null, showing the manual list) within ~3.2s.
Future<Country?> detectCountryReal() async {
  final client = ApiService.httpClient;

  Future<Country?> viaIpApiCo() async {
    final res = await client
        .get(Uri.parse('https://ipapi.co/country/'))
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return null;
    final code = res.body.trim().toUpperCase();
    if (code.length != 2) return null;
    return countryByCode(code);
  }

  Future<Country?> viaIpwhois() async {
    final res = await client
        .get(Uri.parse('https://ipwho.is/?fields=success,country_code'))
        .timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    if (json['success'] != true) return null;
    final code = (json['country_code'] as String?)?.toUpperCase();
    return countryByCode(code);
  }

  // Race both network sources concurrently and take a majority vote when
  // they agree, otherwise trust whichever one actually resolved — a
  // network-IP signal is already far more reliable than locale on its
  // own. NOTE: a raw-IP-based third source (e.g. Cloudflare's
  // 1.1.1.1/cdn-cgi/trace) was deliberately left out here — this app's
  // network_security_config.xml only whitelists traffic by *domain*, and
  // a bare IP literal can't be expressed as a <domain-config> entry, so
  // that call would be silently blocked exactly like the Worker/YouTube
  // domains were before those got added. Two domain-based providers
  // (both whitelisted below) keep this reliable without hitting that
  // trap again. This whole race is capped at 3.5s total.
  final attempts = <Future<Country?>>[
    viaIpApiCo().catchError((_) => null),
    viaIpwhois().catchError((_) => null),
  ];

  try {
    final results = await Future.wait(attempts)
        .timeout(const Duration(milliseconds: 3500), onTimeout: () => const []);
    final codes = results.whereType<Country>().map((c) => c.code).toList();
    if (codes.isEmpty) return detectCountryFromLocale();

    // Majority vote when both agree; otherwise just trust whichever one
    // answered since either is already a real network signal.
    final counts = <String, int>{};
    for (final c in codes) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final winner =
        counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return countryByCode(winner) ?? detectCountryFromLocale();
  } catch (_) {
    return detectCountryFromLocale();
  }
}
