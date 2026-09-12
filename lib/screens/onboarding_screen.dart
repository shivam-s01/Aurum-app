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
//     J-Pop/Anime first). See genreOrderFor() below.
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/api_service.dart';
import '../services/recommendation_engine.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../config/region_catalog.dart';

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
  Country? _selectedCountry;
  final Set<String> _selectedGenres = {};
  final Set<String> _selectedArtists = {}; // artist names

  bool _detectedAutomatically = false;
  // True only while the user has explicitly tapped "Auto-Detect" and the
  // real (network) detection is in flight — drives the scanning/loading-
  // bar animation on the Country step. Detection no longer runs
  // automatically on open: the user is shown a choice (Auto-Detect vs.
  // search manually) first, and nothing fires until they pick one.
  bool _detecting = false;
  // True only when the user tapped Auto-Detect and it came back empty
  // (no network, or every provider failed) — surfaced as a small inline
  // notice above the manual list instead of silently dropping the user
  // into search with zero explanation of what just happened.
  bool _detectionFailed = false;

  @override
  void initState() {
    super.initState();
    // Intentionally NOT calling _runDetection() here anymore — see the
    // _detecting comment above. The Country step now opens on a neutral
    // choice screen; detection only starts if/when the user taps
    // "Auto-Detect" (wired via _CountryStep.onAutoDetect below).
  }

  Future<void> _runDetection() async {
    setState(() {
      _detecting = true;
      _detectionFailed = false;
    });
    // Real, accurate detection: IP-based geolocation (what actually
    // reflects where the user is), with locale only as a last-resort
    // fallback if every network attempt fails. This replaces the old
    // locale-only detection, which is why it used to show "UK" for
    // someone in India — locale reflects the phone's language setting,
    // not its actual location.
    final detected = await detectCountryReal();
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (detected != null) {
        _selectedCountry = detected;
        _detectedAutomatically = true;
      } else {
        _detectionFailed = true;
      }
    });
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
                detecting: _detecting,
                detectionFailed: _detectionFailed,
                onAutoDetect: _runDetection,
                onSelect: (c) => setState(() {
                  _selectedCountry = c;
                  _detectedAutomatically = false;
                  _detecting = false;
                  _detectionFailed = false;
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
  final Country? selected;
  final bool autoDetected;
  final bool detecting;
  final bool detectionFailed;
  final VoidCallback onAutoDetect;
  final ValueChanged<Country> onSelect;
  final VoidCallback onNext;

  const _CountryStep({
    super.key,
    required this.selected,
    required this.autoDetected,
    required this.detecting,
    required this.detectionFailed,
    required this.onAutoDetect,
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
    // Only force the manual list open on a genuine transition out of
    // detecting (detection finished — success or failure). Checking the
    // current state alone (old buggy check) fired on ANY rebuild while
    // still in the neutral/choice state, forcing _showManualList = true
    // before the user ever tapped anything — which is why "Auto-Detect"
    // never appeared.
    final justFinishedDetecting = oldWidget.detecting && !widget.detecting;
    if (justFinishedDetecting && widget.detectionFailed) {
      _showManualList = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final filtered = _query.isEmpty
        ? kCountries
        : kCountries
            .where((c) => c.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    final showDetectedBanner = widget.autoDetected && widget.selected != null && !_showManualList;
    final showScanning = widget.detecting && !_showManualList;
    // FIX ("no country pre-selected on open, give a real choice"):
    // detection no longer auto-fires on open, so by default nothing has
    // happened yet — neither a detected country nor a manual search.
    // That neutral state now shows the two-option choice screen
    // (Auto-Detect vs. search manually) instead of jumping straight into
    // either flow.
    final showChoice = !showScanning && !showDetectedBanner && !_showManualList;

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
          if (showChoice) ...[
            Expanded(
              child: _CountryChoiceView(
                accent: accent,
                onAutoDetect: widget.onAutoDetect,
                onSearchManually: () => setState(() => _showManualList = true),
              ),
            ),
          ] else if (showScanning) ...[
            _ScanningLocationCard(
              accent: accent,
              onChooseManually: () => setState(() => _showManualList = true),
            ),
            const Spacer(),
          ] else if (showDetectedBanner) ...[
            _DetectedCountryCard(
              country: widget.selected!,
              accent: accent,
              onChangeTap: () => setState(() => _showManualList = true),
            ),
            const Spacer(),
          ] else ...[
            if (widget.detectionFailed) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AurumTheme.bgCardOf(context),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AurumTheme.dividerOf(context)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded,
                        size: 18, color: AurumTheme.textMutedOf(context)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        "Couldn't detect automatically — pick your country below.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AurumTheme.textMutedOf(context),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
          // The bottom button only makes sense once a real choice has
          // been resolved (a country picked, or the user is browsing the
          // manual list and can Skip). On the neutral choice screen,
          // "Auto-Detect" and "Search manually" are already the two
          // actions available, so the button is hidden there.
          if (!showChoice)
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: showScanning ? null : widget.onNext,
                style: ElevatedButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.black,
                  disabledBackgroundColor: accent.withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: Text(
                  showScanning
                      ? 'Detecting...'
                      : widget.selected == null
                          ? 'Skip for now'
                          : 'Continue',
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
// Country choice screen — the neutral first state shown when the Country
// step opens: nothing is pre-selected and nothing runs automatically.
// The user picks one of two explicit actions:
//   - "Auto-Detect My Country" -> triggers the real (IP-based) network
//     detection with the scanning/loading-bar animation.
//   - "Search Manually" -> opens the same searchable 195-country list
//     used everywhere else in this step.
// This replaces the old behavior where detection fired the instant the
// screen opened with no user action at all.
// ─────────────────────────────────────────────────────────────────────────────
class _CountryChoiceView extends StatelessWidget {
  final Color accent;
  final VoidCallback onAutoDetect;
  final VoidCallback onSearchManually;

  const _CountryChoiceView({
    required this.accent,
    required this.onAutoDetect,
    required this.onSearchManually,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.public_rounded, color: accent.withValues(alpha: 0.7), size: 56),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: () {
              AurumHaptics.medium();
              onAutoDetect();
            },
            icon: const Icon(Icons.my_location_rounded, size: 20),
            label: const Text(
              'Auto-Detect My Country',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Takes 1-3 seconds — uses your network,\nnot GPS.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: AurumTheme.textMutedOf(context),
            height: 1.4,
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'OR',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AurumTheme.textMutedOf(context),
                ),
              ),
            ),
            Expanded(child: Divider(color: AurumTheme.dividerOf(context))),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton.icon(
            onPressed: () {
              AurumHaptics.selection();
              onSearchManually();
            },
            icon: Icon(Icons.search_rounded, size: 20, color: AurumTheme.textPrimaryOf(context)),
            label: Text(
              'Search Manually',
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: AurumTheme.textPrimaryOf(context),
              ),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: AurumTheme.dividerOf(context)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Scanning card — shown while real (network) country detection is in
// flight. A radar-style sweep + expanding pulse rings around a location
// pin, entirely built from AnimationControllers/CustomPainter (no new
// packages, no image/Lottie assets), so it's cheap on low-end devices
// and starts rendering the instant the Country step builds. This is what
// makes detection feel deliberate/"real" instead of an instant, opaque
// guess — the user sees an actual scan happen while the IP lookup races
// in the background.
// ─────────────────────────────────────────────────────────────────────────────
class _ScanningLocationCard extends StatefulWidget {
  final Color accent;
  final VoidCallback onChooseManually;

  const _ScanningLocationCard({
    required this.accent,
    required this.onChooseManually,
  });

  @override
  State<_ScanningLocationCard> createState() => _ScanningLocationCardState();
}

class _ScanningLocationCardState extends State<_ScanningLocationCard>
    with TickerProviderStateMixin {
  late final AnimationController _sweep; // continuous radar rotation
  late final AnimationController _pulse; // continuous expanding rings
  late final AnimationController _entrance; // one-shot card entrance
  late final AnimationController _progress; // drives the loading bar fill
  late final AnimationController _shimmer; // moving glow inside the bar

  static const List<String> _statusMessages = [
    'Scanning your network...',
    'Pinpointing your region...',
    'Almost there...',
  ];
  int _statusIndex = 0;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();

    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();

    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    // Loading bar fill: eases up to ~92% on its own over the real network
    // detection's worst-case window (~3.5s, see detectCountryReal) so it
    // reads as genuine progress rather than a fake instant-complete bar —
    // then _CountryStepState jumps it to 100% the moment detection
    // actually resolves (see the `key` swap on this widget / didUpdateWidget
    // in the parent, which disposes this state once detecting flips to
    // false, so the bar is never left visibly stuck under 100%).
    _progress = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3400),
    )..forward();

    // Continuous moving highlight inside the filled portion of the bar —
    // the "cool" shimmer sweep, independent of actual fill progress.
    _shimmer = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();

    // Cycle the status line every ~1.1s so a slower network lookup still
    // reads as active progress rather than a stuck spinner.
    _statusTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      if (!mounted) return;
      setState(() => _statusIndex = (_statusIndex + 1) % _statusMessages.length);
    });
  }

  @override
  void dispose() {
    _sweep.dispose();
    _pulse.dispose();
    _entrance.dispose();
    _progress.dispose();
    _shimmer.dispose();
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardBg = AurumTheme.bgCardOf(context);
    final border = AurumTheme.dividerOf(context);

    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_entrance.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: child,
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border, width: 1),
        ),
        child: Column(
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: AnimatedBuilder(
                animation: Listenable.merge([_sweep, _pulse]),
                builder: (context, _) {
                  return CustomPaint(
                    painter: _RadarPainter(
                      sweepAngle: _sweep.value * 2 * 3.14159265,
                      pulseValue: _pulse.value,
                      accent: widget.accent,
                    ),
                    child: Center(
                      child: Icon(
                        Icons.location_on_rounded,
                        color: widget.accent,
                        size: 28,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: Text(
                _statusMessages[_statusIndex],
                key: ValueKey(_statusIndex),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AurumTheme.textPrimaryOf(context),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Finding the country closest to your\nactual network for accurate results.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: AurumTheme.textMutedOf(context),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            // Animated loading bar — eased fill + a moving shimmer
            // highlight riding on top of the filled portion, both purely
            // CustomPaint (no packages), so it stays cheap and matches
            // the accent color automatically.
            SizedBox(
              width: double.infinity,
              height: 6,
              child: AnimatedBuilder(
                animation: Listenable.merge([_progress, _shimmer]),
                builder: (context, _) {
                  return CustomPaint(
                    painter: _LoadingBarPainter(
                      // Ease toward 92%, never claiming 100% until the
                      // real network result actually lands.
                      fill: Curves.easeOutCubic.transform(_progress.value) * 0.92,
                      shimmer: _shimmer.value,
                      accent: widget.accent,
                      track: border,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: widget.onChooseManually,
              style: TextButton.styleFrom(
                foregroundColor: widget.accent,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
              child: const Text(
                'Choose manually instead',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the loading bar: a rounded track, an eased accent-colored fill,
/// and a soft moving highlight band that sweeps left-to-right across the
/// filled portion on a short loop — the "shimmer" that makes the bar read
/// as actively working rather than a static filled rectangle.
class _LoadingBarPainter extends CustomPainter {
  final double fill; // 0..1 how much of the bar is filled
  final double shimmer; // 0..1 position of the moving highlight
  final Color accent;
  final Color track;

  _LoadingBarPainter({
    required this.fill,
    required this.shimmer,
    required this.accent,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);

    // Track (full-width, faint).
    final trackPaint = Paint()..color = track.withValues(alpha: 0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      trackPaint,
    );

    final fillWidth = size.width * fill.clamp(0.0, 1.0);
    if (fillWidth <= 0) return;

    final fillRect = Rect.fromLTWH(0, 0, fillWidth, size.height);
    final fillRRect = RRect.fromRectAndRadius(fillRect, radius);

    // Base fill.
    canvas.save();
    canvas.clipRRect(fillRRect);
    canvas.drawRect(fillRect, Paint()..color = accent.withValues(alpha: 0.85));

    // Moving shimmer highlight, clipped to the filled region so it never
    // spills onto the empty track.
    final shimmerCenter = fillWidth * shimmer;
    final shimmerWidth = size.width * 0.35;
    final shimmerRect = Rect.fromLTWH(
      shimmerCenter - shimmerWidth / 2,
      0,
      shimmerWidth,
      size.height,
    );
    final shimmerPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.55),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(shimmerRect);
    canvas.drawRect(shimmerRect, shimmerPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LoadingBarPainter oldDelegate) {
    return oldDelegate.fill != fill ||
        oldDelegate.shimmer != shimmer ||
        oldDelegate.accent != accent ||
        oldDelegate.track != track;
  }
}

/// Paints the radar: a soft rotating conic sweep wedge, two expanding
/// pulse rings, and a static faint outer ring — all in the accent color
/// so it matches the app's dynamic theme automatically. Pure CustomPaint,
/// no assets, cheap enough to run continuously at 60fps.
class _RadarPainter extends CustomPainter {
  final double sweepAngle;
  final double pulseValue;
  final Color accent;

  _RadarPainter({
    required this.sweepAngle,
    required this.pulseValue,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // Static faint outer + mid rings for depth.
    final ringPaint = Paint()
      ..color = accent.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(center, maxRadius * 0.98, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.66, ringPaint);
    canvas.drawCircle(center, maxRadius * 0.34, ringPaint);

    // Two staggered expanding pulse rings (fade out as they grow).
    for (final offset in [0.0, 0.5]) {
      final progress = (pulseValue + offset) % 1.0;
      final radius = maxRadius * (0.25 + progress * 0.75);
      final opacity = (1.0 - progress).clamp(0.0, 1.0) * 0.35;
      final pulsePaint = Paint()
        ..color = accent.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(center, radius, pulsePaint);
    }

    // Rotating radar sweep — a conic gradient wedge fading to
    // transparent, like a classic radar scan line.
    final sweepRect = Rect.fromCircle(center: center, radius: maxRadius);
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 3.14159265 / 2, // 90-degree bright wedge
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: 0.35),
        ],
        transform: GradientRotation(sweepAngle),
      ).createShader(sweepRect);
    canvas.drawCircle(center, maxRadius, sweepPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) {
    return oldDelegate.sweepAngle != sweepAngle ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.accent != accent;
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
  final Country country;
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
  final Country? country;
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
    final ordered = genreOrderFor(widget.country?.code);
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
  final Country? country;
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
      // FIX ("40 artists minimum"): genre count was capped at 4 and each
      // genre query capped at limit:10 — worst case that's a hard 40-item
      // ceiling BEFORE de-duplication even runs, so overlapping results
      // between genres routinely left the picker well under 40. Now:
      // pull from every selected genre (not just the first 4) and ask
      // each query for more (limit: 16) so there's enough raw supply
      // even after duplicates are dropped and the merge cap (60) still
      // comfortably clears the 40-artist floor in the common case.
      final genreList = widget.genres.isNotEmpty
          ? kOnboardingGenres.where((g) => widget.genres.contains(g.key)).toList()
          : genreOrderFor(widget.country?.code).take(4).toList();

      final countryName = widget.country?.name;
      final countryCode = widget.country?.code;
      // Computed once up front (also reused by the top-up logic below):
      // whether Saavn's India-only catalog is a safe source for this
      // country. See searchArtistsRegionScoped's doc comment — Saavn has
      // no artist-type filter and no country awareness, so racing it in
      // for a non-Indian query let mismatched Indian results win the
      // race purely on speed, which is why picks looked completely
      // unrelated to the chosen country/genre.
      final isIndiaOrUnset = countryCode == null || countryCode == 'IN';

      // FIX: the old query was a single loose string like "pop United
      // Kingdom artists" — that's a free-text search with no real filter
      // behind it, so a country/genre combo with thin native coverage
      // would silently backfill with generically popular but unrelated
      // artists. Changes here:
      //   1. Query phrasing is now genre-aware and region-native where we
      //      know it (e.g. Bollywood + India -> "bollywood playback
      //      singers India", not just "bollywood India artists"), which
      //      biases the underlying search much more tightly.
      //   2. Every result is tagged with which genre query produced it,
      //      and results are taken round-robin across genres (instead of
      //      genre-1's results filling the whole grid) so the picker
      //      visibly reflects every genre + the chosen country, not just
      //      whichever query happened to return the most matches.
      //   3. Saavn is only raced in for India/unset — see isIndiaOrUnset
      //      above. Every other country now searches YT Music's
      //      artist-type-filtered shelves only, which is what actually
      //      fixes results matching the picked country/genre.
      final queries = genreList.map((g) {
        final seed = buildArtistSearchSeed(
          genreSeed: g.searchSeed,
          countryName: countryName,
        );
        return ApiService.searchArtistsRegionScoped(seed,
                limit: 16, includeSaavn: isIndiaOrUnset)
            .timeout(const Duration(seconds: 4))
            .catchError((_) => <ArtistSimple>[])
            .then((list) => MapEntry(g.key, list));
      }).toList();

      final results = await Future.wait(queries).timeout(
        const Duration(seconds: 6),
        onTimeout: () => <MapEntry<String, List<ArtistSimple>>>[],
      );

      // Round-robin merge across genre buckets so the grid represents
      // every selected genre/country combo fairly instead of one query's
      // results dominating.
      final merged = <ArtistSimple>[];
      final seenNames = <String>{};
      final buckets = results.map((e) => e.value).toList();
      var addedAny = true;
      var col = 0;
      while (addedAny && merged.length < 60) {
        addedAny = false;
        for (final bucket in buckets) {
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

      // FIX: if the genre-scoped queries still come back under the
      // 40-artist floor (e.g. only 1-2 genres picked, or a niche
      // genre+country combo with thin native coverage), top up with the
      // general home-artist pool BEFORE giving up — this is what
      // actually guarantees "at least 40 artists" instead of silently
      // showing whatever the genre queries happened to return.
      //
      // IMPORTANT: fetchHomeArtists() is a curated pool that's India-
      // centric (Bollywood/Punjabi/Pop/Retro) — it has no country
      // parameter. Using it to top up for a non-Indian country would be
      // a jarring mismatch (a US/Japan user suddenly seeing Arijit
      // Singh/Diljit Dosanjh). So this top-up only fires for India (or
      // when no country was picked/detected at all, where there's no
      // better default). Every other country instead widens its OWN
      // genre search net first (see the extra queries below) rather
      // than falling back to a mismatched pool.
      // (countryCode / isIndiaOrUnset already computed above.)

      if (merged.length < 40 && isIndiaOrUnset) {
        try {
          final topUp = await ApiService.fetchHomeArtists()
              .timeout(const Duration(seconds: 4));
          for (final a in topUp) {
            if (merged.length >= 40) break;
            if (a.name.isEmpty) continue;
            if (seenNames.add(a.name.toLowerCase())) merged.add(a);
          }
        } catch (_) {}
      }

      // For every OTHER country, if still under the floor, widen the net
      // with additional genre queries beyond the ones already tried
      // (the full country-appropriate genre priority list, not just
      // what the user picked) — this keeps every top-up artist at least
      // genre/region-relevant instead of falling back to an unrelated
      // curated pool.
      if (merged.length < 40 && !isIndiaOrUnset) {
        try {
          final triedKeys = genreList.map((g) => g.key).toSet();
          final extraGenres = genreOrderFor(countryCode)
              .where((g) => !triedKeys.contains(g.key))
              .take(4)
              .toList();

          final extraQueries = extraGenres.map((g) {
            final seed = buildArtistSearchSeed(
              genreSeed: g.searchSeed,
              countryName: countryName,
            );
            return ApiService.searchArtistsRegionScoped(seed,
                    limit: 16, includeSaavn: isIndiaOrUnset)
                .timeout(const Duration(seconds: 4))
                .catchError((_) => <ArtistSimple>[]);
          }).toList();

          final extraResults = await Future.wait(extraQueries).timeout(
            const Duration(seconds: 6),
            onTimeout: () => <List<ArtistSimple>>[],
          );

          for (final list in extraResults) {
            for (final a in list) {
              if (merged.length >= 40) break;
              if (a.name.isEmpty) continue;
              if (seenNames.add(a.name.toLowerCase())) merged.add(a);
            }
          }
        } catch (_) {}
      }

      // Fallback: if genre-scoped search came back thin (e.g. no genres
      // picked and country search too narrow), fall back to the general
      // home-artist pool so this step is never empty for no good reason.
      // Covers the "topUp above wasn't enough either" case too, e.g.
      // fetchHomeArtists() itself returned an overlapping/small set.
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
