// =============================================================================
// FILE: lib/screens/settings_region_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Settings > Region & Music Preferences. Lets a user who has
//   already finished onboarding come back at any time and change their
//   country, genres, and followed artists — the same three inputs
//   onboarding collects once, but editable for the lifetime of the app
//   instead of a one-shot first-launch flow.
//
//   Built as ONE scrollable screen (country picker -> genre chips -> artist
//   grid -> Save), not a multi-step wizard like onboarding: this is an
//   editing surface for someone who already has an account and a feed.
//   Country is pre-filled from the current saved value; genres/artists
//   intentionally start blank on every visit (see _loadCurrentPrefs'
//   comment for why boosted weights can't be reverse-mapped back to a
//   display selection) — anything picked here adds a fresh onboarding-
//   strength boost on top of the existing feed rather than replacing it.
//
// WIRING:
//   - Reuses lib/config/region_catalog.dart for the country list, genre
//     catalog, genre-priority-by-country ordering, and the artist
//     search-seed builder — the exact same data/logic onboarding uses, so
//     the two surfaces can never drift out of sync.
//   - Reads the CURRENT country from 'onboarding_country_code' /
//     'onboarding_country_name' SharedPreferences (written by onboarding,
//     or by this screen after a previous edit).
//   - On Save: writes the new country back to those same two keys, and
//     pushes the newly-picked genres/artists into RecommendationEngine via
//     applyOnboardingGenrePreferences()/applyOnboardingArtistPreferences()
//     — the identical calls onboarding makes. Both are additive boosts
//     (existing weights are nudged up, never reset), so re-picking a
//     region never erases listening history that's already shaped the
//     feed; it just gives the new picks the same strong head-start
//     onboarding gives a first-time pick.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../config/region_catalog.dart';
import '../services/api_service.dart';
import '../services/recommendation_engine.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../widgets/aurum_morph_loader.dart';

class SettingsRegionScreen extends StatefulWidget {
  const SettingsRegionScreen({super.key});

  @override
  State<SettingsRegionScreen> createState() => _SettingsRegionScreenState();
}

class _SettingsRegionScreenState extends State<SettingsRegionScreen> {
  bool _loadingPrefs = true;
  bool _saving = false;

  Country? _country;
  Country? _initialCountry; // snapshot at load time, to detect a real change on Save
  final Set<String> _selectedGenres = {};
  final Set<String> _selectedArtists = {};

  // Artist search state — re-runs whenever the effective genre/country
  // selection changes (see _reloadArtists below).
  List<ArtistSimple>? _artists; // null = loading, [] = failed/empty
  int _artistLoadToken = 0; // guards against a stale, slow search overwriting a newer one

  bool _countryExpanded = false;
  String _countryQuery = '';

  @override
  void initState() {
    super.initState();
    _loadCurrentPrefs();
  }

  Future<void> _loadCurrentPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final code = p.getString('onboarding_country_code');
      final savedCountry = countryByCode(code);

      // NOTE: genres/artists intentionally start unselected rather than
      // trying to "reverse" the current boosted weights back into a
      // selection. RecommendationEngine stores artist weights under a
      // normalized key (all non-alphanumeric characters, spaces
      // included, stripped — see _normalizeKey) with no separate
      // display-name field, so "Arijit Singh" is stored as
      // "arijitsingh" with the original casing/spacing gone for good.
      // There's no lossless way to turn that back into a real display
      // name for pre-filling this screen, and guessing would risk
      // showing a garbled or wrong-cased artist chip. Starting blank
      // means every pick made here is unambiguous and additive on top
      // of whatever the feed has already learned.
      if (!mounted) return;
      setState(() {
        _country = savedCountry;
        _initialCountry = savedCountry;
        _loadingPrefs = false;
      });
      _reloadArtists();
    } catch (_) {
      if (mounted) setState(() => _loadingPrefs = false);
    }
  }

  void _onCountrySelected(Country c) {
    AurumHaptics.selection();
    setState(() {
      _country = c;
      _countryExpanded = false;
      _countryQuery = '';
    });
    _reloadArtists();
  }

  void _onGenreToggled(String key) {
    AurumHaptics.selection();
    setState(() {
      if (!_selectedGenres.remove(key)) _selectedGenres.add(key);
    });
    _reloadArtists();
  }

  void _onArtistToggled(String name) {
    AurumHaptics.selection();
    setState(() {
      if (!_selectedArtists.remove(name)) _selectedArtists.add(name);
    });
  }

  Future<void> _reloadArtists() async {
    final token = ++_artistLoadToken;
    setState(() => _artists = null); // show loading state immediately

    try {
      final genreList = _selectedGenres.isNotEmpty
          ? kOnboardingGenres.where((g) => _selectedGenres.contains(g.key)).toList()
          : genreOrderFor(_country?.code).take(4).toList();

      final countryName = _country?.name;
      final countryCode = _country?.code;
      // Same reasoning as onboarding's artist loader (see
      // region_catalog.dart / searchArtistsRegionScoped doc comment):
      // Saavn's catalog is India-only and has no artist-type filter, so
      // it only gets raced in when the picked country is India/unset —
      // every other country searches YT Music's artist-filtered shelves
      // only, which is what keeps results genuinely matching the picked
      // country/genre instead of a fast-but-wrong Saavn match winning.
      final isIndiaOrUnset = countryCode == null || countryCode == 'IN';

      final queries = genreList.map((g) {
        final seed = buildArtistSearchSeed(
          genreSeed: g.searchSeed,
          countryName: countryName,
        );
        return ApiService.searchArtistsRegionScoped(seed,
                limit: 16, includeSaavn: isIndiaOrUnset)
            .timeout(const Duration(seconds: 4))
            .catchError((_) => <ArtistSimple>[]);
      }).toList();

      final results = await Future.wait(queries).timeout(
        const Duration(seconds: 6),
        onTimeout: () => <List<ArtistSimple>>[],
      );

      // Round-robin merge across genre buckets, same as onboarding, so
      // the grid represents every selected genre fairly.
      final merged = <ArtistSimple>[];
      final seenNames = <String>{};
      var addedAny = true;
      var col = 0;
      while (addedAny && merged.length < 60) {
        addedAny = false;
        for (final bucket in results) {
          if (col < bucket.length) {
            final a = bucket[col];
            if (a.name.isNotEmpty && seenNames.add(a.name.toLowerCase())) {
              merged.add(a);
            }
            addedAny = true;
          }
        }
        col++;
      }

      if (merged.length < 6) {
        try {
          final fallback = await ApiService.fetchHomeArtists()
              .timeout(const Duration(seconds: 4));
          for (final a in fallback) {
            if (a.name.isEmpty) continue;
            if (seenNames.add(a.name.toLowerCase())) merged.add(a);
          }
        } catch (_) {}
      }

      // A newer reload started while this one was in flight (user kept
      // tapping genres/country) — drop this stale result instead of
      // clobbering whatever the latest reload already produced.
      if (!mounted || token != _artistLoadToken) return;
      setState(() => _artists = merged);
    } catch (_) {
      if (!mounted || token != _artistLoadToken) return;
      setState(() => _artists = const []);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    AurumHaptics.medium();

    final hadNewPicks = _selectedGenres.isNotEmpty || _selectedArtists.isNotEmpty;
    final countryChanged = _country?.code != _initialCountry?.code;

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
      // Never block on a preference-save failure — worst case the country
      // still saves below and genres/artists just don't get their boost.
    }

    try {
      final p = await SharedPreferences.getInstance();
      if (_country != null) {
        await p.setString('onboarding_country_code', _country!.code);
        await p.setString('onboarding_country_name', _country!.name);
      } else {
        await p.remove('onboarding_country_code');
        await p.remove('onboarding_country_name');
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() => _saving = false);
    // Message reflects what actually changed — saying "your feed will
    // reflect this" when the person only changed the country (no
    // genres/artists tapped, which is the common case since this screen
    // intentionally starts both blank) would promise a feed change that
    // didn't happen. Likewise, tapping Save with nothing changed at all
    // shouldn't claim anything was updated.
    final message = hadNewPicks
        ? 'Preferences updated — your feed will reflect this shortly.'
        : countryChanged
            ? 'Country updated.'
            : 'No changes to save.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AurumTheme.bgCardOf(context),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              color: AurumTheme.textPrimaryOf(context), size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Region & Music Preferences',
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w600)),
      ),
      body: _loadingPrefs
          ? const Center(child: AurumMorphLoader(size: 40))
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              children: [
                Text(
                  'Change your country any time — it reshapes which '
                  'genres and artists surface first, both here and on '
                  'your Home feed.',
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),
                _SectionLabel('COUNTRY'),
                const SizedBox(height: 8),
                _CountryPicker(
                  selected: _country,
                  expanded: _countryExpanded,
                  query: _countryQuery,
                  onToggleExpanded: () =>
                      setState(() => _countryExpanded = !_countryExpanded),
                  onQueryChanged: (v) => setState(() => _countryQuery = v),
                  onSelect: _onCountrySelected,
                ),
                const SizedBox(height: 28),
                _SectionLabel('GENRES'),
                const SizedBox(height: 4),
                Text(
                  _country != null
                      ? 'Sorted for ${_country!.name}.'
                      : 'Pick a few — we\'ll shape your feed around them.',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 12),
                _GenreChipGrid(
                  country: _country,
                  selected: _selectedGenres,
                  onToggle: _onGenreToggled,
                ),
                const SizedBox(height: 28),
                _SectionLabel('ARTISTS'),
                const SizedBox(height: 4),
                Text(
                  'Follow a few to fine-tune recommendations further.',
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 12),
                _ArtistPickerGrid(
                  artists: _artists,
                  selected: _selectedArtists,
                  accent: accent,
                  onToggle: _onArtistToggled,
                ),
              ],
            ),
      bottomNavigationBar: _loadingPrefs
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: accent.withValues(alpha: 0.5),
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
                        : const Text('Save Preferences',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section label — matches _SectionHeader's style in settings_screen.dart
// (kept as a private local copy since that one is private to its own file).
// ─────────────────────────────────────────────────────────────────────────────
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AurumTheme.textMutedOf(context),
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Country picker — collapsed shows the current selection as a tappable
// row; expanded shows the full searchable 195-country list inline (no
// separate screen/route — this is meant to feel like one continuous edit
// surface, not another wizard step).
// ─────────────────────────────────────────────────────────────────────────────
class _CountryPicker extends StatelessWidget {
  final Country? selected;
  final bool expanded;
  final String query;
  final VoidCallback onToggleExpanded;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<Country> onSelect;

  const _CountryPicker({
    required this.selected,
    required this.expanded,
    required this.query,
    required this.onToggleExpanded,
    required this.onQueryChanged,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final filtered = query.isEmpty
        ? kCountries
        : kCountries
            .where((c) => c.name.toLowerCase().contains(query.toLowerCase()))
            .toList();

    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onToggleExpanded,
              splashFactory: NoSplash.splashFactory,
              highlightColor: accent.withValues(alpha: 0.06),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    if (selected != null) ...[
                      Text(selected!.flag, style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 12),
                    ] else ...[
                      Icon(Icons.public_rounded,
                          size: 20, color: AurumTheme.textMutedOf(context)),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        selected?.name ?? 'Not set',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AurumTheme.textPrimaryOf(context),
                        ),
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                      color: AurumTheme.textMutedOf(context),
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, thickness: 0.5, color: AurumTheme.dividerOf(context)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                onChanged: onQueryChanged,
                autofocus: true,
                style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search countries',
                  hintStyle: TextStyle(color: AurumTheme.textMutedOf(context)),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: AurumTheme.textMutedOf(context)),
                  filled: true,
                  fillColor: AurumTheme.bgOf(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: filtered.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No countries match "$query"',
                          style: TextStyle(color: AurumTheme.textMutedOf(context)),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        thickness: 0.5,
                        indent: 16,
                        color: AurumTheme.dividerOf(context),
                      ),
                      itemBuilder: (context, i) {
                        final country = filtered[i];
                        final isSelected = selected?.code == country.code;
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => onSelect(country),
                            splashFactory: NoSplash.splashFactory,
                            highlightColor: accent.withValues(alpha: 0.06),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              child: Row(
                                children: [
                                  Text(country.flag, style: const TextStyle(fontSize: 22)),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Text(
                                      country.name,
                                      style: TextStyle(
                                        fontSize: 14.5,
                                        fontWeight:
                                            isSelected ? FontWeight.w600 : FontWeight.w500,
                                        color: isSelected
                                            ? accent
                                            : AurumTheme.textPrimaryOf(context),
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(Icons.check_circle_rounded,
                                        color: accent, size: 18),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Genre chip grid — reuses the same country-aware ordering onboarding
// uses (genreOrderFor from region_catalog.dart).
// ─────────────────────────────────────────────────────────────────────────────
class _GenreChipGrid extends StatelessWidget {
  final Country? country;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  const _GenreChipGrid({
    required this.country,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final ordered = genreOrderFor(country?.code);

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: ordered.map((genre) {
        final isSelected = selected.contains(genre.key);
        final borderColor = isSelected ? accent : AurumTheme.dividerOf(context);
        final bgColor =
            isSelected ? accent.withValues(alpha: 0.14) : AurumTheme.bgCardOf(context);
        final fgColor = isSelected ? accent : AurumTheme.textPrimaryOf(context);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onToggle(genre.key),
            borderRadius: BorderRadius.circular(20),
            splashFactory: NoSplash.splashFactory,
            highlightColor: accent.withValues(alpha: 0.06),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: borderColor, width: isSelected ? 1.4 : 0.8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(genre.icon, color: fgColor, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    genre.label,
                    style: TextStyle(
                      color: fgColor,
                      fontSize: 13.5,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artist grid — same visual language as onboarding's artist picker.
// ─────────────────────────────────────────────────────────────────────────────
class _ArtistPickerGrid extends StatelessWidget {
  final List<ArtistSimple>? artists;
  final Set<String> selected;
  final Color accent;
  final ValueChanged<String> onToggle;

  const _ArtistPickerGrid({
    required this.artists,
    required this.selected,
    required this.accent,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (artists == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: AurumMorphLoader(size: 32)),
      );
    }
    if (artists!.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Couldn\'t load artist picks right now.',
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13),
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: artists!.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemBuilder: (context, i) {
        final artist = artists![i];
        final isSelected = selected.contains(artist.name);
        return GestureDetector(
          onTap: () => onToggle(artist.name),
          child: Column(
            children: [
              Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSelected ? accent : Colors.transparent,
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
                  if (isSelected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: AurumTheme.bgOf(context),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.check_circle_rounded, color: accent, size: 18),
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
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: AurumTheme.textPrimaryOf(context),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
