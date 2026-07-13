import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/shorts_catalog.dart';
import '../services/shorts_prefs.dart';
import '../widgets/shorts_chip.dart';
import 'shorts_feed_screen.dart';

/// Screen 3 of Shorts onboarding: search + multi-select categories.
/// Finish saves preferences and drops user straight into the feed.
class ShortsCategoryScreen extends StatefulWidget {
  final List<String> selectedLanguages;
  const ShortsCategoryScreen({super.key, required this.selectedLanguages});

  @override
  State<ShortsCategoryScreen> createState() => _ShortsCategoryScreenState();
}

class _ShortsCategoryScreenState extends State<ShortsCategoryScreen> {
  final Set<String> _selected = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  bool _saving = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    if (_query.trim().isEmpty) return ShortsCatalog.categories.keys.toList();
    final q = _query.trim().toLowerCase();
    return ShortsCatalog.categories.keys
        .where((c) => c.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _finish() async {
    if (_selected.isEmpty || _saving) return;
    setState(() => _saving = true);
    HapticFeedback.mediumImpact();

    await ShortsPrefs.setLanguages(widget.selectedLanguages);
    await ShortsPrefs.setCategories(_selected.toList());
    await ShortsPrefs.setOnboarded();

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, anim, __) => const ShortsFeedScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canFinish = _selected.isNotEmpty && !_saving;

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
                      'Choose Categories',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                    ),
                  ),
                  Text(
                    '${_selected.length}',
                    style: TextStyle(
                      color: AurumTheme.gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(23),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Colors.white, fontSize: 14.5),
                  decoration: InputDecoration(
                    hintText: 'Search categories',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                    prefixIcon: Icon(Icons.search,
                        color: Colors.white.withOpacity(0.4), size: 20),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: _filtered.map((cat) {
                    return ShortsChip(
                      label: cat,
                      selected: _selected.contains(cat),
                      onTap: () {
                        setState(() {
                          if (_selected.contains(cat)) {
                            _selected.remove(cat);
                          } else {
                            _selected.add(cat);
                          }
                        });
                      },
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
                        canFinish ? AurumTheme.gold : Colors.white10,
                    foregroundColor:
                        canFinish ? Colors.black : Colors.white30,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                    elevation: 0,
                  ),
                  onPressed: canFinish ? _finish : null,
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
                          'Finish',
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
