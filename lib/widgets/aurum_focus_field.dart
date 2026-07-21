import 'package:flutter/material.dart';

/// Wrap a [TextField] (or any focusable input) placed inside a
/// [showDialog] / [showModalBottomSheet] with this to have it request
/// keyboard focus safely, instead of using `autofocus: true` directly.
///
/// ── THE BUG THIS FIXES ──────────────────────────────────────────────
/// `autofocus: true` requests IME focus the instant the field first
/// builds. For a field inside a dialog or bottom sheet, that first build
/// happens DURING the enclosing route's own entrance transition
/// (DialogRoute's ~150ms fade/scale, or a bottom sheet's ~250ms slide-up).
/// Android can silently drop an IME focus request made while the window
/// is still mid-transition: the TextField ends up focused (blinking
/// cursor, focusedBorder shows) but the soft keyboard itself never rises.
///
/// An earlier version of this widget waited on the route's own
/// AnimationStatus.completed before requesting focus — that's the exact
/// mechanism that got stuck/never-fired in the older per-file fixes this
/// widget replaced, so it's removed entirely here. No animation status,
/// no listener, nothing that can get stuck waiting on a signal that never
/// comes. Instead: a short fixed delay (comfortably longer than any
/// dialog/sheet entrance transition in this app) and then a plain
/// requestFocus(). Simple, and nothing to get stuck on.
///
/// Usage — wrap only the field, keep everything else the same:
/// ```dart
/// AurumFocusField(
///   builder: (focusNode) => TextField(
///     controller: _controller,
///     focusNode: focusNode,
///     decoration: const InputDecoration(hintText: 'Name'),
///   ),
/// )
/// ```
///
/// For fields that need to move focus to a *different* field later (e.g.
/// a two-step PIN flow), pass [refocusSignal] — bump it (any new object,
/// e.g. flip a bool) whenever you want this widget to request focus again
/// immediately (no delay needed the second time — the dialog/sheet is
/// already fully on screen by then).
class AurumFocusField extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;
  final Object? refocusSignal;

  const AurumFocusField({
    super.key,
    required this.builder,
    this.refocusSignal,
  });

  @override
  State<AurumFocusField> createState() => _AurumFocusFieldState();
}

class _AurumFocusFieldState extends State<AurumFocusField> {
  final _focusNode = FocusNode();

  // Longer than any dialog/bottom-sheet entrance transition used in this
  // app (~150-250ms), so by the time this fires the route is guaranteed
  // to be fully settled and requesting focus behaves like a real tap.
  static const _settleDelay = Duration(milliseconds: 350);

  @override
  void initState() {
    super.initState();
    Future.delayed(_settleDelay, () {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(AurumFocusField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refocusSignal != oldWidget.refocusSignal) {
      // Dialog/sheet is already fully on screen by now — no delay needed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_focusNode);
}
