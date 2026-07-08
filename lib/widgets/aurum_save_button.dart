// =============================================================================
// FILE: lib/widgets/aurum_save_button.dart
// PROJECT: Aurum Music
// DESCRIPTION: Premium animated "Save" toggle button (bookmark icon), used on
//   AlbumScreen (and reusable anywhere similar save/follow affordances are
//   needed). Gives the tap a paid-app feel:
//   - Icon bounce-pop (scale 1 -> 1.3 -> 1) on every toggle, spring-out curve.
//   - A soft gold glow ring flashes outward and fades when saving (not when
//     un-saving) — a quick "confirmation" pulse rather than a static state
//     change.
//   - Border/icon color cross-fades between saved/unsaved instead of
//     snapping instantly.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/aurum_theme.dart';

class AurumSaveButton extends StatefulWidget {
  final bool saved;
  final VoidCallback onTap;
  final double size;

  const AurumSaveButton({
    super.key,
    required this.saved,
    required this.onTap,
    this.size = 44,
  });

  @override
  State<AurumSaveButton> createState() => _AurumSaveButtonState();
}

class _AurumSaveButtonState extends State<AurumSaveButton>
    with TickerProviderStateMixin {
  late final AnimationController _bounceCtrl;
  late final Animation<double> _bounce;

  late final AnimationController _glowCtrl;
  late final Animation<double> _glowRadius;
  late final Animation<double> _glowOpacity;

  @override
  void initState() {
    super.initState();
    _bounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _bounce = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.35)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 35),
      TweenSequenceItem(
          tween: Tween(begin: 1.35, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 65),
    ]).animate(_bounceCtrl);

    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _glowRadius = Tween<double>(begin: 0.4, end: 1.6).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeOut),
    );
    _glowOpacity = Tween<double>(begin: 0.55, end: 0.0).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _bounceCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    final willSave = !widget.saved;
    HapticFeedback.mediumImpact();
    _bounceCtrl.forward(from: 0);
    if (willSave) {
      _glowCtrl.forward(from: 0);
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.saved;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // Expanding glow ring — only visible for a moment right after
            // saving, reads as a little "confirmation pulse" rather than
            // a plain state flip.
            AnimatedBuilder(
              animation: _glowCtrl,
              builder: (context, _) {
                if (_glowOpacity.value <= 0.01) return const SizedBox.shrink();
                return Container(
                  width: widget.size * _glowRadius.value,
                  height: widget.size * _glowRadius.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AurumTheme.gold
                            .withOpacity(_glowOpacity.value),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                );
              },
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOut,
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: saved
                      ? AurumTheme.gold
                      : AurumTheme.textMutedOf(context).withOpacity(0.4),
                  width: saved ? 1.4 : 1.0,
                ),
              ),
              child: Center(
                child: AnimatedBuilder(
                  animation: _bounce,
                  builder: (context, child) => Transform.scale(
                    scale: _bounce.value,
                    child: child,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Icon(
                      saved
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded,
                      key: ValueKey(saved),
                      color: saved
                          ? AurumTheme.gold
                          : AurumTheme.textMutedOf(context),
                      size: widget.size * 0.5,
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
