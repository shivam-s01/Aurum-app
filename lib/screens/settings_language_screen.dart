import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/locale_provider.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_settings_tile.dart';
import '../widgets/aurum_loader.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_motion.dart';

class SettingsLanguageScreen extends StatefulWidget {
  const SettingsLanguageScreen({super.key});

  @override
  State<SettingsLanguageScreen> createState() => _SettingsLanguageScreenState();
}

class _SettingsLanguageScreenState extends State<SettingsLanguageScreen> {
  // Which row is mid-switch, so its own tile can show a small spinner
  // instead of its checkmark/circle — and every row gets briefly disabled
  // — while the locale change propagates through MaterialApp's rebuild.
  // That rebuild reflows every localized string in the whole app in one
  // frame, which is real work on a low-end device; a spinner here means
  // the tap always reads as "doing something" rather than looking frozen
  // or, worse, inviting a second tap mid-rebuild that queues up a second
  // full-app rebuild right behind the first.
  String? _switchingTo;

  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _select(Locale? locale) async {
    if (_switchingTo != null) return; // already mid-switch, ignore
    AurumHaptics.selection();
    setState(() => _switchingTo = locale?.languageCode ?? 'system');
    // A deliberate ~2s hold so the M3 morph spinner actually reads as
    // "loading" rather than flashing for a single frame — the real
    // locale swap below is near-instant on its own (it's an in-memory
    // rebuild), so without this pause the row would just blink. This
    // mirrors the same "always show *something* is happening" pattern
    // used for the account/app-data operations elsewhere in Settings,
    // just tuned to a longer, more deliberate duration since a language
    // switch reflows every string in the app and deserves to feel like
    // a real transition rather than an instant snap.
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;
    await context.read<LocaleProvider>().setLocale(locale);
    if (!mounted) return;
    setState(() => _switchingTo = null);
  }

  bool _matchesQuery(String nativeName, String? englishName, String code) {
    if (_query.isEmpty) return true;
    if (nativeName.toLowerCase().contains(_query)) return true;
    if (englishName != null && englishName.toLowerCase().contains(_query)) return true;
    if (code.toLowerCase().contains(_query)) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final localeProvider = context.watch<LocaleProvider>();
    final currentCode = localeProvider.locale?.languageCode;

    // "System default" only makes sense while browsing the full list —
    // once someone's actively searching for a specific language, a row
    // that isn't actually a language just adds noise above the results.
    final showSystemDefault = _query.isEmpty;

    final matches = kSupportedLocales.where((locale) {
      final code = locale.languageCode;
      final native = kLocaleDisplayNames[code] ?? code;
      final english = kLocaleEnglishNames[code];
      return _matchesQuery(native, english, code);
    }).toList();

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
        title: Text(l10n.settingsLanguage,
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        // Was missing BouncingScrollPhysics + the 100px bottom clearance
        // every other settings screen uses — without them this list used
        // Android's default ClampingScrollPhysics (hard-stops at the
        // edges, no overscroll give) and its last row sat right at the
        // very bottom edge instead of clearing the floating nav bar,
        // which is what made this one screen feel "stuck" compared to
        // the rest of Settings.
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              l10n.settingsLanguageSubtitle,
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13,
              ),
            ),
          ),
          // Search field — pointless friction for a 4-item list, genuinely
          // useful once there are 16+ languages in unfamiliar scripts;
          // this is the same reason Spotify/Apple Music both put a search
          // bar at the top of their language pickers instead of asking
          // someone to scroll and visually scan for their script.
          _LanguageSearchField(controller: _searchController),
          const SizedBox(height: 16),
          if (showSystemDefault) ...[
            AurumStaggerItem(
              index: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: AurumTheme.bgCardOf(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
                ),
                child: _LanguageRow(
                  flag: null,
                  fallbackIcon: Icons.smartphone_rounded,
                  label: l10n.settingsLanguageSystemDefault,
                  sublabel: null,
                  selected: currentCode == null,
                  loading: _switchingTo == 'system',
                  enabled: _switchingTo == null,
                  onTap: () => _select(null),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (matches.isEmpty)
            _NoResults(query: _searchController.text.trim())
          else
            AurumStaggerItem(
              index: showSystemDefault ? 1 : 0,
              child: Container(
                decoration: BoxDecoration(
                  color: AurumTheme.bgCardOf(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
                ),
                child: Column(
                  children: List.generate(matches.length, (i) {
                    final locale = matches[i];
                    final code = locale.languageCode;
                    final isLast = i == matches.length - 1;
                    return Column(
                      children: [
                        _LanguageRow(
                          flag: kLocaleFlags[code],
                          fallbackIcon: Icons.translate_rounded,
                          label: kLocaleDisplayNames[code] ?? code,
                          sublabel: kLocaleEnglishNames[code],
                          selected: currentCode == code,
                          loading: _switchingTo == code,
                          enabled: _switchingTo == null,
                          onTap: () => _select(locale),
                        ),
                        if (!isLast)
                          Divider(
                              color: AurumTheme.dividerOf(context),
                              height: 0.5,
                              indent: 68,
                              endIndent: 14),
                      ],
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rounded search field matching the app's other search surfaces — flat
/// fill, hairline border, leading search glyph, and a clear (×) button
/// that only appears once there's text to clear.
class _LanguageSearchField extends StatelessWidget {
  const _LanguageSearchField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AurumTheme.bgCardOf(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Icon(Icons.search_rounded, color: AurumTheme.textMutedOf(context), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 14.5),
              cursorColor: AurumTheme.accentOf(context),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: l10n.commonSearch,
                hintStyle: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 14.5),
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: AurumMotion.durationOrZero(AurumMotion.short2),
            transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
            child: controller.text.isEmpty
                ? const SizedBox(key: ValueKey('empty'), width: 14)
                : Padding(
                    key: const ValueKey('clear'),
                    padding: const EdgeInsets.only(right: 8),
                    child: AurumPressable(
                      onTap: () {
                        AurumHaptics.light();
                        controller.clear();
                      },
                      scaleAmount: 0.85,
                      child: Icon(Icons.close_rounded,
                          color: AurumTheme.textMutedOf(context), size: 18),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.travel_explore_rounded,
              color: AurumTheme.textMutedOf(context).withValues(alpha: 0.5), size: 32),
          const SizedBox(height: 12),
          Text(
            l10n.searchNoResultsFor(query),
            textAlign: TextAlign.center,
            style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.flag,
    required this.fallbackIcon,
    required this.label,
    required this.sublabel,
    required this.selected,
    required this.onTap,
    this.loading = false,
    this.enabled = true,
  });

  /// Real flag emoji (e.g. "🇮🇳") shown as the leading glyph. Null for
  /// the "System default" row, which has no single flag to represent it
  /// and instead falls back to [fallbackIcon].
  final String? flag;
  final IconData fallbackIcon;
  final String label;
  final String? sublabel;
  final bool selected;
  final VoidCallback onTap;
  final bool loading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: enabled ? onTap : () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            // Flag chip — a soft rounded square behind the emoji so every
            // row has a consistent leading footprint (flags come in
            // different natural aspect ratios; the container normalizes
            // that the same way Spotify/Apple Music badge their language
            // rows with a fixed-size leading glyph slot).
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context).withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(9),
              ),
              child: flag != null
                  ? Text(flag!, style: const TextStyle(fontSize: 18, height: 1.1))
                  : Icon(fallbackIcon, size: 17, color: AurumTheme.textMutedOf(context)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: enabled
                          ? AurumTheme.textPrimaryOf(context)
                          : AurumTheme.textMutedOf(context),
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: -0.1,
                    ),
                  ),
                  if (sublabel != null) ...[
                    const SizedBox(height: 1),
                    Text(
                      sublabel!,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: AurumMotion.durationOrZero(AurumMotion.short2),
              transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
              child: loading
                  ? const SizedBox(
                      key: ValueKey('loading'),
                      width: 20,
                      height: 20,
                      child: AurumMorphLoader(size: 20),
                    )
                  : selected
                      ? Icon(Icons.check_circle_rounded, key: const ValueKey('sel'), color: AurumTheme.accentOf(context), size: 22)
                      : Icon(Icons.circle_outlined,
                          key: const ValueKey('unsel'),
                          color: AurumTheme.textMutedOf(context).withValues(alpha: 0.4), size: 22),
            ),
          ],
        ),
      ),
    );
  }
}
