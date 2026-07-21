import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wrap a [TextField] (or any focusable input) placed inside a
/// [showDialog] / [showModalBottomSheet] with this to have it request
/// keyboard focus safely, instead of using `autofocus: true` directly.
///
/// ── THE BUG THIS FIXES (root cause, corrected) ──────────────────────
/// `autofocus: true` / a bare `FocusNode.requestFocus()` requests IME
/// focus on the Flutter side. That is NOT the same thing as the Android
/// soft keyboard actually rising. If the request happens while the
/// enclosing route (DialogRoute fade/scale, bottom sheet slide-up) is
/// still mid-transition, Android can silently attach the input
/// connection without ever showing the keyboard: the TextField ends up
/// looking focused (blinking cursor, focusedBorder shows) but no
/// keyboard appears. This is exactly what earlier fix attempts kept
/// running into.
///
/// A previous version of this widget tried to paper over that with a
/// fixed `Future.delayed(350ms)` guess before calling requestFocus().
/// That is unreliable on slower devices/OEM skins (the transition can
/// simply take longer than 350ms on a loaded device), and even when the
/// timing IS right, a bare requestFocus() can still fail to surface the
/// keyboard because Flutter's focus state and the platform's IME
/// visibility are two separate things that can desync.
///
/// This version fixes both problems:
///  1. Timing: instead of guessing a delay, we wait for the actual
///     enclosing route's transition to finish (if one exists) via
///     ModalRoute.of(context)!.animation, then request focus on the
///     next frame. No blind delay, no guessing.
///  2. Reliability: after requesting focus, we explicitly invoke the
///     `TextInput.show` platform channel method. This directly tells
///     Android to raise the soft keyboard, instead of relying on it to
///     infer that from the focus change alone — which is the actual gap
///     that let the "focused but keyboard never rises" bug happen.
///  3. Safety net: if the field still doesn't have focus ~400ms later
///     (edge cases: no enclosing animated route, rebuild raced us), we
///     retry once more. This never loops indefinitely.
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
  bool _didInitialFocus = false;

  @override
  void initState() {
    super.initState();
    // Wait one frame so we have a BuildContext attached to the tree with
    // a ModalRoute available, then hook into that route's transition.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleInitialFocus());
  }

  void _scheduleInitialFocus() {
    if (!mounted || _didInitialFocus) return;
    final route = ModalRoute.of(context);
    final animation = route?.animation;

    if (animation == null || animation.status == AnimationStatus.completed) {
      // No animated enclosing route (or it's already settled) — safe to
      // focus right away.
      _requestFocusAndShowKeyboard();
      return;
    }

    void onStatusChange(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        animation.removeStatusListener(onStatusChange);
        _requestFocusAndShowKeyboard();
      }
    }

    animation.addStatusListener(onStatusChange);

    // Safety net: if for any reason the route never reports "completed"
    // (edge cases with custom transitions), don't wait forever.
    Future.delayed(const Duration(milliseconds: 500), () {
      animation.removeStatusListener(onStatusChange);
      if (mounted && !_didInitialFocus) _requestFocusAndShowKeyboard();
    });
  }

  void _requestFocusAndShowKeyboard() {
    if (!mounted) return;
    _didInitialFocus = true;
    _focusNode.requestFocus();
    // THE ACTUAL FIX: explicitly tell the platform to raise the soft
    // keyboard. Flutter focus state alone doesn't guarantee this on
    // Android when the request lands right as a route settles — this
    // direct channel call is what makes it reliable.
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');

    // One retry safety net: if something (a rebuild, a race with the
    // route) caused the focus to not stick, try one more time shortly
    // after. This fires at most once and never loops.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted && !_focusNode.hasFocus) {
        _focusNode.requestFocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      }
    });
  }

  @override
  void didUpdateWidget(AurumFocusField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refocusSignal != oldWidget.refocusSignal) {
      // Dialog/sheet is already fully on screen by now — no need to wait
      // on any route transition, just do it next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
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
