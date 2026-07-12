import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/locale_provider.dart';
import '../widgets/aurum_pressable.dart';

class SettingsLanguageScreen extends StatelessWidget {
  const SettingsLanguageScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
        title: Text('Language',
            style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 18,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              'Choose your preferred app language',
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 13,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AurumTheme.dividerOf(context), width: 0.5),
            ),
            child: Column(
              children: [
                _LanguageRow(
                  label: 'System default',
                  selected: currentCode == null,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    context.read<LocaleProvider>().setLocale(null);
                  },
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
                        onTap: () {
                          HapticFeedback.selectionClick();
                          context.read<LocaleProvider>().setLocale(locale);
                        },
                      ),
                      if (!isLast)
                        Divider(color: AurumTheme.dividerOf(context), height: 0.5, indent: 14, endIndent: 14),
                    ],
                  );
                }),
              ],
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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded, color: AurumTheme.gold, size: 22)
            else
              Icon(Icons.circle_outlined,
                  color: AurumTheme.textMutedOf(context).withValues(alpha: 0.4), size: 22),
          ],
        ),
      ),
    );
  }
}
