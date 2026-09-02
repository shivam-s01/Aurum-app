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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final localeProvider = context.watch<LocaleProvider>();
    final currentCode = localeProvider.locale?.languageCode;

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
          AurumStaggerItem(
            index: 0,
            child: Container(
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Column(
              children: [
                _LanguageRow(
                  label: l10n.settingsLanguageSystemDefault,
                  selected: currentCode == null,
                  loading: _switchingTo == 'system',
                  enabled: _switchingTo == null,
                  onTap: () => _select(null),
                ),
                Divider(color: AurumTheme.dividerOf(context), height: 0.5, indent: 14, endIndent: 14),
                ...List.generate(kSupportedLocales.length, (i) {
                  final locale = kSupportedLocales[i];
                  final isLast = i == kSupportedLocales.length - 1;
                  return Column(
                    children: [
                      _LanguageRow(
                        label: kLocaleDisplayNames[locale.languageCode] ?? locale.languageCode,
                        selected: currentCode == locale.languageCode,
                        loading: _switchingTo == locale.languageCode,
                        enabled: _switchingTo == null,
                        onTap: () => _select(locale),
                      ),
                      if (!isLast)
                        Divider(color: AurumTheme.dividerOf(context), height: 0.5, indent: 14, endIndent: 14),
                    ],
                  );
                }),
              ],
            ),
          ),
          ),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.label,
    required this.selected,
    required this.onTap,
    this.loading = false,
    this.enabled = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool loading;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: enabled ? onTap : () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? AurumTheme.textPrimaryOf(context)
                      : AurumTheme.textMutedOf(context),
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
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
                      ? Icon(Icons.check_circle_rounded, key: const ValueKey('sel'), color: AurumTheme.gold, size: 22)
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
