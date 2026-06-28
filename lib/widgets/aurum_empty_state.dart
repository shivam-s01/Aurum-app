import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// AurumEmptyState — Premium empty-state widget
// • Gold icon inside a soft glowing ring, gentle breathe + float animation
// • Title + subtitle, optional action button
// • Used anywhere a list/grid has nothing to show: Library, Search, Liked,
//   Queue, Downloads, History, Playlists, etc.
//
// Usage:
//   AurumEmptyState(
//     icon: Icons.favorite_border_rounded,
//     title: 'No liked songs yet',
//     subtitle: 'Songs you like will show up here',
//   )
// ─────────────────────────────────────────────────────────────────────────────

class AurumEmptyState extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AurumEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<AurumEmptyState> createState() => _AurumEmptyStateState();
}

class _AurumEmptyStateState extends State<AurumEmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _breathe;
  late final Animation<double> _float;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);

    _breathe = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );

    _float = Tween<double>(begin: -6, end: 6).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                return Transform.translate(
                  offset: Offset(0, _float.value),
                  child: Transform.scale(
                    scale: _breathe.value,
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            AurumTheme.gold.withOpacity(0.16),
                            AurumTheme.gold.withOpacity(0.0),
                          ],
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AurumTheme.bgSurfaceOf(context),
                            border: Border.all(
                              color: AurumTheme.gold.withOpacity(0.35),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AurumTheme.gold.withOpacity(0.18),
                                blurRadius: 20,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Icon(
                            widget.icon,
                            color: AurumTheme.gold,
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
            if (widget.actionLabel != null && widget.onAction != null) ...[
              const SizedBox(height: 24),
              _EmptyStateAction(
                label: widget.actionLabel!,
                onTap: widget.onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyStateAction extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _EmptyStateAction({required this.label, required this.onTap});

  @override
  State<_EmptyStateAction> createState() => _EmptyStateActionState();
}

class _EmptyStateActionState extends State<_EmptyStateAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          decoration: BoxDecoration(
            gradient: AurumTheme.goldGradient,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AurumTheme.gold.withOpacity(0.3),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: AurumTheme.bgOf(context),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
