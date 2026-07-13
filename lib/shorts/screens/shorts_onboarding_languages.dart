import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/shorts_catalog.dart';
import '../widgets/shorts_chip.dart';
import 'shorts_onboarding_categories.dart';

/// Screen 2 of Shorts onboarding: pick up to 3 languages.
class ShortsLanguageScreen extends StatefulWidget {
  const ShortsLanguageScreen({super.key});

  @override
  State<ShortsLanguageScreen> createState() => _ShortsLanguageScreenState();
}

class _ShortsLanguageScreenState extends State<ShortsLanguageScreen> {
  final Set<String> _selected = {};

  void _toggle(String lang) {
    setState(() {
      if (_selected.contains(lang)) {
        _selected.remove(lang);
      } else {
        if (_selected.length >= ShortsCatalog.maxLanguageSelection) {
          HapticFeedback.heavyImpact();
          return;
        }
        _selected.add(lang);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final canContinue = _selected.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Choose Languages',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                    ),
                  ),
                  Text(
                    '${_selected.length}/${ShortsCatalog.maxLanguageSelection}',
                    style: TextStyle(
                      color: AurumTheme.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Pick up to 3 — we\'ll tailor your feed.',
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              ),
            ),
            const SizedBox(height: 32),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: ShortsCatalog.languages.map((lang) {
                    return ShortsChip(
                      label: lang,
                      selected: _selected.contains(lang),
                      onTap: () => _toggle(lang),
                    );
                  }).toList(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 32),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canContinue ? AurumTheme.gold : Colors.white10,
                    foregroundColor:
                        canContinue ? Colors.black : Colors.white30,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  onPressed: canContinue
                      ? () {
                          HapticFeedback.lightImpact();
                          Navigator.of(context).push(
                            PageRouteBuilder(
                              pageBuilder: (_, anim, __) =>
                                  ShortsCategoryScreen(
                                selectedLanguages: _selected.toList(),
                              ),
                              transitionsBuilder: (_, anim, __, child) =>
                                  FadeTransition(opacity: anim, child: child),
                              transitionDuration:
                                  const Duration(milliseconds: 260),
                            ),
                          );
                        }
                      : null,
                  child: const Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
