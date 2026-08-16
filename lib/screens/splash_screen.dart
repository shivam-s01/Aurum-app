import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/theme_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen — Echo-Nightly-matched brand entrance.
// ─────────────────────────────────────────────────────────────────────────────
//
// REWRITTEN (2026-08 — "cold start mein koi faltu layer/animation na rahe,
// Echo Nightly jaisa"): the previous version was a 2.7s, multi-stage
// sequence (entrance → 1.7s spin+glow → decel → glass-sweep → pulse →
// cross-fade handoff) that also DELAYED mounting the real app
// (widget.child / HomeScreen) until the whole thing finished, pushing
// actual time-to-interactive out past 2.7s on every single cold start.
//
// Echo Nightly's own splash — confirmed straight from its theme XML
// (values/themes.xml's android:windowSplashScreenAnimationDuration) — is
// exactly 900ms, and it's the OS's native Android 12+ Splash Screen API:
// the icon animates for 900ms while the real Activity/Fragments are
// ALREADY being constructed underneath it, so the OS splash and the
// app's own startup work run in parallel, not one after the other.
//
// Aurum can't use that same OS-level icon animation (windowSplashScreen
// AnimatedIcon is deliberately left unset in android/app/.../values-v31/
// styles.xml — several OEM skins draw the manifest icon on a light "icon
// card" that ignores requested colors when that property is set, a
// worse visual bug than having no icon there at all). So this Dart-side
// widget remains the actual branding moment — but now matches Echo's
// two defining properties instead of just borrowing its aesthetic:
//   1. ~900ms total (was 2700ms) — one clean entrance-and-settle, no
//      separate decorative stages after the mark has already appeared.
//   2. widget.child mounts immediately, in parallel underneath this
//      overlay, exactly like Echo's real Activity mounts underneath its
//      OS splash — Home's own initState/data-fetch work now starts on
//      frame 1 instead of waiting ~2.7s for an unrelated animation to
//      finish first.
// ─────────────────────────────────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Matches Echo's own windowSplashScreenAnimationDuration exactly.
  static const Duration _total = Duration(milliseconds: 900);

  late final AnimationController _ctrl;
  late final Animation<double> _markScale;
  late final Animation<double> _markOpacity;
  late final Animation<double> _overlayFade;

  bool _overlayVisible = true;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    // Entrance: icon fades/scales in over the first 55% of the timeline,
    // holds fully settled for the remainder. Overlay fade-out: last 30%
    // of the timeline, so the handoff to the real app is a quick
    // cross-fade rather than an instant cut, without adding any extra
    // time beyond the 900ms total.
    //
    // NOTE: there is deliberately NO separate "background fade-in" —
    // the overlay's ColoredBox is opaque from frame 1 (see build()
    // below). Fading the background in over its own interval would mean
    // the first ~270ms of a cold start shows a partially-transparent
    // overlay with whatever HomeScreen/MainShell is doing underneath
    // bleeding through — exactly the "cold start white/gray flash" class
    // of bug already hardened against elsewhere in this app (see
    // pushFullPlayer's _FullPlayerRouteBackdrop in home_screen.dart).
    // The whole point of this overlay is to fully hide that gap, so it
    // must be 100% opaque for its entire visible lifetime, with only the
    // icon mark and the final hand-off allowed to animate.
    _markScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
      ),
    );
    _markOpacity = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
    );
    _overlayFade = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.7, 1.0, curve: Curves.easeIn),
    );

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _overlayVisible = false);
      }
    });

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // FIX — "white layer on cold start, no matter which theme is selected"
  // (confirmed root cause): this used to read `AurumTheme.bgOf(context)`,
  // i.e. Theme.of(context).scaffoldBackgroundColor — the AMBIENT theme
  // MaterialApp has resolved for THIS frame. On a real cold start,
  // MaterialApp itself paints its very first frame(s) with Flutter's own
  // built-in fallback ThemeData (a plain white-ish ColorScheme.light())
  // before Consumer2<ThemeProvider,...> has run even once — because
  // ThemeProvider's constructor kicks off _load(), which awaits
  // SharedPreferences.getInstance() (a real async platform-channel call,
  // not instant). SplashScreen sits INSIDE that MaterialApp.home subtree,
  // so its very own initState/first build can land in that exact window —
  // reading Theme.of(context) at that moment returns Flutter's default
  // near-white background, completely independent of which Aurum theme
  // (dark/light/amoled/dynamic) the user actually has selected, since
  // ThemeProvider hasn't had a chance to apply it to the ambient Theme
  // yet. That's exactly why it showed "chahe koi bhi theme ho" — the bug
  // was never about which theme was chosen, it was that no real theme had
  // been applied to the ambient Theme yet on that first frame. Reading
  // ThemeProvider directly (via Consumer, below) sidesteps the ambient
  // Theme entirely: _mode defaults to AurumThemeMode.dark synchronously
  // at field-init time (see ThemeProvider._mode's declaration), before
  // _load() ever runs, so there is no unresolved/default-white window —
  // worst case for one frame it shows the dark bg instead of the user's
  // saved light/amoled choice, then corrects instantly once _load()
  // completes; it can never show Flutter's raw white fallback.
  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final bg = switch (themeProvider.mode) {
      AurumThemeMode.light => AurumTheme.lightBg,
      AurumThemeMode.amoled => AurumTheme.amoledBg,
      AurumThemeMode.dynamic =>
        (themeProvider.isDarkOf(context))
            ? (themeProvider.dynamicDark?.surface ?? AurumTheme.darkBg)
            : (themeProvider.dynamicLight?.surface ?? AurumTheme.lightBg),
      AurumThemeMode.system =>
        (themeProvider.isDarkOf(context)) ? AurumTheme.darkBg : AurumTheme.lightBg,
      AurumThemeMode.dark => AurumTheme.darkBg,
    };

    // widget.child is mounted from frame 1, same as Echo's real Activity
    // content being constructed underneath its OS splash — Home's own
    // startup work (cache hydration, network fetch, permission prompts)
    // now runs concurrently with this overlay instead of waiting for it.
    return Stack(
      children: [
        widget.child,
        if (_overlayVisible)
          RepaintBoundary(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  return Opacity(
                    opacity: 1.0 - _overlayFade.value,
                    child: ColoredBox(
                      color: bg,
                      child: Center(
                        child: Transform.scale(
                          scale: _markScale.value,
                          child: Opacity(
                            opacity: _markOpacity.value,
                            child: _buildMark(),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMark() {
    const double markSize = 132;
    return RepaintBoundary(
      child: SizedBox(
        width: markSize,
        height: markSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Image.asset(
              'assets/images/scallop_ring.png',
              width: markSize,
              height: markSize,
            ),
            Image.asset(
              'assets/images/note_glyph.png',
              width: markSize,
              height: markSize,
            ),
          ],
        ),
      ),
    );
  }
}

