import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/feedback_service.dart';
import '../theme/aurum_theme.dart';

/// Shows the feedback dialog. Call this from either the auto-prompt
/// (after 1-2 songs) or from a manual "Send Feedback" entry in
/// Settings/About.
Future<void> showFeedbackDialog(BuildContext context) {
  return showDialog(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    // BUGFIX: "keyboard doesn't open, dialog vanishes in ~1s the moment
    // you tap the feedback text field". barrierDismissible defaults to
    // true, and when the keyboard rises it shrinks the available
    // viewport, which shifts/relayouts the dialog's content (the
    // AnimatedPadding below reacts to viewInsets.bottom mid-animation).
    // On Android in particular, a tap-down that starts on the TextField
    // can end up resolving as a tap-up over the barrier once that
    // relayout has shifted things by even a few pixels — and with the
    // barrier dismissible, Flutter reads that as "user tapped outside"
    // and pops the dialog before the keyboard even finishes rising.
    // There's already an explicit "Not now" button for dismissal, so
    // outside-tap-to-dismiss was never load-bearing UX here — disabling
    // it removes the race entirely.
    barrierDismissible: false,
    builder: (_) => const _FeedbackDialog(),
  );
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog>
    with SingleTickerProviderStateMixin {
  int _rating = 0;
  final _controller = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  // Drives the icon's entrance "bubble pop" (overshoot scale-in) and its
  // slow idle breathing glow once settled — the small bit of motion that
  // makes the mark feel alive/crafted rather than a static system icon.
  late final AnimationController _iconCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    _iconCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_rating == 0 || _sending) return;
    setState(() => _sending = true);

    String? version;
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {}

    // Fire the request but don't let network speed dictate the UX —
    // show the thank-you state after a minimum, pleasant delay either
    // way. The user never needs to know or care whether it succeeded
    // instantly or is still in flight.
    final sendFuture = FeedbackService.submit(
      rating: _rating,
      message: _controller.text,
      appVersion: version,
    );
    await Future.wait([
      sendFuture,
      Future.delayed(const Duration(milliseconds: 600)),
    ]);

    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = true;
    });

    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // BUGFIX: with only AnimatedPadding pushing content up for the
    // keyboard and no upper bound on the dialog's own height, a tall
    // keyboard (300px+) on a device with limited vertical space could
    // push the card's effective height past what's actually left on
    // screen — a silent overflow in release mode, which is what read as
    // "opens then vanishes/goes blank" rather than a clean resize.
    // Capping maxHeight against the keyboard-shrunk viewport (with the
    // dialog's own 24px vertical insetPadding accounted for) guarantees
    // the card can never ask for more room than actually exists, so
    // SingleChildScrollView below takes over instead of overflowing.
    final maxDialogHeight =
        MediaQuery.of(context).size.height - bottomInset - 48;

    return Dialog(
      backgroundColor: Colors.transparent,
      // FIX — previously this manually added viewInsets.bottom into the
      // insetPadding itself. Dialog already resizes/repositions for the
      // keyboard on its own; doubling up on the same inset shrank the
      // available height the moment the TextField requested focus, which
      // fought the keyboard animation and left it never actually opening
      // (the field looked focusable but the keyboard sheet never rose).
      // Plain fixed padding here — the AnimatedPadding below is what
      // now smoothly follows the keyboard.
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxDialogHeight > 0 ? maxDialogHeight : double.infinity,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              decoration: BoxDecoration(
                color: (isDark ? Colors.black : Colors.white)
                    .withValues(alpha: isDark ? 0.55 : 0.85),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.08),
                  width: 1,
                ),
              ),
              // Smoothly slides the whole card up as the keyboard rises,
              // instead of the old approach that tried to pre-shrink the
              // dialog's outer inset before the keyboard was even there.
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                  child: SingleChildScrollView(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _sent ? _buildThankYou(context) : _buildForm(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Column(
      key: const ValueKey('form'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _AurumBrandMark(controller: _iconCtrl),
        const SizedBox(height: 18),
        Text(
          'Enjoying Aurum?',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Your feedback helps us make it even better.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.color
                    ?.withValues(alpha: 0.65),
              ),
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (i) {
            final filled = i < _rating;
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _rating = i + 1);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TweenAnimationBuilder<double>(
                  key: ValueKey('star_$i${filled}'),
                  tween: Tween(begin: filled ? 1.3 : 1.0, end: 1.0),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.elasticOut,
                  builder: (context, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Icon(
                    filled ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 36,
                    color: filled
                        ? AurumTheme.gold
                        : Theme.of(context)
                            .iconTheme
                            .color
                            ?.withValues(alpha: 0.3),
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _controller,
          maxLines: 3,
          minLines: 2,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'Tell us what\'s on your mind (optional)',
            hintStyle: TextStyle(
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withValues(alpha: 0.4),
              fontSize: 13,
            ),
            filled: true,
            fillColor: (Theme.of(context).brightness == Brightness.dark
                    ? Colors.white
                    : Colors.black)
                .withValues(alpha: 0.05),
            contentPadding: const EdgeInsets.all(14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _rating == 0 || _sending ? null : _send,
            style: ElevatedButton.styleFrom(
              backgroundColor: AurumTheme.gold,
              disabledBackgroundColor:
                  AurumTheme.gold.withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 0,
            ),
            child: _sending
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Send Feedback',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: Colors.white,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: Text(
            'Not now',
            style: TextStyle(
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withValues(alpha: 0.55),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildThankYou(BuildContext context) {
    return Column(
      key: const ValueKey('thanks'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                AurumTheme.gold.withValues(alpha: 0.95),
                AurumTheme.gold.withValues(alpha: 0.6),
              ],
            ),
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 34),
        ),
        const SizedBox(height: 20),
        Text(
          'Thank you!',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your feedback means a lot to us —\nwe\'re always working to improve\nyour experience.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.color
                    ?.withValues(alpha: 0.7),
                height: 1.4,
              ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Aurum brand mark — the dialog's identity anchor.
//
// Replaces a generic Material sparkle icon with a mark that's clearly
// "Aurum" (a music note in the app's gold gradient) inside a disc, plus
// two bits of motion that separate a hand-tuned premium feel from a stock
// system dialog:
//
//  1. Entrance "bubble pop" — scales in with a soft overshoot (elasticOut)
//     the moment the dialog appears, like a bubble settling rather than
//     just fading in flat.
//  2. Idle breathing glow — once settled, a slow (2.4s) loop gently
//     pulses the soft outer glow behind the disc, so the mark reads as
//     alive rather than a static icon.
// ─────────────────────────────────────────────────────────────────────────────
class _AurumBrandMark extends StatefulWidget {
  final AnimationController controller;
  const _AurumBrandMark({required this.controller});

  @override
  State<_AurumBrandMark> createState() => _AurumBrandMarkState();
}

class _AurumBrandMarkState extends State<_AurumBrandMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pop = CurvedAnimation(
      parent: widget.controller,
      curve: Curves.elasticOut,
    );
    return AnimatedBuilder(
      animation: Listenable.merge([pop, _breathCtrl]),
      builder: (context, _) {
        final breath = 0.5 + (_breathCtrl.value * 0.5); // 0.5 → 1.0
        return Transform.scale(
          scale: pop.value,
          child: SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Soft breathing glow behind the disc.
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AurumTheme.gold
                            .withValues(alpha: 0.35 * breath),
                        blurRadius: 22,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
                // Main disc with the note mark.
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AurumTheme.goldLight,
                        AurumTheme.gold,
                        AurumTheme.goldDark,
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
