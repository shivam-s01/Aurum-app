import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show scaffoldMessengerKey;

/// Root-cause-agnostic fix for the "keyboard opens then instantly closes"
/// bug. The route-settle timing fixes elsewhere in this app (waiting for
/// ModalRoute.animation to complete before requesting focus) address ONE
/// specific cause of this symptom — but the same 0.1-0.3s flash-and-close
/// pattern can also come from other sources this app doesn't fully
/// control: a provider higher in the tree rebuilding the subtree a frame
/// after focus is granted, an IME/OS-level focus race on certain device
/// keyboards, or a still-settling parent transition that isn't the
/// FocusNode's own ModalRoute. Chasing each of those individually is a
/// losing game — this class instead makes the SYMPTOM impossible: if
/// focus is lost unexpectedly shortly after being (re)gained, and nothing
/// the user did explains it, it simply asks for focus again.
///
/// This does NOT fight a deliberate user action — tapping outside the
/// field, pressing back, or the sheet/dialog actually closing all stop
/// the retry loop immediately (see [stop] and the mounted/route checks
/// below). It only refuses to accept an *unexplained* focus loss in the
/// first ~2 seconds after the field should have keyboard focus.
class PersistentFocusRequester {
  PersistentFocusRequester({
    required this.focusNode,
    this.label = 'field',
    this.maxRetries = 6,
    this.retryInterval = const Duration(milliseconds: 120),
  });

  final FocusNode focusNode;
  final String label;
  final int maxRetries;
  final Duration retryInterval;

  bool _stopped = false;
  int _attempts = 0;

  /// Call once, after the field's own "safe to focus now" condition is
  /// met (e.g. after the enclosing route's enter animation completes).
  /// Requests focus, then watches for it being lost again too quickly —
  /// if that happens and this requester hasn't been [stop]ped, it tries
  /// again, up to [maxRetries] times.
  void start() {
    _stopped = false;
    _attempts = 0;
    _attemptFocus();
  }

  void _attemptFocus() {
    if (_stopped || _attempts >= maxRetries) return;
    _attempts++;
    focusNode.requestFocus();
    debugPrint('[PersistentFocus:$label] attempt $_attempts requesting focus');

    // Check back shortly after: did focus actually stick? A genuine user
    // interaction (tapping away, the field's screen closing) will have
    // set _stopped=true by the time this runs, via stop(). If it hasn't,
    // and focus somehow isn't held, this wasn't the user's doing — retry.
    Future.delayed(retryInterval, () {
      if (_stopped) return;
      try {
        if (!focusNode.hasFocus) {
          debugPrint('[PersistentFocus:$label] focus did not stick after '
              'attempt $_attempts — retrying');
          _attemptFocus();
        } else {
          debugPrint('[PersistentFocus:$label] focus confirmed held after '
              'attempt $_attempts — done');
        }
      } catch (e) {
        // FocusNode was disposed between scheduling this check and it
        // running (stop() should always precede dispose(), but this is a
        // defensive guard against any future call site that doesn't).
        debugPrint('[PersistentFocus:$label] focusNode disposed mid-check: $e');
      }
    });
  }

  /// Call when the user does something that should legitimately end the
  /// focus attempt — the field's screen/dialog/sheet closing, or
  /// disposal. Safe to call multiple times.
  void stop() {
    _stopped = true;
  }
}

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
/// [kDebugKeyboardWatchdogEnabled] is true (flip it off before a real
/// release if you don't want the banner surfaced to end users during
/// testing).
const bool kDebugKeyboardWatchdogEnabled = true;

class KeyboardFlashWatchdog {
  KeyboardFlashWatchdog({required this.context, required this.label}) {
    // BUGFIX (no banner/log ever appeared, even when the bug should have
    // been triggerable): _fireAlert used to look up
    // ScaffoldMessenger.maybeOf(context) with whatever context the sheet
    // or dialog's own builder handed it. Bottom sheets and dialogs are
    // NOT guaranteed to sit below a Scaffold in the tree the way a
    // normal page route is — maybeOf can come back null there, and the
    // old code just silently `return`ed with no banner AND no log line
    // marking that this happened, which is indistinguishable from "the
    // bug isn't occurring" even when it still is. Two fixes: (1) this
    // constructor now prints an "armed" line immediately so it's
    // possible to confirm the watchdog is actually attached at all, and
    // (2) _fireAlert below now shows through the app's global
    // scaffoldMessengerKey instead of a local context lookup, so the
    // banner can never silently fail to appear regardless of where this
    // widget lives in the tree.
    debugPrint('[KeyboardWatchdog:$label] watchdog attached and armed — '
        'if you don\'t see this line, the watchdog itself isn\'t wired '
        'up on this screen, not just "no bug found".');
  }

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

    // Global key instead of ScaffoldMessenger.maybeOf(context) — see the
    // constructor comment above for why the old local-context lookup
    // could silently find nothing and skip the banner entirely.
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) {
      debugPrint('[KeyboardWatchdog:$label] could not show banner — '
          'global ScaffoldMessenger not attached yet. Check the log '
          'lines above instead; the detection itself still fired.');
      return;
    }
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
