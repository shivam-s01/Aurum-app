import 'dart:ui';
import 'package:flutter/material.dart';
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
    builder: (_) => const _FeedbackDialog(),
  );
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  int _rating = 0;
  final _controller = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _controller.dispose();
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

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: 28,
        // Keeps the dialog above the keyboard instead of being pushed
        // off-screen or clipped — without this, the TextField was
        // visually present but its tap/focus region ended up misaligned
        // once the keyboard inset changed the available height.
        vertical: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
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
            child: SingleChildScrollView(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _sent ? _buildThankYou(context) : _buildForm(context),
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
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                AurumTheme.gold.withValues(alpha: 0.9),
                AurumTheme.gold.withValues(alpha: 0.5),
              ],
            ),
          ),
          child: const Icon(Icons.auto_awesome_rounded,
              color: Colors.white, size: 26),
        ),
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
              onTap: () => setState(() => _rating = i + 1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
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
