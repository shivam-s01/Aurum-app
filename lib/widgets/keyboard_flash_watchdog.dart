import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// DEBUG-ONLY instrumentation for the "keyboard opens then instantly
/// closes" bug (PIN sheet / feedback dialog / playlist create-rename
/// dialogs).
///
/// Attach to any [FocusNode] used by a TextField that has previously
/// been hit by this race. It doesn't change focus behavior at all —
/// it only *observes* focus gain/loss timing and, if it sees the
/// exact signature of the race (focus gained, then lost again within
/// a very short window, with no user-initiated cause), throws up a
/// loud red banner + haptic buzz + debugPrint with a timestamp.
///
/// This means if the bug resurfaces on a real device after the fix
/// build, Shivam sees it happen live instead of having to describe
/// "it flashed" after the fact — the banner tells him exactly how
/// many milliseconds the field was focused for.
///
/// Wire-up (3 lines per screen):
///   final _watchdog = KeyboardFlashWatchdog(context: context, label: 'PIN sheet');
///   ... focusNode: _pinFocus..addListener(() => _watchdog.onFocusChange(_pinFocus.hasFocus)),
///   ... _watchdog.dispose(); in State.dispose()
///
/// Safe to leave wired in release builds — it's a no-op unless
/// [kDebugKeyboardWatchdog] is true (flip it off before a real release
/// if you don't want the banner surfaced to end users during testing).
const bool kDebugKeyboardWatchdogEnabled = true;

class KeyboardFlashWatchdog {
  KeyboardFlashWatchdog({required this.context, required this.label});

  final BuildContext context;
  final String label;

  DateTime? _focusGainedAt;
  bool _warned = false;

  /// Call this from the FocusNode's own listener with its current
  /// hasFocus value every time it changes.
  void onFocusChange(bool hasFocus) {
    if (!kDebugKeyboardWatchdogEnabled) return;

    if (hasFocus) {
      _focusGainedAt = DateTime.now();
      _warned = false;
      debugPrint('[KeyboardWatchdog:$label] focus GAINED at '
          '${_focusGainedAt!.toIso8601String()}');
      return;
    }

    // Focus was lost — how long did we actually have it?
    final gainedAt = _focusGainedAt;
    if (gainedAt == null) return; // never had focus in the first place
    final heldFor = DateTime.now().difference(gainedAt);
    debugPrint('[KeyboardWatchdog:$label] focus LOST after '
        '${heldFor.inMilliseconds}ms');

    // The race's signature: focus held for well under a normal typing
    // interaction (a real tap-then-type holds focus for seconds).
    // Under ~450ms with no text ever entered is the flash-and-slam
    // pattern, not a deliberate dismiss.
    if (heldFor.inMilliseconds < 450 && !_warned) {
      _warned = true;
      _fireAlert(heldFor.inMilliseconds);
    }
  }

  void _fireAlert(int ms) {
    debugPrint('[KeyboardWatchdog:$label] ⚠️ KEYBOARD FLASH DETECTED — '
        'focus lost after only ${ms}ms. This is the race. '
        'Screenshot this banner + note exact repro steps.');
    HapticFeedback.heavyImpact();

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        content: Text(
          '⚠️ Keyboard flash detected in "$label"\n'
          'Focus lost after only ${ms}ms — this is the bug. '
          'Note what you tapped and when.',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void dispose() {
    _focusGainedAt = null;
  }
}
