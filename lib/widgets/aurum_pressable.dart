// aurum_pressable.dart
// Aurum Music — Shared Press-Scale Interaction Wrapper
//
// Single source of truth for the "premium tap" feel used across the app:
// a quick scale-down on press-down, spring back on release, plus a light
// haptic tick. Replaces one-off GestureDetector/AnimationController
// boilerplate that was duplicated per-widget (home_screen's old
// _SongCardState, _PlaylistCardState, etc.) with one cheap, reusable
// implementation — same feel everywhere, less code, one less
// AnimationController per card at a time.
//
// Usage:
//   AurumPressable(
//     onTap: () => doSomething(),
//     child: MyCard(),
//   )
//
//   // Disable haptic (e.g. for very frequent taps like chip filters):
//   AurumPressable(onTap: ..., haptic: false, child: ...)
//
//   // Tighter/looser press feel:
//   AurumPressable(onTap: ..., scaleAmount: 0.94, child: ...)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AurumPressable extends StatefulWidget {
  const AurumPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleAmount = 0.97,
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale factor applied while pressed (1.0 = no shrink).
  final double scaleAmount;

  /// Whether to fire a light selection haptic on tap.
  final bool haptic;

  final HitTestBehavior behavior;

  @override
  State<AurumPressable> createState() => _AurumPressableState();
}

class _AurumPressableState extends State<AurumPressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _scale = Tween<double>(begin: 1.0, end: widget.scaleAmount).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut, reverseCurve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onTap != null) _ctrl.forward();
  }

  void _onTapUp(TapUpDetails _) => _ctrl.reverse();

  void _onTapCancel() => _ctrl.reverse();

  void _handleTap() {
    if (widget.onTap == null) return;
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      onTap: widget.onTap == null ? null : _handleTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}
