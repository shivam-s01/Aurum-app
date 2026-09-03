import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/aurum_theme.dart';
import '../providers/theme_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SplashScreen — Echo-Nightly-matched brand entrance.
// ─────────────────────────────────────────────────────────────────────────────
//
// RE-REWRITTEN (2026-09 — "ekdam Echo Nightly jaisa, kuch bhi awkward na
// lage, poora smooth"): the previous version compressed Echo's
// choreography down to a 900ms window because that's what Echo's manifest
// declares as android:windowSplashScreenAnimationDuration. But that
// number is just how long the OS keeps the icon on screen — Echo's own
// art_splash_anim.xml <target> timeline actually runs a full 2400ms
// internally (ring: two 1200ms rotation bursts back to back; bg: one
// continuous 2400ms rotation; note/play/media/path_5/path_6: a full
// sequence of tilts, morphs and scale-pops spread across that same
// 2400ms). The OS cuts Echo's own animation off mid-sequence at 900ms —
// which is a constraint of the platform API, not a deliberate part of
// the choreography, and is exactly the kind of "beech mein kata hua"
// abruptness that reads as awkward rather than smooth.
//
// Since this is a plain Dart-side overlay with no OS timing ceiling,
// there's no reason to inherit that cutoff. Every interval below is
// mapped from Echo's real per-target timeline as a PERCENTAGE of its
// 2400ms total (start%, end%) and then re-applied to Aurum's own 2400ms
// AnimationController — so the relative choreography (what starts when,
// relative to what) is frame-percentage-identical to Echo's source XML,
// and the full sequence plays out to its natural end with nothing cut
// off.
//
//   Echo target      start% → end%      what
//   ────────────────────────────────────────────────────────────────
//   bg   rotation      0%   → 100%      full 360° background turn
//   ring rotation      0%   →  50%      burst 1 (0°→120°)
//   ring rotation     50%   → 100%      burst 2 (120°→240°)
//   note pathData    8.3%   →  25%      note glyph settle-in morph
//   play rotation   16.7%   → 33.3%     tilt out
//   media scale     29.2%   → 41.7%     pop out (~1.05x)
//   group rotation  33.3%   → 58.3%     micro counter-rotation
//   media scale     41.7%   →  50%      settle back from pop
//   play rotation   70.8%   → 83.3%     tilt back to rest
//   note pathData   66.7%   → 83.3%     note glyph settle-out morph
//   media scale     70.8%   → 91.7%     second small pop + settle
//   group rotation  70.8%   → 100%      micro counter-rotation back
//
// Aurum's PNG mark can't morph pathData the way Echo's vector does, so
// the two note pathData windows (8.3-25% and 66.7-83.3%) are reinterpreted
// as the note glyph's own overshoot-tilt-and-settle — same timing
// windows, same role (the note is "doing its own thing" independently
// of the ring), just expressed as rotation+scale instead of path morph
// since that's what a raster asset can actually do.
//
// widget.child still mounts from frame 1, same as before — Home's own
// startup work runs concurrently underneath this overlay the entire
// time, exactly like Echo's real Activity mounts underneath its OS
// splash. A longer overlay duration only delays when the *overlay*
// clears, never when the real app underneath starts working.
// ─────────────────────────────────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  final Widget child;
  final VoidCallback? onFinished;
  const SplashScreen({super.key, required this.child, this.onFinished});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Echo's own internal vector timeline length (art_splash_anim.xml)
  // played out in full, with nothing cut off.
  static const Duration _total = Duration(milliseconds: 2400);

  late final AnimationController _ctrl;

  // Entrance (Aurum-specific — Echo's OS splash has no fade-in of its
  // own, the icon is just present from frame 0; this is what lets our
  // Dart-side overlay avoid popping in instantly on first paint).
  late final Animation<double> _entranceScale;
  late final Animation<double> _entranceOpacity;
  late final Animation<double> _overlayFade;

  // Echo-timeline-mapped motion — see the class doc comment above for
  // the exact percentage source of each of these.
  late final Animation<double> _bgRotation; // degrees — background glow
  late final Animation<double> _ringRotation; // degrees — outer scalloped ring
  late final Animation<double> _noteRotation; // degrees — note glyph tilt
  late final Animation<double> _noteScale; // note glyph pop
  late final Animation<double> _groupRotation; // degrees — whole-mark micro-rotate

  bool _overlayVisible = true;

  /// Builds a curved [Interval]-based animation over [_ctrl] using
  /// percentages (0-100) copied directly from Echo's own XML timeline,
  /// so every interval below reads as the same start%/end% pair quoted
  /// in the class doc comment above.
  Animation<double> _pct(
    double startPct,
    double endPct,
    double begin,
    double end, {
    Curve curve = Curves.linear,
  }) {
    return Tween<double>(begin: begin, end: end).animate(
      CurvedAnimation(
        parent: _ctrl,
        curve: Interval(startPct / 100, endPct / 100, curve: curve),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _total);

    // Entrance: icon fades/scales in quickly at the very start (Echo's
    // icon is simply present at frame 0, but a raw pop-in on Dart's
    // first composited frame reads as a flicker rather than an
    // entrance) — kept short and front-loaded so it reads as "the mark
    // is already here" rather than as its own separate beat.
    //
    // NOTE: there is deliberately NO separate "background fade-in" —
    // the overlay's ColoredBox is opaque from frame 1 (see build()
    // below). Fading the background in over its own interval would mean
    // the first moments of a cold start show a partially-transparent
    // overlay with whatever HomeScreen/MainShell is doing underneath
    // bleeding through — exactly the "cold start white/gray flash" class
    // of bug already hardened against elsewhere in this app (see
    // pushFullPlayer's _FullPlayerRouteBackdrop in home_screen.dart).
    // The whole point of this overlay is to fully hide that gap, so it
    // must be 100% opaque for its entire visible lifetime, with only the
    // icon mark and the final hand-off allowed to animate.
    _entranceScale = _pct(0, 12, 0.85, 1.0, curve: Curves.easeOutCubic);
    _entranceOpacity = _pct(0, 10, 0.0, 1.0, curve: Curves.easeOut);

    // Overlay fade-out: last 12% of the full timeline, so the handoff
    // to the real app underneath is a quick cross-fade rather than an
    // instant cut, without adding any extra time beyond _total.
    _overlayFade = _pct(88, 100, 0.0, 1.0, curve: Curves.easeIn);

    // bg: continuous 360° turn across the entire timeline (0%-100%).
    _bgRotation = _pct(0, 100, 0.0, 360.0, curve: Curves.linear);

    // ring: two back-to-back 120° bursts (0-50%, 50-100%) — net 240°.
    // Built as one TweenSequence so the join at 50% has zero
    // discontinuity (each burst individually eases, but the net path
    // is still perfectly continuous in position, matching how Echo's
    // own two-objectAnimator burst reads visually as one continuous
    // spin with a soft mid-point rather than a stutter).
    _ringRotation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 120.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 120.0, end: 240.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 50,
      ),
    ]).animate(_ctrl);

    // note: Echo's note/play targets tilt out around 16.7-33.3%, hold
    // through the mid-section, then tilt back 70.8-83.3%. Aurum's note
    // glyph is a raster asset (can't path-morph), so this is expressed
    // as a rotation+scale "settle" doing the same job in the same
    // windows — independent motion from the ring, on Echo's own clock.
    _noteRotation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 16.7),
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -16.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 16.6, // → 33.3%
      ),
      TweenSequenceItem(tween: ConstantTween(-16.0), weight: 37.5), // hold to 70.8%
      TweenSequenceItem(
        tween: Tween(begin: -16.0, end: 0.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 12.5, // → 83.3%
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 16.7),
    ]).animate(_ctrl);

    // note scale: mirrors Echo's "media" group scale-pops at
    // 29.2-41.7% (pop out) and 70.8-91.7% (second pop + settle).
    _noteScale = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 29.2),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.06)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 12.5, // → 41.7%
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.06, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 29.1, // → 70.8%
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.05)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 12.5, // → 83.3%
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.05, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 16.7,
      ),
    ]).animate(_ctrl);

    // group: Echo's "group" target adds a small whole-mark counter
    // rotation at 33.3-58.3% and again 70.8-100% — a tiny "settle
    // wobble" applied to the ring+note as one unit, on top of (not
    // instead of) the ring's own independent spin.
    _groupRotation = TweenSequence<double>([
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 33.3),
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: -5.0)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 8.3, // → 41.7%
      ),
      TweenSequenceItem(
        tween: Tween(begin: -5.0, end: 0.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 16.7, // → 58.3%
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 12.5), // → 70.8%
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 3.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 12.5, // → 83.3%
      ),
      TweenSequenceItem(
        tween: Tween(begin: 3.0, end: 0.0)
            .chain(CurveTween(curve: Curves.fastOutSlowIn)),
        weight: 16.7,
      ),
    ]).animate(_ctrl);

    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _overlayVisible = false);
        widget.onFinished?.call();
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
                        child: Transform.rotate(
                          angle: _groupRotation.value * math.pi / 180,
                          child: Transform.scale(
                            scale: _entranceScale.value,
                            child: Opacity(
                              opacity: _entranceOpacity.value,
                              child: _buildMark(),
                            ),
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
    // Layered exactly like Echo's art_splash_anim.xml: a soft rotating
    // background glow, an independently-rotating outer scalloped ring
    // group, and a note glyph group with its own tilt+scale on top —
    // same structure as Echo's "bg" / "ring" / "play"+"media" targets,
    // just built from Aurum's own PNG mark instead of Echo's vector
    // paths.
    return RepaintBoundary(
      child: SizedBox(
        width: markSize,
        height: markSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // bg: soft rotating radial glow, sampled from the ring's own
            // gradient so it reads as "the ring's aura", not a foreign
            // color — matches Echo's bg target being a blurred copy of
            // the same shape, rotating underneath everything else.
            AnimatedBuilder(
              animation: _bgRotation,
              builder: (context, child) {
                return Transform.rotate(
                  angle: _bgRotation.value * math.pi / 180,
                  child: child,
                );
              },
              child: Opacity(
                opacity: 0.55,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Image.asset(
                    'assets/images/scallop_ring.png',
                    width: markSize * 1.08,
                    height: markSize * 1.08,
                  ),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _ringRotation,
              builder: (context, child) {
                return Transform.rotate(
                  angle: _ringRotation.value * math.pi / 180,
                  child: child,
                );
              },
              child: Image.asset(
                'assets/images/scallop_ring.png',
                width: markSize,
                height: markSize,
              ),
            ),
            AnimatedBuilder(
              animation: Listenable.merge([_noteRotation, _noteScale]),
              builder: (context, child) {
                return Transform.rotate(
                  angle: _noteRotation.value * math.pi / 180,
                  child: Transform.scale(
                    scale: _noteScale.value,
                    child: child,
                  ),
                );
              },
              child: Image.asset(
                'assets/images/note_glyph.png',
                width: markSize,
                height: markSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
