// =============================================================================
// FILE: lib/screens/onboarding_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: First-launch-only onboarding — three quick picker steps shown
//   exactly once before the user ever sees Home, so their very first feed
//   already leans toward music they actually like instead of a cold,
//   generic default. Modeled after Spotify/Apple Music's own "pick a few
//   things you like" first-run flow: a few taps, then straight into the
//   app — no forced sign-in, no long form, fully skippable at every step.
//
//   STEP 1 — Country: all 195 countries, searchable, each with its flag
//     rendered from Unicode regional indicator symbols (no image assets
//     or extra packages needed). Auto-detected instantly from the
//     device's system locale (Platform.localeName) — no network call, no
//     permission prompt, resolves in the same frame the screen builds —
//     with a "not you? tap to change" affordance that opens the same
//     manual searchable list. Country now DRIVES the two steps after it:
//     it reorders genre priority and scopes the artist search.
//   STEP 2 — Genres: a small fixed local list with a live search field
//     (never a network call, so this step always renders instantly
//     regardless of connection state) — but re-ordered per selected
//     country so the most locally-relevant genres surface first (e.g.
//     India -> Bollywood/Punjabi first, US -> Pop/Hip-Hop first, Japan ->
//     J-Pop/Anime first). See _genreOrderFor() below.
//   STEP 3 — Artists: REAL, live-searched artists via
//     ApiService.searchArtists() — one query per selected genre, scoped
//     with the selected country's name so results skew toward locally
//     relevant artists for that genre instead of a hardcoded pool. This
//     is a genuine live network lookup (same source Search already uses),
//     not a static list, so it stays accurate as the catalog changes. If
//     the fetch fails or is slow, a timeout falls through to a Skip-only
//     version of this step rather than blocking first launch.
//
// WIRING:
//   - Shown by _OnboardingGate in main.dart, which checks the
//     'onboarding_complete' SharedPreferences flag once at launch and
//     shows this screen instead of MainShell until it's set.
//   - Genre/artist selections are pushed into RecommendationEngine via
//     applyOnboardingGenrePreferences()/applyOnboardingArtistPreferences().
//   - Country is saved directly as 'onboarding_country_code' /
//     'onboarding_country_name' SharedPreferences strings.
// =============================================================================

import 'dart:io' show Platform;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/api_service.dart';
import '../services/recommendation_engine.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Genre data
// ─────────────────────────────────────────────────────────────────────────────

class _OnboardingGenre {
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
  const _OnboardingGenre(this.key, this.label, this.icon, this.searchSeed);
}

const List<_OnboardingGenre> _kOnboardingGenres = [
  _OnboardingGenre('bollywood', 'Bollywood', Icons.movie_filter_rounded, 'bollywood'),
  _OnboardingGenre('punjabi', 'Punjabi', Icons.celebration_rounded, 'punjabi'),
  _OnboardingGenre('hiphop', 'Hip-Hop', Icons.graphic_eq_rounded, 'hip hop'),
  _OnboardingGenre('english', 'English Pop', Icons.language_rounded, 'pop'),
  _OnboardingGenre('lofi', 'Lo-Fi / Chill', Icons.nightlight_round, 'lofi chill'),
  _OnboardingGenre('devotional', 'Devotional', Icons.self_improvement_rounded, 'devotional bhakti'),
  _OnboardingGenre('bhojpuri', 'Bhojpuri', Icons.music_note_rounded, 'bhojpuri'),
  _OnboardingGenre('rnb', 'R&B', Icons.mic_external_on_rounded, 'r&b'),
  _OnboardingGenre('rock', 'Rock', Icons.electric_bolt_rounded, 'rock'),
  _OnboardingGenre('country', 'Country', Icons.landscape_rounded, 'country music'),
  _OnboardingGenre('jpop', 'J-Pop', Icons.flare_rounded, 'j-pop'),
  _OnboardingGenre('jrnb', 'J-R&B', Icons.spa_rounded, 'japanese r&b'),
  _OnboardingGenre('anime', 'Anime', Icons.animation_rounded, 'anime songs'),
  _OnboardingGenre('kpop', 'K-Pop', Icons.star_rounded, 'k-pop'),
  _OnboardingGenre('latin', 'Latin', Icons.local_fire_department_rounded, 'latin'),
  _OnboardingGenre('afrobeats', 'Afrobeats', Icons.public_rounded, 'afrobeats'),
  _OnboardingGenre('edm', 'EDM / Dance', Icons.equalizer_rounded, 'edm dance'),
  _OnboardingGenre('indie', 'Indie', Icons.explore_rounded, 'indie'),
  _OnboardingGenre('classical', 'Classical', Icons.piano_rounded, 'classical'),
  _OnboardingGenre('other', 'Something Else', Icons.explore_rounded, 'popular'),
];

/// Country-code -> ordered list of genre keys (from _kOnboardingGenres)
/// that are most locally relevant, first. Any genre key not present here
/// simply falls to the end in its original catalog order — so this map
/// only needs to cover the *priority* genres per region, not every genre.
///
/// Kept intentionally small and maintainable: a handful of major markets
/// plus one sensible default. Add more country codes here any time —
/// nothing else needs to change.
const Map<String, List<String>> _kCountryGenrePriority = {
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
const List<String> _kDefaultGenrePriority = [
  'bollywood', 'punjabi', 'hiphop', 'english', 'lofi', 'devotional', 'bhojpuri', 'other',
];

/// Returns [_kOnboardingGenres] re-ordered so the country's priority
/// genres come first (in that priority order), followed by everything
/// else in its original catalog order. Pure, cheap, no I/O.
List<_OnboardingGenre> _genreOrderFor(String? countryCode) {
  final priority = _kCountryGenrePriority[countryCode] ?? _kDefaultGenrePriority;
  final byKey = {for (final g in _kOnboardingGenres) g.key: g};
  final ordered = <_OnboardingGenre>[];
  final used = <String>{};
  for (final key in priority) {
    final g = byKey[key];
    if (g != null && used.add(g.key)) ordered.add(g);
  }
  for (final g in _kOnboardingGenres) {
    if (used.add(g.key)) ordered.add(g);
  }
  return ordered;
}

// ─────────────────────────────────────────────────────────────────────────────
// Country data — 195 countries, ISO 3166-1 alpha-2 code + name. Flag is
// computed at runtime from the code via Unicode regional indicator symbols
// (see _Country.flag below) — no image assets or extra packages needed.
// ─────────────────────────────────────────────────────────────────────────────

class _Country {
  final String code;
  final String name;
  const _Country(this.code, this.name);

  String get flag =>
      String.fromCharCodes(code.codeUnits.map((c) => 0x1F1E6 + (c - 65)));
}

const List<_Country> _kCountries = [
  _Country('AF', 'Afghanistan'),
  _Country('AL', 'Albania'),
  _Country('DZ', 'Algeria'),
  _Country('AD', 'Andorra'),
  _Country('AO', 'Angola'),
  _Country('AG', 'Antigua and Barbuda'),
  _Country('AR', 'Argentina'),
  _Country('AM', 'Armenia'),
  _Country('AU', 'Australia'),
  _Country('AT', 'Austria'),
  _Country('AZ', 'Azerbaijan'),
  _Country('BS', 'Bahamas'),
  _Country('BH', 'Bahrain'),
  _Country('BD', 'Bangladesh'),
  _Country('BB', 'Barbados'),
  _Country('BY', 'Belarus'),
  _Country('BE', 'Belgium'),
  _Country('BZ', 'Belize'),
  _Country('BJ', 'Benin'),
  _Country('BT', 'Bhutan'),
  _Country('BO', 'Bolivia'),
  _Country('BA', 'Bosnia and Herzegovina'),
  _Country('BW', 'Botswana'),
  _Country('BR', 'Brazil'),
  _Country('BN', 'Brunei'),
  _Country('BG', 'Bulgaria'),
  _Country('BF', 'Burkina Faso'),
  _Country('BI', 'Burundi'),
  _Country('CV', 'Cabo Verde'),
  _Country('KH', 'Cambodia'),
  _Country('CM', 'Cameroon'),
  _Country('CA', 'Canada'),
  _Country('CF', 'Central African Republic'),
  _Country('TD', 'Chad'),
  _Country('CL', 'Chile'),
  _Country('CN', 'China'),
  _Country('CO', 'Colombia'),
  _Country('KM', 'Comoros'),
  _Country('CG', 'Congo'),
  _Country('CD', 'Congo (DRC)'),
  _Country('CR', 'Costa Rica'),
  _Country('CI', 'Cote d\'Ivoire'),
  _Country('HR', 'Croatia'),
  _Country('CU', 'Cuba'),
  _Country('CY', 'Cyprus'),
  _Country('CZ', 'Czechia'),
  _Country('DK', 'Denmark'),
  _Country('DJ', 'Djibouti'),
  _Country('DM', 'Dominica'),
  _Country('DO', 'Dominican Republic'),
  _Country('EC', 'Ecuador'),
  _Country('EG', 'Egypt'),
  _Country('SV', 'El Salvador'),
  _Country('GQ', 'Equatorial Guinea'),
  _Country('ER', 'Eritrea'),
  _Country('EE', 'Estonia'),
  _Country('SZ', 'Eswatini'),
  _Country('ET', 'Ethiopia'),
  _Country('FJ', 'Fiji'),
  _Country('FI', 'Finland'),
  _Country('FR', 'France'),
  _Country('GA', 'Gabon'),
  _Country('GM', 'Gambia'),
  _Country('GE', 'Georgia'),
  _Country('DE', 'Germany'),
  _Country('GH', 'Ghana'),
  _Country('GR', 'Greece'),
  _Country('GD', 'Grenada'),
  _Country('GT', 'Guatemala'),
  _Country('GN', 'Guinea'),
  _Country('GW', 'Guinea-Bissau'),
  _Country('GY', 'Guyana'),
  _Country('HT', 'Haiti'),
  _Country('HN', 'Honduras'),
  _Country('HU', 'Hungary'),
  _Country('IS', 'Iceland'),
  _Country('IN', 'India'),
  _Country('ID', 'Indonesia'),
  _Country('IR', 'Iran'),
  _Country('IQ', 'Iraq'),
  _Country('IE', 'Ireland'),
  _Country('IL', 'Israel'),
  _Country('IT', 'Italy'),
  _Country('JM', 'Jamaica'),
  _Country('JP', 'Japan'),
  _Country('JO', 'Jordan'),
  _Country('KZ', 'Kazakhstan'),
  _Country('KE', 'Kenya'),
  _Country('KI', 'Kiribati'),
  _Country('KP', 'North Korea'),
  _Country('KR', 'South Korea'),
  _Country('KW', 'Kuwait'),
  _Country('KG', 'Kyrgyzstan'),
  _Country('LA', 'Laos'),
  _Country('LV', 'Latvia'),
  _Country('LB', 'Lebanon'),
  _Country('LS', 'Lesotho'),
  _Country('LR', 'Liberia'),
  _Country('LY', 'Libya'),
  _Country('LI', 'Liechtenstein'),
  _Country('LT', 'Lithuania'),
  _Country('LU', 'Luxembourg'),
  _Country('MG', 'Madagascar'),
  _Country('MW', 'Malawi'),
  _Country('MY', 'Malaysia'),
  _Country('MV', 'Maldives'),
  _Country('ML', 'Mali'),
  _Country('MT', 'Malta'),
  _Country('MH', 'Marshall Islands'),
  _Country('MR', 'Mauritania'),
  _Country('MU', 'Mauritius'),
  _Country('MX', 'Mexico'),
  _Country('FM', 'Micronesia'),
  _Country('MD', 'Moldova'),
  _Country('MC', 'Monaco'),
  _Country('MN', 'Mongolia'),
  _Country('ME', 'Montenegro'),
  _Country('MA', 'Morocco'),
  _Country('MZ', 'Mozambique'),
  _Country('MM', 'Myanmar'),
  _Country('NA', 'Namibia'),
  _Country('NR', 'Nauru'),
  _Country('NP', 'Nepal'),
  _Country('NL', 'Netherlands'),
  _Country('NZ', 'New Zealand'),
  _Country('NI', 'Nicaragua'),
  _Country('NE', 'Niger'),
  _Country('NG', 'Nigeria'),
  _Country('MK', 'North Macedonia'),
  _Country('NO', 'Norway'),
  _Country('OM', 'Oman'),
  _Country('PK', 'Pakistan'),
  _Country('PW', 'Palau'),
  _Country('PS', 'Palestine'),
  _Country('PA', 'Panama'),
  _Country('PG', 'Papua New Guinea'),
  _Country('PY', 'Paraguay'),
  _Country('PE', 'Peru'),
  _Country('PH', 'Philippines'),
  _Country('PL', 'Poland'),
  _Country('PT', 'Portugal'),
  _Country('QA', 'Qatar'),
  _Country('RO', 'Romania'),
  _Country('RU', 'Russia'),
  _Country('RW', 'Rwanda'),
  _Country('KN', 'Saint Kitts and Nevis'),
  _Country('LC', 'Saint Lucia'),
  _Country('VC', 'Saint Vincent and the Grenadines'),
  _Country('WS', 'Samoa'),
  _Country('SM', 'San Marino'),
  _Country('ST', 'Sao Tome and Principe'),
  _Country('SA', 'Saudi Arabia'),
  _Country('SN', 'Senegal'),
  _Country('RS', 'Serbia'),
  _Country('SC', 'Seychelles'),
  _Country('SL', 'Sierra Leone'),
  _Country('SG', 'Singapore'),
  _Country('SK', 'Slovakia'),
  _Country('SI', 'Slovenia'),
  _Country('SB', 'Solomon Islands'),
  _Country('SO', 'Somalia'),
  _Country('ZA', 'South Africa'),
  _Country('SS', 'South Sudan'),
  _Country('ES', 'Spain'),
  _Country('LK', 'Sri Lanka'),
  _Country('SD', 'Sudan'),
  _Country('SR', 'Suriname'),
  _Country('SE', 'Sweden'),
  _Country('CH', 'Switzerland'),
  _Country('SY', 'Syria'),
  _Country('TW', 'Taiwan'),
  _Country('TJ', 'Tajikistan'),
  _Country('TZ', 'Tanzania'),
  _Country('TH', 'Thailand'),
  _Country('TL', 'Timor-Leste'),
  _Country('TG', 'Togo'),
  _Country('TO', 'Tonga'),
  _Country('TT', 'Trinidad and Tobago'),
  _Country('TN', 'Tunisia'),
  _Country('TR', 'Turkey'),
  _Country('TM', 'Turkmenistan'),
  _Country('TV', 'Tuvalu'),
  _Country('UG', 'Uganda'),
  _Country('UA', 'Ukraine'),
  _Country('AE', 'United Arab Emirates'),
  _Country('GB', 'United Kingdom'),
  _Country('US', 'United States'),
  _Country('UY', 'Uruguay'),
  _Country('UZ', 'Uzbekistan'),
  _Country('VU', 'Vanuatu'),
  _Country('VA', 'Vatican City'),
  _Country('VE', 'Venezuela'),
  _Country('VN', 'Vietnam'),
  _Country('YE', 'Yemen'),
  _Country('ZM', 'Zambia'),
  _Country('ZW', 'Zimbabwe'),
];

_Country? _countryByCode(String? code) {
  if (code == null) return null;
  for (final c in _kCountries) {
    if (c.code == code) return c;
  }
  return null;
}

/// Detects the user's likely country instantly from the device's system
/// locale (e.g. "en_IN" -> IN, "ja_JP" -> JP) — NOT GPS/network location,
/// so this is synchronous-fast (no permission prompt, no network round
/// trip, resolves in the same frame the screen builds). This is a
/// best-effort hint only: the user can always override it from the same
/// searchable country list, since locale doesn't always match where
/// someone actually is.
_Country? _detectCountryFromLocale() {
  try {
    if (kIsWeb) return null;
    final raw = Platform.localeName; // e.g. "en_IN", "ja_JP", "en_US.UTF-8"
    final cleaned = raw.split('.').first; // strip encoding suffix if present
    final parts = cleaned.split(RegExp(r'[_-]'));
    if (parts.length < 2) return null;
    final region = parts[1].toUpperCase();
    return _countryByCode(region);
  } catch (_) {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Root screen — steps through Country -> Genres -> Artists
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0; // 0 = country, 1 = genres, 2 = artists
  _Country? _selectedCountry;
  final Set<String> _selectedGenres = {};
  final Set<String> _selectedArtists = {}; // artist names

  bool _detectedAutomatically = false;

  @override
  void initState() {
    super.initState();
    // Instant, synchronous, no I/O — safe to run right in initState so
    // the Country step already shows a detected pick on first frame.
    final detected = _detectCountryFromLocale();
    if (detected != null) {
      _selectedCountry = detected;
      _detectedAutomatically = true;
    }
  }

  void _goToStep(int step) {
    AurumHaptics.medium();
    setState(() => _step = step);
  }

  Future<void> _finish() async {
    try {
      if (_selectedGenres.isNotEmpty) {
        await RecommendationEngine.applyOnboardingGenrePreferences(
          _selectedGenres.toList(),
        );
      }
      if (_selectedArtists.isNotEmpty) {
        await RecommendationEngine.applyOnboardingArtistPreferences(
          _selectedArtists.toList(),
        );
      }
    } catch (_) {
      // Never block first launch on a preference-save failure — worst
      // case the user just gets a neutral, non-personalized feed.
    }

    try {
      final p = await SharedPreferences.getInstance();
      if (_selectedCountry != null) {
        await p.setString('onboarding_country_code', _selectedCountry!.code);
        await p.setString('onboarding_country_name', _selectedCountry!.name);
      }
      await p.setBool('onboarding_complete', true);
    } catch (_) {}

    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: switch (_step) {
            0 => _CountryStep(
                key: const ValueKey('country'),
                selected: _selectedCountry,
                autoDetected: _detectedAutomatically && _selectedCountry != null,
                onSelect: (c) => setState(() {
                  _selectedCountry = c;
                  _detectedAutomatically = false;
                }),
                onNext: () => _goToStep(1),
              ),
            1 => _GenreStep(
                key: const ValueKey('genres'),
                country: _selectedCountry,
                selected: _selectedGenres,
                onToggle: (key) => setState(() {
                  if (!_selectedGenres.remove(key)) _selectedGenres.add(key);
                }),
                onBack: () => _goToStep(0),
                onNext: () => _goToStep(2),
              ),
            _ => _ArtistStep(
                key: const ValueKey('artists'),
                country: _selectedCountry,
                genres: _selectedGenres,
                selected: _selectedArtists,
                onToggle: (name) => setState(() {
                  if (!_selectedArtists.remove(name)) _selectedArtists.add(name);
                }),
                onBack: () => _goToStep(1),
                onFinish: _finish,
              ),
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 1 — Country picker (auto-detected + manual, with search)
// ─────────────────────────────────────────────────────────────────────────────
class _CountryStep extends StatefulWidget {
  final _Country? selected;
  final bool autoDetected;
  final ValueChanged<_Country> onSelect;
  final VoidCallback onNext;

  const _CountryStep({
    super.key,
    required this.selected,
    required this.autoDetected,
    required this.onSelect,
    required this.onNext,
  });

  @override
  State<_CountryStep> createState() => _CountryStepState();
}

class _CountryStepState extends State<_CountryStep> {
  String _query = '';
  bool _showManualList = false;

  @override
  void didUpdateWidget(covariant _CountryStep oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Once the user has picked manually, keep the list open.
    if (!widget.autoDetected) _showManualList = true;
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final filtered = _query.isEmpty
        ? _kCountries
        : _kCountries
            .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    final showDetectedBanner = widget.autoDetected && widget.selected != null && !_showManualList;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _StepDots(activeIndex: 0, total: 3),
          const SizedBox(height: 20),
          Text(
            'Where are you\nlistening from?',
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.5,
              color: AurumTheme.textPrimaryOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Helps us pick the right genres, charts and artists for you.',
            style: TextStyle(
              fontSize: 14,
              color: AurumTheme.textMutedOf(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          if (showDetectedBanner) ...[
            _DetectedCountryCard(
              country: widget.selected!,
              accent: accent,
              onChangeTap: () => setState(() => _showManualList = true),
            ),
            const Spacer(),
          ] else ...[
            _SearchField(
              hint: 'Search countries',
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No countries match "$_query"',
                        style: TextStyle(color: AurumTheme.textMutedOf(context)),
                      ),
                    )
                  : ListView.separated(
                      physics: const BouncingScrollPhysics(),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.5,
                        color: AurumTheme.dividerOf(context),
                      ),
                      itemBuilder: (context, i) {
                        final country = filtered[i];
                        final isSelected = widget.selected?.code == country.code;
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              AurumHaptics.selection();
                              widget.onSelect(country);
                            },
                            splashFactory: NoSplash.splashFactory,
                            highlightColor: accent.withValues(alpha: 0.06),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 12),
                              child: Row(
                                children: [
                                  Text(country.flag,
                                      style: const TextStyle(fontSize: 24)),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      country.name,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: isSelected
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? accent
                                            : AurumTheme.textPrimaryOf(context),
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(Icons.check_circle_rounded,
                                        color: accent, size: 20),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: widget.onNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                widget.selected == null ? 'Skip for now' : 'Continue',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Lightweight, top-grade entrance animation for the auto-detected country
// card — pure Flutter AnimationControllers only (no new packages, no
// heavy Lottie/Rive assets), so this stays instant and cheap on any
// device while still feeling deliberate and polished:
//   1. Card: fades + slides up + scales in on a slight overshoot curve.
//   2. A soft accent-colored glow ring pulses outward once behind the
//      flag right after the card lands, like a locate-me "ping".
//   3. The flag itself pops in with a short elastic bounce, staggered
//      slightly after the card so the eye has something to follow.
//   4. The "DETECTED AUTOMATICALLY" label and country name fade/slide in
//      last, in a quick stagger, finishing the whole sequence in ~650ms.
class _DetectedCountryCard extends StatefulWidget {
  final _Country country;
  final Color accent;
  final VoidCallback onChangeTap;

  const _DetectedCountryCard({
    required this.country,
    required this.accent,
    required this.onChangeTap,
  });

  @override
  State<_DetectedCountryCard> createState() => _DetectedCountryCardState();
}

class _DetectedCountryCardState extends State<_DetectedCountryCard>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;
  late final AnimationController _ping;

  late final Animation<double> _cardFade;
  late final Animation<double> _cardSlide;
  late final Animation<double> _cardScale;
  late final Animation<double> _flagScale;
  late final Animation<double> _labelFade;
  late final Animation<double> _labelSlide;
  late final Animation<double> _nameFade;
  late final Animation<double> _nameSlide;

  @override
  void initState() {
    super.initState();

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );

    // Card container: quick fade + upward slide + gentle overshoot scale
    // (easeOutBack gives that "settles with a tiny bounce" premium feel
    // without needing a physics package).
    _cardFade = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    _cardSlide = Tween<double>(begin: 18, end: 0).animate(
      CurvedAnimation(
        parent: _entrance,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
      ),
    );
    _cardScale = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(
        parent: _entrance,
        curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
      ),
    );

    // Flag: staggered slightly after the card, elastic pop.
    _flagScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entrance,
        curve: const Interval(0.25, 0.85, curve: Curves.elasticOut),
      ),
    );

    // Label + name: last in the stagger, quick fade/slide.
    _labelFade = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.35, 0.7, curve: Curves.easeOut),
    );
    _labelSlide = Tween<double>(begin: -8, end: 0).animate(
      CurvedAnimation(
        parent: _entrance,
        curve: const Interval(0.35, 0.7, curve: Curves.easeOutCubic),
      ),
    );
    _nameFade = CurvedAnimation(
      parent: _entrance,
      curve: const Interval(0.45, 0.85, curve: Curves.easeOut),
    );
    _nameSlide = Tween<double>(begin: 10, end: 0).animate(
      CurvedAnimation(
        parent: _entrance,
        curve: const Interval(0.45, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    // A single soft "locate-me" ping ring, fired once right after the
    // card mostly settles — cheap (one Container + BoxShadow-less circle
    // painted via a border, no image/shader work) and never repeats, so
    // it reads as a one-time confirmation rather than a distracting loop.
    _ping = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _entrance.forward();
    Future.delayed(const Duration(milliseconds: 260), () {
      if (mounted) _ping.forward();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, child) {
        return Opacity(
          opacity: _cardFade.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, _cardSlide.value),
            child: Transform.scale(
              scale: _cardScale.value,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: widget.accent.withValues(alpha: 0.4), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedBuilder(
              animation: _entrance,
              builder: (context, _) => Opacity(
                opacity: _labelFade.value.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(_labelSlide.value, 0),
                  child: Row(
                    children: [
                      Icon(Icons.my_location_rounded, color: widget.accent, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'DETECTED AUTOMATICALLY',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: widget.accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                // Flag + one-shot "ping" ring behind it.
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _ping,
                        builder: (context, _) {
                          final t = _ping.value;
                          if (t == 0.0 || t == 1.0) return const SizedBox.shrink();
                          return Container(
                            width: 48 * (0.6 + t * 0.8),
                            height: 48 * (0.6 + t * 0.8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: widget.accent
                                    .withValues(alpha: (1.0 - t) * 0.5),
                                width: 1.4,
                              ),
                            ),
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: _entrance,
                        builder: (context, _) => Transform.scale(
                          scale: _flagScale.value,
                          child: Text(widget.country.flag,
                              style: const TextStyle(fontSize: 36)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _entrance,
                    builder: (context, _) => Opacity(
                      opacity: _nameFade.value.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(_nameSlide.value, 0),
                        child: Text(
                          widget.country.name,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: AurumTheme.textPrimaryOf(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: widget.onChangeTap,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AurumTheme.textPrimaryOf(context),
                  side: BorderSide(color: AurumTheme.dividerOf(context)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Not you? Choose manually',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 2 — Genre picker (with search), re-ordered by selected country
// ─────────────────────────────────────────────────────────────────────────────
class _GenreStep extends StatefulWidget {
  final _Country? country;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const _GenreStep({
    super.key,
    required this.country,
    required this.selected,
    required this.onToggle,
    required this.onBack,
    required this.onNext,
  });

  @override
  State<_GenreStep> createState() => _GenreStepState();
}

class _GenreStepState extends State<_GenreStep> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final ordered = _genreOrderFor(widget.country?.code);
    final filtered = _query.isEmpty
        ? ordered
        : ordered
            .where((g) => g.label.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: Icon(Icons.arrow_back_rounded,
                    color: AurumTheme.textPrimaryOf(context)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const Spacer(),
              const _StepDots(activeIndex: 1, total: 3),
              const Spacer(),
              const SizedBox(width: 40),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'What do you like\nlistening to?',
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.5,
              color: AurumTheme.textPrimaryOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.country != null
                ? 'Pick a few — sorted for ${widget.country!.name}.'
                : 'Pick a few — we\'ll shape your Home feed around them.',
            style: TextStyle(
              fontSize: 14,
              color: AurumTheme.textMutedOf(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _SearchField(
            hint: 'Search genres',
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      'No genres match "$_query"',
                      style: TextStyle(color: AurumTheme.textMutedOf(context)),
                    ),
                  )
                : GridView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: filtered.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 2.4,
                    ),
                    itemBuilder: (context, i) {
                      final genre = filtered[i];
                      final isSelected = widget.selected.contains(genre.key);
                      return _PillChip(
                        label: genre.label,
                        icon: genre.icon,
                        selected: isSelected,
                        accent: accent,
                        onTap: () {
                          AurumHaptics.selection();
                          widget.onToggle(genre.key);
                        },
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: widget.onNext,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: Text(
                widget.selected.isEmpty ? 'Skip for now' : 'Continue',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 3 — Artist picker — LIVE search results, scoped by country + genres
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistStep extends StatefulWidget {
  final _Country? country;
  final Set<String> genres;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onBack;
  final Future<void> Function() onFinish;

  const _ArtistStep({
    super.key,
    required this.country,
    required this.genres,
    required this.selected,
    required this.onToggle,
    required this.onBack,
    required this.onFinish,
  });

  @override
  State<_ArtistStep> createState() => _ArtistStepState();
}

class _ArtistStepState extends State<_ArtistStep> {
  List<ArtistSimple>? _artists; // null = loading, [] = failed/empty
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  Future<void> _loadArtists() async {
    try {
      final genreList = widget.genres.isNotEmpty
          ? _kOnboardingGenres.where((g) => widget.genres.contains(g.key)).toList()
          : _genreOrderFor(widget.country?.code).take(3).toList();

      final countryName = widget.country?.name;

      // One live search per selected genre (capped to keep first-launch
      // snappy), each scoped with the country name so results skew toward
      // artists relevant to that genre IN that region rather than a
      // single generic global query. Runs concurrently.
      final queries = genreList.take(4).map((g) {
        final seed = countryName != null
            ? '${g.searchSeed} $countryName artists'
            : '${g.searchSeed} artists';
        return ApiService.searchArtists(seed, limit: 8)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => <ArtistSimple>[]);
      }).toList();

      final results = await Future.wait(queries)
          .timeout(const Duration(seconds: 7), onTimeout: () => <List<ArtistSimple>>[]);

      final merged = <ArtistSimple>[];
      final seenNames = <String>{};
      for (final list in results) {
        for (final a in list) {
          if (a.name.isEmpty) continue;
          if (seenNames.add(a.name.toLowerCase())) merged.add(a);
        }
      }

      // Fallback: if genre-scoped search came back thin (e.g. no genres
      // picked and country search too narrow), fall back to the general
      // home-artist pool so this step is never empty for no good reason.
      if (merged.length < 6) {
        try {
          final fallback = await ApiService.fetchHomeArtists()
              .timeout(const Duration(seconds: 5));
          for (final a in fallback) {
            if (a.name.isEmpty) continue;
            if (seenNames.add(a.name.toLowerCase())) merged.add(a);
          }
        } catch (_) {}
      }

      if (mounted) setState(() => _artists = merged);
    } catch (_) {
      if (mounted) setState(() => _artists = const []);
    }
  }

  Future<void> _handleFinish() async {
    if (_saving) return;
    setState(() => _saving = true);
    AurumHaptics.medium();
    await widget.onFinish();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final loading = _artists == null;
    final hasArtists = _artists != null && _artists!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                icon: Icon(Icons.arrow_back_rounded,
                    color: AurumTheme.textPrimaryOf(context)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const Spacer(),
              const _StepDots(activeIndex: 2, total: 3),
              const Spacer(),
              const SizedBox(width: 40),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Follow a few\nartists?',
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.2,
              letterSpacing: -0.5,
              color: AurumTheme.textPrimaryOf(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasArtists
                ? 'Tap the ones you love — this fine-tunes your\nrecommendations even further.'
                : loading
                    ? 'Finding artists picked for you...'
                    : 'We couldn\'t load artist picks right now — no\nworries, you can skip this step.',
            style: TextStyle(
              fontSize: 14,
              color: AurumTheme.textMutedOf(context),
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : hasArtists
                    ? GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        itemCount: _artists!.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 12,
                          childAspectRatio: 0.78,
                        ),
                        itemBuilder: (context, i) {
                          final artist = _artists![i];
                          final isSelected = widget.selected.contains(artist.name);
                          return _ArtistCard(
                            artist: artist,
                            selected: isSelected,
                            accent: accent,
                            onTap: () {
                              AurumHaptics.selection();
                              widget.onToggle(artist.name);
                            },
                          );
                        },
                      )
                    : const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _saving ? null : _handleFinish,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: _saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        valueColor: AlwaysStoppedAnimation(Colors.black),
                      ),
                    )
                  : Text(
                      widget.selected.isEmpty ? 'Skip & Start Listening' : 'Start Listening',
                      style:
                          const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared small widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: TextField(
        onChanged: onChanged,
        style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
          prefixIcon: Icon(Icons.search_rounded,
              color: AurumTheme.textMutedOf(context), size: 20),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  final int activeIndex;
  final int total;
  const _StepDots({required this.activeIndex, required this.total});

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final muted = AurumTheme.dividerOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: active ? 20 : 6,
          height: 6,
          decoration: BoxDecoration(
            color: active ? accent : muted,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

class _PillChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _PillChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? accent : AurumTheme.dividerOf(context);
    final bgColor =
        selected ? accent.withValues(alpha: 0.14) : AurumTheme.bgCardOf(context);
    final fgColor = selected ? accent : AurumTheme.textPrimaryOf(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        splashFactory: NoSplash.splashFactory,
        highlightColor: accent.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: selected ? 1.4 : 0.8),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(icon, color: fgColor, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: accent, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistCard extends StatelessWidget {
  final ArtistSimple artist;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _ArtistCard({
    required this.artist,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Stack(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 82,
                height: 82,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: ClipOval(
                  child: artist.imageUrl.isEmpty
                      ? Container(
                          color: AurumTheme.bgCardOf(context),
                          child: Icon(Icons.person_rounded,
                              color: AurumTheme.textMutedOf(context)),
                        )
                      : CachedNetworkImage(
                          imageUrl: artist.imageUrl,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: AurumTheme.bgCardOf(context)),
                          errorWidget: (_, __, ___) => Container(
                            color: AurumTheme.bgCardOf(context),
                            child: Icon(Icons.person_rounded,
                                color: AurumTheme.textMutedOf(context)),
                          ),
                        ),
                ),
              ),
              if (selected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: AurumTheme.bgOf(context),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check_circle_rounded,
                        color: accent, size: 20),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AurumTheme.textPrimaryOf(context),
            ),
          ),
        ],
      ),
    );
  }
}
