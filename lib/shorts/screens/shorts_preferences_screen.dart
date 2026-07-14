import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/shorts_catalog.dart';
import '../services/shorts_prefs.dart';
import '../widgets/shorts_chip.dart';

/// Lets the user change their Shorts language/category preferences
/// after onboarding — opened from the feed's "more" menu. Saving
/// pops back with `true` so the feed screen knows to rebuild with a
/// fresh controller (new preferences, cleared shown/skip state).
class ShortsPreferencesScreen extends StatefulWidget {
  const ShortsPreferencesScreen({super.key});

  @override
  State<ShortsPreferencesScreen> createState() =>
      _ShortsPreferencesScreenState();
}

class _ShortsPreferencesScreenState extends State<ShortsPreferencesScreen> {
  Set<String> _languages = {};
  Set<String> _categories = {};
  String _query = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final langs = await ShortsPrefs.getLanguages();
    final cats = await ShortsPrefs.getCategories();
    if (!mounted) return;
    setState(() {
      _languages = langs.toSet();
      _categories = cats.toSet();
      _loading = false;
    });
  }

  List<String> get _filteredCategories {
    if (_query.trim().isEmpty) return ShortsCatalog.categories.keys.toList();
    final q = _query.trim().toLowerCase();
    return ShortsCatalog.categories.keys
        .where((c) => c.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _save() async {
    if (_languages.isEmpty || _categories.isEmpty || _saving) return;
    setState(() => _saving = true);
    HapticFeedback.mediumImpact();
    await ShortsPrefs.setLanguages(_languages.toList());
    await ShortsPrefs.setCategories(_categories.toList());
    if (!mounted) return;
    Navigator.of(context).pop(true); // signal: preferences changed
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white38)),
      );
    }

    final canSave = _languages.isNotEmpty && _categories.isNotEmpty && !_saving;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 20),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  Text(
                    'Feed Preferences',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Languages',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.9),
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_languages.length}/${ShortsCatalog.maxLanguageSelection}',
                          style: TextStyle(
                            color: AurumTheme.gold,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 14,
                      children: ShortsCatalog.languages.map((lang) {
                        return ShortsChip(
                          label: lang,
                          selected: _languages.contains(lang),
                          onTap: () {
                            setState(() {
                              if (_languages.contains(lang)) {
                                _languages.remove(lang);
                              } else {
                                if (_languages.length >=
                                    ShortsCatalog.maxLanguageSelection) {
                                  HapticFeedback.heavyImpact();
                                  return;
                                }
                                _languages.add(lang);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'Categories',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.9),
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(22),
                        border:
                            Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14.5),
                        decoration: InputDecoration(
                          hintText: 'Search categories',
                          hintStyle:
                              TextStyle(color: Colors.white.withOpacity(0.4)),
                          prefixIcon: Icon(Icons.search,
                              color: Colors.white.withOpacity(0.4), size: 20),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 12,
                      runSpacing: 14,
                      children: _filteredCategories.map((cat) {
                        return ShortsChip(
                          label: cat,
                          selected: _categories.contains(cat),
                          onTap: () {
                            setState(() {
                              if (_categories.contains(cat)) {
                                _categories.remove(cat);
                              } else {
                                _categories.add(cat);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canSave ? AurumTheme.gold : Colors.white10,
                    foregroundColor:
                        canSave ? Colors.black : Colors.white30,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  onPressed: canSave ? _save : null,
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            valueColor:
                                AlwaysStoppedAnimation(Colors.black54),
                          ),
                        )
                      : const Text(
                          'Save & Refresh Feed',
                          style: TextStyle(
                            fontSize: 15.5,
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
