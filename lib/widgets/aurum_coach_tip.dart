import 'dart:async';

import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/splash_screen.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_motion.dart';

// ═══════════════════════════════════════════════════════════════════════════
// AurumCoachTip — one-time, non-blocking hint under a button.
//
// Same look as the Library "import playlist" tip, packaged so any screen can
// reuse it. It is deliberately PATIENT: a hint must never fight another
// popup, so it waits for a calm moment instead of showing on a timer.
//   • shown ONCE per install — the flag is saved the moment it appears
//   • waits for the splash intro to be completely gone
//   • then waits until the screen has been calm for ~2.4s: app in the
//     foreground, this route on top (no dialog / sheet / permission prompt /
//     other screen), the button really painted, and [ready] true. On a brand
//     new install that means it appears AFTER the notification / storage /
//     autostart prompts are finished — and if the person never gets a calm
//     moment within 90s it simply skips WITHOUT being marked as seen, so it
//     tries again next launch
//   • no dimming, no blocking: a touch ANYWHERE removes it instantly and the
//     touch still reaches whatever was tapped
//   • auto-hides after 8s, and also hides by itself if anything covers the
//     button, the app goes to background, or the button moves
// ═══════════════════════════════════════════════════════════════════════════

class AurumCoachTip extends StatefulWidget {
  final Widget child;
  final String prefKey;
  final IconData icon;
  final String title;
  final String message;

  /// Evaluated on every calm-check. Return false to stop for good (without
  /// marking the tip as seen), e.g. when the user signed in.
  final bool Function() enabled;

  /// Optional async gate. While it returns false the tip keeps waiting
  /// (e.g. "first-launch permission prompts are not finished yet").
  final Future<bool> Function()? ready;

  const AurumCoachTip({
    super.key,
    required this.child,
    required this.prefKey,
    required this.icon,
    required this.title,
    required this.message,
    required this.enabled,
    this.ready,
  });

  @override
  State<AurumCoachTip> createState() => _AurumCoachTipState();
}

class _AurumCoachTipState extends State<AurumCoachTip> {
  static bool _showing = false; // never two tips at once
  static const _tick = Duration(milliseconds: 800);
  static const _calmTicksNeeded = 3;
  static const _maxWait = Duration(seconds: 90);
  static const _visibleFor = Duration(seconds: 8);

  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _watch;
  Rect? _shownRect;
  DateTime? _shownAt;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _waitForSplash() async {
    final n = SplashScreen.finishedNotifier;
    if (n.value) return;
    final c = Completer<void>();
    void l() {
      if (n.value && !c.isCompleted) c.complete();
    }

    n.addListener(l);
    try {
      await c.future.timeout(const Duration(seconds: 12));
    } catch (_) {
      // splash never reported — carry on, the calm-checks below still
      // protect us
    } finally {
      n.removeListener(l);
    }
  }

  /// The button's on-screen rect, but ONLY if it is genuinely visible and
  /// untouched-by-anything-else right now. Null = not a good moment.
  Rect? _visibleRect() {
    if (_disposed || !mounted) return null;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return null;

    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return null;

    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = MediaQuery.of(context).size;
    if (rect.top < 0 || rect.bottom > screen.height - 80) return null;
    if (rect.left < 0 || rect.right > screen.width) return null;

    // A hit-test at the button's centre only reaches it when it is painted
    // on the active tab and nothing (sheet, dialog, another tab) covers it.
    final hit = HitTestResult();
    WidgetsBinding.instance
        .hitTestInView(hit, rect.center, View.of(context).viewId);
    if (!hit.path.any((e) => identical(e.target, box))) return null;
    return rect;
  }

  bool _sameRect(Rect a, Rect b) =>
      (a.left - b.left).abs() < 1.5 && (a.top - b.top).abs() < 1.5;

  Future<void> _maybeShow() async {
    if (_showing) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(widget.prefKey) == true) return;
      if (_disposed || !mounted) return;

      await _waitForSplash();

      final deadline = DateTime.now().add(_maxWait);
      var calm = 0;
      Rect? last;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(_tick);
        if (_disposed || !mounted || _showing) return;
        if (!widget.enabled()) return;

        final gateOk = await (widget.ready?.call() ?? Future.value(true));
        if (_disposed || !mounted || _showing) return;

        final rect = gateOk ? _visibleRect() : null;
        if (rect == null || (last != null && !_sameRect(last, rect))) {
          calm = 0; // something is going on — start the calm window again
          last = rect;
          continue;
        }
        last = rect;
        if (++calm < _calmTicksNeeded) continue;

        // Calm for ~2.4s — show it.
        final overlay = Overlay.of(context);
        _showing = true;
        await prefs.setBool(widget.prefKey, true);
        if (_disposed || !mounted) {
          _showing = false;
          return;
        }
        _shownRect = rect;
        _shownAt = DateTime.now();
        _entry = OverlayEntry(
          builder: (ctx) => _CoachTipOverlay(
            anchor: rect,
            icon: widget.icon,
            title: widget.title,
            message: widget.message,
            onDismiss: _dismiss,
          ),
        );
        overlay.insert(_entry!);
        _watch = Timer.periodic(const Duration(milliseconds: 400), (_) {
          final r = _visibleRect();
          final age = DateTime.now().difference(_shownAt!);
          if (r == null || !_sameRect(r, _shownRect!) || age >= _visibleFor) {
            _dismiss();
          }
        });
        return;
      }
      // Never got a calm moment: give up quietly, NOT marked as seen.
    } catch (_) {
      // A tip is never worth an error — just skip it.
      _showing = false;
    }
  }

  void _dismiss() {
    _watch?.cancel();
    _watch = null;
    final e = _entry;
    _entry = null;
    if (e != null) {
      try {
        e.remove();
      } catch (_) {}
      _showing = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _anchorKey, child: widget.child);
}

class _CoachTipOverlay extends StatelessWidget {
  final Rect anchor;
  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onDismiss;

  const _CoachTipOverlay({
    required this.anchor,
    required this.icon,
    required this.title,
    required this.message,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    const cardW = 268.0;
    const margin = 16.0;
    final accent = AurumTheme.accentOf(context);
    final cx = anchor.center.dx;
    final left = (cx + cardW / 2 + margin > screen.width)
        ? screen.width - cardW - margin
        : (cx - cardW / 2).clamp(margin, screen.width);
    final arrowLeft = (cx - left - 7).clamp(18.0, cardW - 32);
    final top = anchor.bottom + 12;

    return Listener(
      // translucent: a touch anywhere removes the tip at once AND still
      // reaches the widget underneath — nothing ever gets blocked.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onDismiss(),
      child: Material(
        type: MaterialType.transparency,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration:
              AurumMotion.durationOrZero(const Duration(milliseconds: 320)),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
                offset: Offset(0, (1 - t) * 8), child: child),
          ),
          child: Stack(
            children: [
              // soft ring around the button
              Positioned(
                left: anchor.left - 4,
                top: anchor.top - 4,
                width: anchor.width + 8,
                height: anchor.height + 8,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: accent.withOpacity(0.55), width: 2),
                      boxShadow: [
                        BoxShadow(
                            color: accent.withOpacity(0.28), blurRadius: 14),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: left.toDouble(),
                top: top,
                width: cardW,
                child: IgnorePointer(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          color: AurumTheme.bgCardOf(context),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: accent.withOpacity(0.28)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.22),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: accent.withOpacity(0.16),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(icon, color: accent, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title,
                                      style: TextStyle(
                                          color:
                                              AurumTheme.textPrimaryOf(context),
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w800)),
                                  const SizedBox(height: 2),
                                  Text(message,
                                      style: TextStyle(
                                          color:
                                              AurumTheme.textMutedOf(context),
                                          fontSize: 12.5,
                                          height: 1.3)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        left: arrowLeft.toDouble(),
                        top: 0,
                        child: Transform.rotate(
                          angle: 0.785398,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: AurumTheme.bgCardOf(context),
                              border: Border(
                                top: BorderSide(
                                    color: accent.withOpacity(0.28)),
                                left: BorderSide(
                                    color: accent.withOpacity(0.28)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
