import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';
import '../models/shorts_catalog.dart';

/// Chrome-tabs-style horizontal category switcher pinned to the top
/// of the Shorts feed. Exactly one category is active at a time —
/// tapping a different one triggers an immediate, full feed
/// replacement (see ShortsFeedScreen._switchCategory), never a blend.
///
/// Kept snappy/instant-feeling on purpose: no loading spinner inside
/// the bar itself, no debounce — tap registers instantly (haptic +
/// visual highlight swap), the underlying feed swap happens async
/// behind it while the old content stays visible until the new first
/// item is ready.
class ShortsCategoryToggleBar extends StatefulWidget {
  final String activeCategory;
  final ValueChanged<String> onCategoryChanged;

  const ShortsCategoryToggleBar({
    super.key,
    required this.activeCategory,
    required this.onCategoryChanged,
  });

  @override
  State<ShortsCategoryToggleBar> createState() =>
      _ShortsCategoryToggleBarState();
}

class _ShortsCategoryToggleBarState extends State<ShortsCategoryToggleBar> {
  late final ScrollController _scrollController;
  late final List<String> _categories;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _categories = ShortsCatalog.categories.keys.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
  }

  @override
  void didUpdateWidget(covariant ShortsCategoryToggleBar old) {
    super.didUpdateWidget(old);
    if (old.activeCategory != widget.activeCategory) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
  }

  void _scrollToActive() {
    if (!_scrollController.hasClients) return;
    final index = _categories.indexOf(widget.activeCategory);
    if (index <= 0) return;
    // Rough centering estimate — good enough for a snappy feel
    // without measuring exact chip widths.
    final target = (index * 92.0) - 60.0;
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isActive = category == widget.activeCategory;
          return GestureDetector(
            onTap: () {
              if (isActive) return;
              HapticFeedback.selectionClick();
              widget.onCategoryChanged(category);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: isActive
                    ? AurumTheme.gold.withOpacity(0.20)
                    : Colors.black.withOpacity(0.35),
                border: Border.all(
                  color:
                      isActive ? AurumTheme.gold : Colors.white.withOpacity(0.14),
                  width: 1.1,
                ),
              ),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: TextStyle(
                  color: isActive ? AurumTheme.goldLight : Colors.white70,
                  fontSize: 13.5,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                ),
                child: Text(category),
              ),
            ),
          );
        },
      ),
    );
  }
}
