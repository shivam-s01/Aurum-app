import 'package:flutter/material.dart';
import '../theme/aurum_theme.dart';

/// AurumSnack — a single shared entry point for every toast/snackbar in
/// the app, matching the behavior of Echo Nightly's own SnackBarHandler.
///
/// WHY THIS EXISTS:
/// Before this, 6 separate `_snack()` helpers existed across
/// song_tile.dart, full_player_screen.dart, mix_screen.dart, and
/// album_screen.dart — each hand-copied with small drift (one forgot to
/// set backgroundColor and fell back to Flutter's default Material
/// color instead of Astra's themed surface; signatures varied between
/// `_snack(msg)` and `_snack(context, msg)`). None of them talked to
/// each other, so two actions firing close together from different
/// screens had no shared queue.
///
/// Echo's SnackBarHandler (ui/common/SnackBarHandler.kt) solves this
/// with one app-wide queue: `messages` is deduped (`if
/// (!messages.contains(message)) messages.add(message)`) and only the
/// front of the queue is ever shown, advancing to the next distinct
/// message on dismiss. Recreating that here: ScaffoldMessenger already
/// queues sequentially on its own, so the piece that was actually
/// missing is the DEDUPE — without it, a fast double-tap on "Add to
/// Queue" queues the identical "Added to queue" message twice, showing
/// the same toast back-to-back where Echo would only show it once.
class AurumSnack {
  AurumSnack._();

  // Tracks the most recent message text and when it was shown, per
  // Messenger instance (keying by the ScaffoldMessengerState itself
  // means this naturally resets across different screens/navigators
  // rather than needing manual teardown).
  static final Map<ScaffoldMessengerState, (String, DateTime)> _lastShown = {};

  /// Show [message] via [context]'s ScaffoldMessenger, styled
  /// consistently with the app's elevated surface color. Identical text
  /// shown again within [dedupeWindow] is silently skipped — matching
  /// Echo's own dedupe — so a rapid double-tap never stacks the same
  /// toast twice.
  ///
  /// THEME FIX ("album save/unsave snackbar kabhi theme follow nahi
  /// karta, kisi bhi theme pe awkward lagta hai"): this used to only
  /// set `backgroundColor`, leaving `elevation`, `shape`, and — the
  /// actual bug — the message `Text`'s color/weight completely unset.
  /// With no app-wide SnackBarThemeData defined anywhere either,
  /// Flutter's SnackBar falls back to its own hardcoded Material
  /// defaults for everything else, which is a fixed dark scrim + white
  /// text baked in regardless of the active theme. On light mode that
  /// reads as a jarring dark bar that doesn't belong to the screen; on
  /// dark mode it can end up nearly the same tone as the surface behind
  /// it with washed-out contrast; and Material You dynamic theming
  /// never touched it at all since nothing here read from
  /// colorScheme. Now every visual property is pulled explicitly from
  /// AurumTheme so the toast matches whichever of light / dark /
  /// dynamic Material You is active, with a text color guaranteed to
  /// contrast against that same surface (bgElevatedOf/textPrimaryOf are
  /// already a matched pair everywhere else in the app).
  static void show(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
    Duration dedupeWindow = const Duration(milliseconds: 800),
  }) {
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final last = _lastShown[messenger];
    if (last != null &&
        last.$1 == message &&
        now.difference(last.$2) < dedupeWindow) {
      return;
    }
    _lastShown[messenger] = (message, now);

    final surface = AurumTheme.bgElevatedOf(context);
    final textColor = AurumTheme.textPrimaryOf(context);

    messenger.showSnackBar(SnackBar(
      content: Text(
        message,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      backgroundColor: surface,
      elevation: 6,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        // Faint themed border so the floating bar reads as a distinct
        // surface even when its color sits close to the scaffold
        // background behind it (e.g. bgElevated vs bg in light mode).
        side: BorderSide(color: AurumTheme.dividerOf(context), width: 0.6),
      ),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      duration: duration,
    ));
  }
}
