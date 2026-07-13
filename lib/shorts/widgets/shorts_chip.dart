import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/aurum_theme.dart';

/// Premium pill-shaped selectable chip used across onboarding screens.
/// Subtle scale + color morph on select — no flashy motion.
class ShortsChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const ShortsChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: selected
              ? AurumTheme.gold.withOpacity(0.16)
              : Colors.white.withOpacity(0.04),
          border: Border.all(
            color: selected
                ? AurumTheme.gold
                : Colors.white.withOpacity(0.10),
            width: 1.2,
          ),
        ),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 220),
          style: TextStyle(
            color: selected ? AurumTheme.goldLight : Colors.white70,
            fontSize: 14.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
          child: Text(label),
        ),
      ),
    );
  }
}
