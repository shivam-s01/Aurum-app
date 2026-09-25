// =============================================================================
// FILE: lib/screens/splash_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Cold-start intro animation — renders the exact validated
//   web preview (assets/splash/aurum_splash_final.html) inside a WebView,
//   shown once, immediately after the native OS splash hands off to
//   Flutter's first frame, before MainShell/AppLockScreen/OnboardingGate.
//
//   WHY A WEBVIEW INSTEAD OF A DART/CANVAS REBUILD: an earlier version of
//   this file re-implemented the preview's CSS/SVG animation by hand in
//   Dart (CustomPainter + AnimationController). That approximation was
//   close but not pixel/timing-identical — browser SVG text layout and
//   Flutter's Skia text layout don't shape glyphs identically, and hand
//   -porting every keyframe is error-prone. Loading the actual validated
//   HTML file guarantees the on-device animation is the same file the
//   preview was approved from — no re-implementation drift possible.
//
//   WHY THIS EXISTS / HISTORY: main.dart previously carried a Dart-side
//   splash (`_SplashOnEveryEntry`) that was removed because it played
//   AFTER the native OS splash finished, as a fully separate animation —
//   producing a visible restart/discontinuity. That is the exact
//   "awkward" complaint this file exists to fix properly: NOT by removing
//   the animation, but by making the native splash a true zero-length
//   handoff (already the case — see styles.xml's
//   windowSplashScreenAnimationDuration="0" and MainActivity.kt's
//   installSplashScreen() comment) so this widget is the ONLY animation
//   the user ever sees, starting the instant Flutter's first frame paints.
//   One continuous animation, no restart, no gap.
//
// WIRING:
//   - main.dart's MaterialApp.home wraps its existing subtree with this
//     widget: SplashScreen(child: _BlurShaderWarmup(child: AppLockScreen(...))).
//   - Shown ONLY on a true cold start (static _played flag on the State's
//     class, same survives-hot-reload/background-resume reasoning the old
//     _SplashOnEveryEntry doc comment used) — Home button / recents
//     reopen skips straight to `child` with zero delay or flicker.
//   - Respects AudioPrefs.enableAnimationsNotifier: when the user has
//     turned off animations app-wide, this skips straight to `child` with
//     no motion at all, consistent with every other AurumMotion-gated
//     animation in the app.
//   - Uses AurumTheme.darkBg as the Flutter-side background, and the
//     bundled HTML's own --bg-dark variable has been set to the same
//     hex (#13121C) so there is no color flash at the WebView-paints-in
//     moment or at the final crossfade.
//   - The HTML posts a 'done' message via the `AurumSplash` JavaScript
//     channel once its own animation timeline has finished settling;
//     this widget listens for that message and only then starts its own
//     smooth Flutter-side opacity fade into `child` — so the WebView
//     content is never hard-cut, it dissolves.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../theme/aurum_theme.dart';
import '../services/audio_prefs.dart';

class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Survives hot-reload and background/foreground cycles for the Dart
  // VM's lifetime — same pattern the old _SplashOnEveryEntry doc comment
  // used. Only a genuine force-close + relaunch resets the process and
  // clears this, giving a fresh cold-start animation next time.
  static bool _played = false;

  bool _showSplash = false;
  late final WebViewController _webController;
  late final AnimationController _fadeController;
  bool _controllerCreated = false;

  // Purely-visual crossfade once the HTML reports it's done: the WebView
  // fades its own opacity down to 0 while `child` is already painting
  // underneath it, so the transition reads as one continuous dissolve —
  // never a hard setState cut ("bump").
  static const _fadeOutDuration = Duration(milliseconds: 420);

  // Safety fallback only: if the WebView somehow never fires its 'done'
  // message (asset failed to load, JS error, extremely slow device),
  // this guarantees the splash can never softlock the app open. Set
  // comfortably longer than the HTML's own ~2.6s timeline.
  static const _hardTimeout = Duration(milliseconds: 6000);

  @override
  void initState() {
    super.initState();
    if (_played || !AudioPrefs.enableAnimationsNotifier.value) {
      _played = true;
      return;
    }
    _showSplash = true;
    _played = true;
    _controllerCreated = true;

    _fadeController = AnimationController(
      vsync: this,
      duration: _fadeOutDuration,
    );

    _webController = WebViewController()
      // FIX (black gap before animation starts): the surrounding
      // Container already paints AurumTheme.darkBg immediately, but the
      // WebView's own native surface briefly shows plain black while it
      // attaches and the HTML asset is read/parsed — setBackgroundColor
      // here makes that surface start out matching the same dark color
      // instead of default black, so the handoff reads as one continuous
      // dark screen rather than a black flash before the animation.
      ..setBackgroundColor(AurumTheme.darkBg)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'AurumSplash',
        onMessageReceived: (message) => _finish(),
      )
      ..loadFlutterAsset('assets/splash/aurum_splash_final.html');

    // Hard fallback in case the JS 'done' message never arrives.
    Future.delayed(_hardTimeout, _finish);
  }

  void _finish() {
    if (!mounted || !_showSplash) return;
    // Guard against double-invocation (JS message + timeout racing).
    if (_fadeController.status == AnimationStatus.forward ||
        _fadeController.status == AnimationStatus.completed) {
      return;
    }
    _fadeController.forward().whenComplete(() {
      if (!mounted) return;
      // FIX ("bump" on reaching home): the fade-out finishing does not
      // guarantee `child` (MainShell/Home) has actually painted a real,
      // settled frame underneath yet — its first frame can still be a
      // loading/skeleton state mid-flight, so cutting straight to
      // `_showSplash = false` here could reveal that half-built frame,
      // reading as a jarring "bump". Waiting for two post-frame callbacks
      // (one full extra rendered frame of `child` alone, underneath the
      // now-fully-transparent splash) gives `child` a real chance to
      // settle before we remove the splash layer entirely.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _showSplash = false);
        });
      });
    });
  }

  @override
  void dispose() {
    if (_controllerCreated) {
      _fadeController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showSplash) return widget.child;
    return Stack(
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _fadeController,
          builder: (context, _) {
            return Opacity(
              opacity: 1.0 - _fadeController.value,
              child: IgnorePointer(
                child: Container(
                  color: AurumTheme.darkBg,
                  width: double.infinity,
                  height: double.infinity,
                  child: WebViewWidget(controller: _webController),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
