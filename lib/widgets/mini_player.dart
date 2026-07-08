import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_loader.dart';
import 'aurum_pressable.dart';
import '../screens/full_player_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MiniPlayer v3.0 — Fautune-style Premium (rewrite)
// • Swipe UP  → open FullPlayerScreen (smooth slide)
// • Swipe DOWN → stop music + dismiss with fade+scale out
// • Drag tracking: real-time translate + opacity + scale
// • Spring-settle back if drag cancelled
// • Gold progress bar, glassmorphism, haptics
//
// WHY THIS REWRITE EXISTS (v2.1 → v3.0):
//   v2.1 wrapped the whole capsule in `AnimatedSize`, so that when the
//   mini player needed to disappear (hero section visible on Home, or
//   swipe-to-dismiss), the RESERVED LAYOUT SPACE would shrink to zero
//   instead of leaving a blank gap in the Column.
//
//   The problem: `AnimatedSize` animates height 0 -> full (or full -> 0)
//   over real time. The capsule/bar inside has a HARD-CODED fixed height
//   (68 or 64). During every one of those height transitions, the fixed-
//   height child was being sliced by a shorter/taller *growing* clip
//   window — for a couple of frames you'd see a raw, arbitrarily-cut
//   band of the capsule's blurred edge/border, which read as a stray
//   white (light theme) or dark (dark theme) "patti" cutting across the
//   screen. This happened on: first mount, hero-visibility toggles while
//   scrolling Home, AND swipe-down-dismiss -> reappear — three different
//   triggers, all hitting the same structural flaw. Patching each
//   trigger individually (a `_skipSizeAnim` one-shot flag, postFrame
//   callbacks, generation counters) kept fixing one path while leaving
//   the others exposed, because the root cause was architectural: a
//   height animation wrapped around a fixed-height child.
//
//   THE FIX: there is no more height animation anywhere in this widget.
//   The mini player's slot in the Column is ALWAYS either the full fixed
//   height or complexly-absent (`SizedBox.shrink()`) — never mid-grow.
//   Visibility for hero-scroll is handled purely with `AnimatedOpacity` +
//   `AnimatedSlide` (transform-only, doesn't touch layout size, so there
//   is never a clip window to cut the capsule mid-frame). Swipe-down
//   dismiss uses the same fade+slide-away transform it already had via
//   `_settleCtrl`, and simply flips `_dismissed` at the END of that
//   animation, at which point the widget is already fully faded out —
//   so the transition FROM "faded out, zero height" TO "gone" is
//   visually a no-op, and the transition back is a plain instant
//   fade+slide-in (the existing `_entryCtrl`), never a height grow.
//
//   v3.1 FIX (glow-bleed while hero-hidden): the capsule's box-shadow
//   used to include a second, gold-tinted BoxShadow with a 12px blur
//   radius. AnimatedOpacity fades pixel alpha, but a wide-blur shadow
//   still paints (faintly, then more visibly during the entry/slide
//   transform) outside the capsule's own clipped bounds — which read as
//   a stray purple glow sitting exactly where the capsule reappears,
//   even while `heroVisible` was mid-transition. The gold BoxShadow has
//   been removed entirely; only a plain black drop-shadow remains, and
//   its blur radius stays inside the capsule's own margin so nothing
//   leaks above the intended card bounds.
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  /// Broadcasts the current mini-player style ('Capsule' / 'Compact Bar') so
  /// any live MiniPlayer instance updates INSTANTLY when the setting is
  /// changed in Settings → Appearance.
  static final ValueNotifier<String> styleNotifier =
      ValueNotifier<String>('Capsule');

  /// FIX — "background pill" left stuck visible bug: MainShell's
  /// bottomNavigationBar wraps [MiniPlayer] in a solid-color Container
  /// (so the nav bar + mini player read as one continuous card). That
  /// Container used to paint its background purely off `player.hasSong`,
  /// with no knowledge of THIS widget's own internal visibility state
  /// (swipe-down dismissed, or the split-second mid-rebuild gap during a
  /// theme change). Result: the rounded card-colored background kept
  /// painting even after the capsule content inside had already faded/
  /// animated itself away — exactly the stray background pill left after
  /// swipe-down, and the same mechanism behind the mini player fully
  /// vanishing (content gone, panel stays) on a theme switch.
  ///
  /// Single source of truth for "is the mini player actually showing real
  /// content right now" — true only when there is a song AND it isn't
  /// dismissed. MainShell listens to this instead of re-deriving hasSong
  /// itself, so the backing Container's background can never desync from
  /// what's actually painted inside it.
  static final ValueNotifier<bool> visibleNotifier = ValueNotifier<bool>(false);

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;
  bool _isDragging = false;
  bool _dismissed = false;
  String? _dismissedSongId; // track which song was dismissed

  // Debounces the "reappear because playback resumed" check below. Without
  // this, a single stale/transient read of player.isPlaying — which comes
  // from an async method-channel round trip to the native engine, not a
  // synchronous field — could read `true` for one build right after
  // _dismissPlayer() calls player.pause() (the real native pause hasn't
  // been confirmed back yet), causing the mini player to flash back in and
  // then immediately disappear again on the next state push. Spamming
  // swipe-down repeatedly makes this race far more likely to actually be
  // hit, since it forces exactly this pause-then-rebuild sequence over and
  // over in quick succession.
  Timer? _reappearDebounce;

  // Bumped every time a song-change entry/slide-in is scheduled, so that
  // if rapid skip-spam queues several postFrameCallbacks before the first
  // one runs, only the LAST scheduled one actually starts an animation —
  // the stale earlier ones no-op instead of each independently restarting
  // _entryCtrl/_slideInCtrl from 0, which under heavy spam could stack
  // redundant animation restarts and read as stutter.
  int _songChangeGen = 0;

  // ── Horizontal swipe (left/right) → prev/next song ──────────────────────
  double _dragX = 0;
  bool _isDraggingX = false;
  static const double _swipeXThreshold = 70.0;
  static const double _swipeXVelocityThreshold = 500.0;

  // Direction of the committed swipe: -1 = went to next (content exits left),
  // +1 = went to prev (content exits right).
  int _swipeDir = 0;

  late final AnimationController _swipeCtrl;
  Animation<double> _swipeAnim = const AlwaysStoppedAnimation(0.0);

  late final AnimationController _slideInCtrl;
  late Animation<double> _slideInAnim;

  // 'Capsule' = original floating glass pill. 'Compact Bar' = new premium
  // edge-to-edge bar style, selectable from Settings → Appearance.
  static const String prefsKeyMiniPlayerStyle = 'mini_player_style';
  String _style = 'Capsule';

  late final AnimationController _settleCtrl;
  late Animation<double> _settleAnim;

  // Entry animation — plays once when mini player first appears, on song
  // change, and whenever it reappears after being dismissed.
  late final AnimationController _entryCtrl;
  late final Animation<double> _entrySlide;
  late final Animation<double> _entryOpacity;
  late final Animation<double> _entryScale;
  String? _lastSongId;

  static const double _dismissThreshold = 80.0;
  static const double _openThreshold = -60.0;
  static const double _velocityThreshold = 400.0;

  @override
  void initState() {
    super.initState();
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _settleAnim = const AlwaysStoppedAnimation(0.0);

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _entrySlide = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutBack),
    );
    _entryOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entryCtrl,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );
    _entryScale = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _entryCtrl, curve: Curves.easeOutBack),
    );

    _swipeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );

    _slideInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _slideInAnim =
        CurvedAnimation(parent: _slideInCtrl, curve: Curves.easeOutCubic);

    _loadStyle();
    MiniPlayer.styleNotifier.addListener(_onStyleChanged);
  }

  void _onStyleChanged() {
    if (!mounted) return;
    final newStyle = MiniPlayer.styleNotifier.value;
    setState(() {
      _style = newStyle;
      // Compact Bar is always-visible/sticky and has no dismiss gesture
      // of its own — but if the user dismissed the mini player while on
      // Capsule and then switches the style setting to Compact Bar,
      // `_dismissed` would still be `true` left over from that gesture,
      // and Compact Bar would render nothing (SizedBox.shrink in build())
      // with no way to bring it back except playing a new song. Clear it
      // here so switching TO Compact Bar always guarantees "sticky and
      // visible whenever a song is loaded", per its own contract.
      //
      // Also guards a rarer but real case: switching style FROM Settings
      // while a Capsule drag/settle animation is still active (finger
      // still down, or mid spring-back/dismiss). Compact Bar has no drag
      // gestures at all, so any of that leftover state must be fully
      // cleared, not just _dragY, or a stale _isDragging/_settleCtrl could
      // affect the next Capsule session if the user switches back.
      if (newStyle == 'Compact Bar') {
        _settleGen++;
        _settleCtrl.stop();
        _settleCtrl.reset();
        _settleCtrl.duration = const Duration(milliseconds: 220);
        _dismissed = false;
        _dismissedSongId = null;
        _dragY = 0;
        _isDragging = false;
        _reappearDebounce?.cancel();
        _reappearDebounce = null;
      }
    });
  }

  Future<void> _loadStyle() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(prefsKeyMiniPlayerStyle) ?? 'Capsule';
    MiniPlayer.styleNotifier.value = saved;
    if (mounted) setState(() => _style = saved);
  }

  @override
  void dispose() {
    MiniPlayer.styleNotifier.removeListener(_onStyleChanged);
    _reappearDebounce?.cancel();
    _settleCtrl.dispose();
    _entryCtrl.dispose();
    _swipeCtrl.dispose();
    _slideInCtrl.dispose();
    // NOTE: deliberately NOT forcing `visibleNotifier.value = false` here.
    // visibleNotifier is `static` — shared by every MiniPlayer instance —
    // so if THIS instance is being torn down only because a replacement
    // MiniPlayer is mounting in the same frame (e.g. an ancestor rebuild
    // during a theme switch), forcing `false` here would stomp whatever
    // correct value the new instance's build() is about to set, and
    // MainShell's ValueListenableBuilder would flash/stick on "hidden"
    // even though a song is actively playing. Whichever MiniPlayer
    // instance is actually alive and building always keeps this notifier
    // correct on every build (see the unconditional sync in build()
    // above) — there is no scenario where dispose() forcing a value adds
    // correctness, only a scenario where it can introduce a race.
    super.dispose();
  }

  // Generation token — bumped every time a settle animation is started or
  // interrupted, so a stale completion callback from an interrupted
  // animation can never wrongly commit a pause/dismiss while the user is
  // actively dragging again.
  int _settleGen = 0;

  void _onDragStart(DragStartDetails _) {
    _settleGen++;
    _settleCtrl.stop();
    // A new drag can interrupt a dismiss animation mid-flight, whose
    // .whenComplete() (where duration normally gets restored) never
    // fires on .stop(). Restore it here too so an interrupted fast-flick
    // dismiss can never leave a short velocity-derived duration bleeding
    // into the next spring-back or dismiss animation.
    _settleCtrl.duration = const Duration(milliseconds: 220);
    setState(() {
      _isDragging = true;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragY += details.delta.dy;
      _dragY = _dragY.clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDragging = false);

    // Swipe UP → open full player immediately, snap drag offset back to 0
    // with no animation (navigating away).
    if (_dragY < _openThreshold || velocity < -_velocityThreshold) {
      HapticFeedback.mediumImpact();
      _settleGen++;
      _settleCtrl.stop();
      _settleCtrl.reset();
      setState(() => _dragY = 0);
      _openFullPlayer();
      return;
    }

    // Swipe DOWN → dismiss + stop
    if (_dragY > _dismissThreshold || velocity > _velocityThreshold) {
      HapticFeedback.heavyImpact();
      _dismissPlayer(releaseVelocity: velocity);
      return;
    }

    // Cancelled → spring back
    _springBack();
  }

  void _springBack() {
    _settleCtrl.stop();
    final gen = ++_settleGen;
    final from = _dragY;
    _settleAnim = Tween<double>(begin: from, end: 0.0).animate(
      CurvedAnimation(parent: _settleCtrl, curve: Curves.easeOutCubic),
    );
    _settleCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _settleGen) return;
      _settleCtrl.reset();
      setState(() => _dragY = 0);
    });
  }

  void _dismissPlayer({double releaseVelocity = 0}) {
    _settleCtrl.stop();
    final gen = ++_settleGen;
    final from = _dragY;
    // FIX — swipe-down dismiss didn't feel "premium clean": this used to
    // always run over a fixed 220ms (_settleCtrl's built-in duration)
    // regardless of how the gesture was released. A fast flick released
    // near the top still had to cover the FULL remaining distance to
    // 200.0 in the same 220ms as a slow drag released just past the
    // threshold near the bottom — the fast flick's motion visibly
    // stalled/snapped instead of continuing the throw, which is exactly
    // what reads as "not quite right" versus Apple Music/JioSaavn-style
    // dismiss gestures, where the exit speed matches how hard you threw
    // it.
    //
    // Fix: derive the animation duration from the actual distance left
    // to travel and the release velocity, the same way Flutter's own
    // fling simulations do it — clamped to a sensible premium range
    // (120ms floor so it's never jarring-fast, 260ms ceiling so a slow
    // threshold-cross still feels deliberate rather than sluggish).
    final remaining = (200.0 - from).abs();
    final speed = releaseVelocity.abs();
    final velocityMs = speed > 1
        ? (remaining / speed * 1000).clamp(120.0, 260.0)
        : 220.0;
    _settleCtrl.duration = Duration(milliseconds: velocityMs.round());
    // Animate fully off-screen + faded out FIRST. Only once that's fully
    // complete (widget is already invisible) do we flip `_dismissed` and
    // pause playback. This guarantees there is never a frame where the
    // widget goes from "mid-drag visible" straight to "gone" — it always
    // fades/slides out first, exactly like the hero-hide transition does.
    _settleAnim = Tween<double>(begin: from, end: 200.0).animate(
      CurvedAnimation(parent: _settleCtrl, curve: Curves.easeInCubic),
    );
    _settleCtrl.forward(from: 0.0).whenComplete(() {
      // Restore the default duration regardless of gen — this is a
      // controller-wide setting, not per-animation state, so it must
      // never be left on a one-off velocity-derived value that would
      // then wrongly apply to the next _springBack() call.
      _settleCtrl.duration = const Duration(milliseconds: 220);
      if (!mounted || gen != _settleGen) return;
      final player = context.read<PlayerProvider>();
      final songId = player.currentSong?.id;
      player.pause(); // pause only — keeps queue, so user can resume later
      _settleCtrl.reset();
      setState(() {
        _dismissed = true;
        _dismissedSongId = songId;
        _dragY = 0;
      });
    });
  }

  // Generation token for horizontal swipes — same pattern as _settleGen.
  int _swipeGen = 0;

  void _onDragStartX(DragStartDetails _) {
    _swipeGen++;
    _swipeCtrl.stop();
    setState(() => _isDraggingX = true);
  }

  void _onDragUpdateX(DragUpdateDetails details) {
    setState(() {
      _dragX += details.delta.dx;
      _dragX = _dragX.clamp(-160.0, 160.0);
    });
  }

  void _onDragEndX(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDraggingX = false);

    final commitNext =
        _dragX < -_swipeXThreshold || velocity < -_swipeXVelocityThreshold;
    final commitPrev =
        _dragX > _swipeXThreshold || velocity > _swipeXVelocityThreshold;

    if (commitNext) {
      HapticFeedback.mediumImpact();
      _commitSwipe(next: true);
      return;
    }
    if (commitPrev) {
      HapticFeedback.mediumImpact();
      _commitSwipe(next: false);
      return;
    }

    _springBackX();
  }

  void _springBackX() {
    _swipeCtrl.stop();
    final gen = ++_swipeGen;
    final from = _dragX;
    _swipeAnim = Tween<double>(begin: from, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _swipeGen) return;
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }

  void _commitSwipe({required bool next}) {
    _swipeCtrl.stop();
    final gen = ++_swipeGen;
    final from = _dragX;
    final exitTo = next ? -220.0 : 220.0;
    _swipeAnim = Tween<double>(begin: from, end: exitTo).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeInCubic),
    );
    _swipeDir = next ? -1 : 1;
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _swipeGen) return;
      final player = context.read<PlayerProvider>();
      if (next) {
        player.skipNext();
      } else {
        player.skipPrev();
      }
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }

  bool _opening = false; // guards against double-push from tap+swipe firing together

  void _openFullPlayer() {
    if (_opening) return;
    _opening = true;
    setState(() => _dragY = 0);
    HapticFeedback.lightImpact();
    Navigator.of(context)
        .push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        // Standardized to match every other entry point (Home, Search,
        // SongTile) — same slide-up + easeOutCubic, same 380ms. Previously
        // this was the only place using a plain fade, so opening the full
        // player felt different depending on whether you tapped the
        // mini-player or a song row — inconsistent motion reads as cheap.
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 300),
      ),
    )
        .then((_) {
      _opening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // PERF: was `Consumer<PlayerProvider>`, which rebuilds this entire
    // subtree (capsule, BackdropFilter blur, Hero, artwork, text) on
    // EVERY notifyListeners() call from PlayerProvider — including the
    // position tick that fires several times a second during playback.
    // The only fields this outer level actually branches on are hasSong /
    // currentSong.id / isPlaying / isLoading, all of which change rarely
    // (song change, play/pause, buffering). `Selector` rebuilds only when
    // that tuple changes; the live-updating progress value is read by a
    // separately-isolated widget further down (`_MiniProgressBar`) so it
    // repaints on its own without dragging the blur/artwork/text along.
    return Selector<PlayerProvider, (bool, String?, bool, bool)>(
      selector: (_, p) =>
          (p.hasSong, p.currentSong?.id, p.isPlaying, p.isLoading),
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        // Reset dismissed when a DIFFERENT song starts playing, OR when
        // playback resumes on the SAME song.
        //
        // FIX — "swipe down (once or repeatedly, fast), mini player
        // flashes back up then disappears again": player.isPlaying is
        // populated from an async method-channel event pushed by the
        // native engine, not a synchronous field. Right after
        // _dismissPlayer() calls player.pause(), there is a real window
        // (one or two Provider rebuilds) where the native pause hasn't
        // been confirmed back yet and player.isPlaying can still read
        // stale `true`. That single stale read used to be enough to flip
        // shouldReappear -> true, bringing the mini player back for a
        // frame before the real paused state arrived and hid it again.
        // Spamming the dismiss gesture repeatedly hits this window over
        // and over, since it's the exact same pause-then-rebuild sequence
        // every time. Debouncing the reappear by 250ms means a
        // transient/stale true (which flips back to false within a frame
        // or two) never survives long enough to trigger it, while a
        // genuine resume (isPlaying staying true) reappears cleanly after
        // a short, barely-noticeable delay.
        final sameSongResumed = _dismissed &&
            player.hasSong &&
            player.currentSong?.id == _dismissedSongId &&
            player.isPlaying;
        final differentSongStarted = _dismissed &&
            player.hasSong &&
            player.currentSong?.id != _dismissedSongId;

        if (differentSongStarted) {
          // Different song is unambiguous — no race possible here, since
          // it's keyed on song identity, not the async isPlaying flag.
          // Reappear immediately, no debounce needed.
          _reappearDebounce?.cancel();
          _reappearDebounce = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _dismissed = false;
                _dismissedSongId = null;
              });
            }
          });
        } else if (sameSongResumed) {
          _reappearDebounce ??= Timer(const Duration(milliseconds: 250), () {
            _reappearDebounce = null;
            if (!mounted) return;
            // Re-check at fire time — if isPlaying flipped back to false
            // (confirming it was transient/stale), don't reappear at all.
            final p = context.read<PlayerProvider>();
            if (_dismissed &&
                p.isPlaying &&
                p.currentSong?.id == _dismissedSongId) {
              setState(() {
                _dismissed = false;
                _dismissedSongId = null;
              });
            }
          });
        } else {
          // isPlaying dropped back to false (or song mismatch resolved)
          // before the debounce fired — cancel it so a stale timer can't
          // fire later and force a reappear based on outdated info.
          _reappearDebounce?.cancel();
          _reappearDebounce = null;
        }

        // No song, or currently dismissed → render NOTHING. There is no
        // height animation guarding this transition; the widget is simply
        // absent from the tree. Nothing here ever mid-animates a height,
        // so there is no clip window that can slice a fixed-height child.
        final showingNow = player.hasSong && !_dismissed;

        // FIX — mini player permanently vanishing / stuck-empty background
        // pill on: app backgrounding+resume, fast rapid song/source
        // switching, and theme changes.
        //
        // Why this must still be deferred (not set synchronously right
        // here): MiniPlayer is built INSIDE MainShell's
        // ValueListenableBuilder, which itself listens to this very
        // notifier. Setting `.value =` synchronously during this build()
        // would call that ValueListenableBuilder's setState() while it is
        // still on the call stack building its own subtree — Flutter
        // throws "setState() or markNeedsBuild() called during build" for
        // exactly this pattern. So a post-frame callback is required.
        //
        // Why the OLD post-frame implementation was still broken: it
        // captured `showingNow` from THIS build only, with no mounted
        // check, and guarded re-entrancy with a PER-INSTANCE generation
        // counter (`_visibilityGen`) — but `visibleNotifier` itself is
        // `static`, shared across every MiniPlayer instance. Any time
        // this widget's State was torn down and recreated (an ancestor
        // rebuild during a theme change, rapid navigation, etc.), the NEW
        // instance's counter restarted at 0 with zero knowledge of the
        // OLD instance's still-pending callback, so a stale callback from
        // a torn-down instance could still fire and flip the shared
        // notifier to a wrong value the new instance never asked for.
        // `dispose()` made this worse by unconditionally forcing
        // `visibleNotifier.value = false` with no check at all.
        //
        // THE FIX: don't trust anything captured back when the callback
        // was scheduled. Every single frame, unconditionally schedule a
        // post-frame callback that — only if this exact State is still
        // `mounted` at fire time — re-reads `PlayerProvider` and
        // `_dismissed` FRESH at that moment and writes that live truth to
        // the shared notifier. Scheduling every frame instead of only on
        // change is deliberate and cheap (post-frame callbacks are a
        // no-op if nothing is listening/changed): it means the mounted
        // instance is continuously the one true source keeping the
        // static notifier honest, and a torn-down instance's `mounted`
        // guard makes any of its in-flight callbacks permanently inert —
        // no generation bookkeeping required at all.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final freshShowingNow = context.read<PlayerProvider>().hasSong && !_dismissed;
          if (MiniPlayer.visibleNotifier.value != freshShowingNow) {
            MiniPlayer.visibleNotifier.value = freshShowingNow;
          }
        });
        if (!showingNow) {
          return const SizedBox.shrink();
        }

        // Trigger entry animation when song first appears, changes, or the
        // mini player reappears after a dismiss.
        final songId = player.currentSong?.id;
        if (songId != _lastSongId) {
          final isFirstSong = _lastSongId == null;
          _lastSongId = songId;
          // FIX — rapid skip-spam (next/prev tapped or swiped repeatedly,
          // fast) could queue several postFrameCallbacks here before the
          // first one actually runs, since this branch re-evaluates on
          // every Selector rebuild and each queued callback independently
          // called .forward(from: 0.0) on the SAME controller. Individually
          // harmless (forward(from:) always resets to a clean start), but
          // under heavy spam this stacks redundant restarts back-to-back
          // and can read as a stutter instead of one clean slide. The
          // generation token ensures only the LAST scheduled callback (the
          // one matching the song actually current when it fires) starts
          // the animation — every earlier, now-stale one no-ops.
          final gen = ++_songChangeGen;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || gen != _songChangeGen) return;
            if (isFirstSong) {
              _entryCtrl.forward(from: 0.0);
            } else {
              _slideInCtrl.forward(from: 0.0);
            }
          });
        }

        // FIX — mini player now ALWAYS shows whenever a song is playing,
        // regardless of whether the hero card is on-screen or not. The
        // heroVisibleNotifier gate that used to hide this widget while the
        // hero card was visible is removed entirely — no more
        // ValueListenableBuilder/SizedBox.shrink() swap tied to hero
        // visibility.
        return AnimatedBuilder(
          animation: _entryCtrl,
          builder: (_, child) {
            return Transform.translate(
              offset: Offset(0, _entrySlide.value * 80),
              child: Transform.scale(
                scale: _entryScale.value,
                alignment: Alignment.bottomCenter,
                child: Opacity(
                  opacity: _entryOpacity.value,
                  child: child,
                ),
              ),
            );
          },
          child: _buildInner(context, player),
        );
      },
    );
  }

  Widget _buildInner(BuildContext context, PlayerProvider player) {
    // FIX — Compact Bar should be a permanently-sticky JioSaavn-style bar:
    // no swipe-to-dismiss, no vertical drag feedback at all, only tap to
    // open the full player. It only ever disappears when there's no song
    // (handled one level up in build() via `showingNow`) — never via
    // _dismissed. Capsule keeps its full drag-to-dismiss/open behavior
    // unchanged.
    final isCompactBar = _style == 'Compact Bar';

    return AnimatedBuilder(
      animation: _settleCtrl,
      builder: (_, child) {
        // Compact Bar: never apply the drag-driven translate/scale/
        // opacity transform — _dragY can only ever be nonzero here if a
        // gesture briefly fired mid style-switch, and skipping the
        // transform entirely guarantees the bar stays pixel-locked in
        // place regardless, exactly like a native sticky bar.
        if (isCompactBar) return child!;

        final y = _settleCtrl.isAnimating ? _settleAnim.value : _dragY;
        final frac = (y.abs() / 160.0).clamp(0.0, 1.0);
        final op = (1.0 - frac * 0.6).clamp(0.0, 1.0);
        final sc = (1.0 - frac * 0.04).clamp(0.92, 1.0);

        return Transform.translate(
          offset: Offset(0, y.clamp(-60.0, 200.0)),
          child: Transform.scale(
            scale: sc,
            child: Opacity(
              opacity: op,
              child: child,
            ),
          ),
        );
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: AudioPrefs.swipeToChangeNotifier,
        builder: (context, swipeEnabled, _) {
          // Compact Bar: horizontal swipe (prev/next) still respected per
          // the user's existing swipe-to-change preference, but vertical
          // drag (open/dismiss) is fully disabled — tap is the only way
          // to open the full player, and there is no dismiss gesture at
          // all, matching the "always visible, sticky" requirement.
          return GestureDetector(
            onTap: _openFullPlayer,
            onVerticalDragStart: isCompactBar ? null : _onDragStart,
            onVerticalDragUpdate: isCompactBar ? null : _onDragUpdate,
            onVerticalDragEnd: isCompactBar ? null : _onDragEnd,
            onHorizontalDragStart: swipeEnabled ? _onDragStartX : null,
            onHorizontalDragUpdate: swipeEnabled ? _onDragUpdateX : null,
            onHorizontalDragEnd: swipeEnabled ? _onDragEndX : null,
            child: AnimatedBuilder(
              animation: Listenable.merge([_swipeCtrl, _slideInCtrl]),
              builder: (_, child) {
                final swipeX = _swipeCtrl.isAnimating ? _swipeAnim.value : _dragX;
                final swipeFrac = (swipeX.abs() / 160.0).clamp(0.0, 1.0);
                final swipeOpacity = (1.0 - swipeFrac * 0.7).clamp(0.0, 1.0);
                final swipeScale = (1.0 - swipeFrac * 0.06).clamp(0.9, 1.0);

                final slideInOffset = _slideInCtrl.isAnimating
                    ? (1.0 - _slideInAnim.value) * (_swipeDir * -140.0)
                    : 0.0;
                final slideInOpacity = _slideInCtrl.isAnimating
                    ? Curves.easeOut.transform(_slideInAnim.value)
                    : 1.0;

                final totalX = swipeX + slideInOffset;
                final totalOpacity = (swipeOpacity *
                        (_slideInCtrl.isAnimating ? slideInOpacity : 1.0))
                    .clamp(0.0, 1.0);

                return Transform.translate(
                  offset: Offset(totalX, 0),
                  child: Transform.scale(
                    scale: swipeScale,
                    child: Opacity(
                      opacity: totalOpacity,
                      child: child,
                    ),
                  ),
                );
              },
              child: _MiniPlayerContent(
                player: player,
                isDragging: _isDragging,
                dragY: _dragY,
                style: _style,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Content Widget
// ─────────────────────────────────────────────────────────────────────────────
class _MiniPlayerContent extends StatelessWidget {
  final PlayerProvider player;
  final bool isDragging;
  final double dragY;
  final String style;

  const _MiniPlayerContent({
    required this.player,
    required this.isDragging,
    required this.dragY,
    this.style = 'Capsule',
  });

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    // Guard against a race between the parent's hasSong check and a live
    // rebuild here (e.g. mid settle-animation) clearing the song in
    // between — render nothing instead of force-unwrapping, the parent's
    // hasSong guard hides this widget on the very next frame anyway.
    if (song == null) return const SizedBox.shrink();

    if (style == 'Compact Bar') {
      return _buildCompactBar(context, song);
    }
    return _buildCapsule(context, song);
  }

  Widget _buildCapsule(BuildContext context, dynamic song) {
    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    // FIX — capsule background/blur/border/shadow removed entirely per
    // request: the mini player now shows ONLY its raw content (artwork,
    // title/artist, controls) with no glass pill, no rounded box, no
    // BackdropFilter blur sitting behind it. Kept the fixed 68px height +
    // horizontal margin so tap targets and layout spacing stay unchanged;
    // everything that used to paint a visible "capsule" shape is gone.
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      height: 68,
      child: _miniPlayerCapsuleContent(context, song, showUpHint, showDownHint),
    );
  }

  Widget _miniPlayerCapsuleContent(
      BuildContext context, dynamic song, bool showUpHint, bool showDownHint) {
    return Stack(
      children: [
        // MainAxisSize.max: this Column contains an Expanded child, which
        // needs a bounded height from its parent to distribute space.
        // Inside a Stack (which gives non-positioned children loose
        // constraints sized to fill the stack), MainAxisSize.min here
        // would contradict Expanded and produce degenerate layout.
        Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              child: _MiniProgressBar(player: player),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Hero(
                      tag: 'aurum_artwork',
                      flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                          ScaleTransition(scale: anim, child: to.widget),
                      child: AurumArtwork(
                        url: song.artworkUrl,
                        size: 44,
                        borderRadius: 10,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            song.title,
                            style: TextStyle(
                              color: AurumTheme.textPrimaryOf(context),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist,
                            style: TextStyle(
                              color: AurumTheme.textSecondaryOf(context),
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ControlBtn(
                        icon: Icons.skip_previous_rounded,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          player.skipPrev();
                        },
                        size: 22,
                        context: context),
                    const SizedBox(width: 4),
                    _PlayBtn(player: player),
                    const SizedBox(width: 4),
                    _ControlBtn(
                        icon: Icons.skip_next_rounded,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          player.skipNext();
                        },
                        size: 22,
                        context: context),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (showUpHint || showDownHint)
          Positioned.fill(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: (dragY.abs() / 60.0).clamp(0.0, 0.85),
              child: Container(
                decoration: BoxDecoration(
                  color: showDownHint
                      ? Colors.red.withAlpha(30)
                      : Colors.white.withAlpha(10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Center(
                  child: Icon(
                    showDownHint
                        ? Icons.stop_circle_outlined
                        : Icons.keyboard_arrow_up_rounded,
                    color: showDownHint
                        ? Colors.red.withAlpha(180)
                        : Colors.white.withAlpha(150),
                    size: 28,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Compact Bar — premium edge-to-edge style (Settings → Appearance) ──
  Widget _buildCompactBar(BuildContext context, dynamic song) {
    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    // FIX — same background/blur/border/shadow removal as the Capsule
    // variant: only raw content now, no bar-shaped background behind it.
    return Container(
      height: 64,
      child: Stack(
                children: [
                  // Same reasoning as the Capsule variant above:
                  // MainAxisSize.max so the Expanded child gets a real
                  // bounded height from this Column.
                  Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      _MiniProgressBar(player: player),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(
                            children: [
                              Hero(
                                tag: 'aurum_artwork',
                                flightShuttleBuilder: (ctx, anim, dir, from, to) =>
                                    ScaleTransition(scale: anim, child: to.widget),
                                child: AurumArtwork(
                                  url: song.artworkUrl,
                                  size: 40,
                                  borderRadius: 8,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      song.title,
                                      style: TextStyle(
                                        color: AurumTheme.textPrimaryOf(context),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      song.artist,
                                      style: TextStyle(
                                        color: AurumTheme.textSecondaryOf(context),
                                        fontSize: 11,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              _ControlBtn(
                                  icon: Icons.skip_previous_rounded,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    player.skipPrev();
                                  },
                                  size: 20,
                                  context: context),
                              const SizedBox(width: 2),
                              _PlayBtn(player: player),
                              const SizedBox(width: 2),
                              _ControlBtn(
                                  icon: Icons.skip_next_rounded,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    player.skipNext();
                                  },
                                  size: 20,
                                  context: context),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (showUpHint || showDownHint)
                    Positioned.fill(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: (dragY.abs() / 60.0).clamp(0.0, 0.85),
                        child: Container(
                          color: showDownHint
                              ? Colors.red.withAlpha(30)
                              : Colors.white.withAlpha(10),
                          child: Center(
                            child: Icon(
                              showDownHint
                                  ? Icons.stop_circle_outlined
                                  : Icons.keyboard_arrow_up_rounded,
                              color: showDownHint
                                  ? Colors.red.withAlpha(180)
                                  : Colors.white.withAlpha(150),
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini Progress Bar — isolated so the position tick (fires several times a
// second during playback) only repaints this 2px strip, not the whole
// capsule (BackdropFilter blur, artwork, text) sitting around it.
// ─────────────────────────────────────────────────────────────────────────────
class _MiniProgressBar extends StatelessWidget {
  final PlayerProvider player;
  const _MiniProgressBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, double>(
      selector: (_, p) => p.progress,
      builder: (context, progress, _) => RepaintBoundary(
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.transparent,
          valueColor: const AlwaysStoppedAnimation<Color>(AurumTheme.gold),
          minHeight: 2,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Play Button
// ─────────────────────────────────────────────────────────────────────────────
class _PlayBtn extends StatelessWidget {
  final PlayerProvider player;
  const _PlayBtn({required this.player});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<ThemeProvider>().accentColor;
    if (player.isLoading) {
      return Opacity(
        opacity: 0.35,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(Icons.play_arrow_rounded, color: accent, size: 26),
        ),
      );
    }
    return AurumPressable(
      scaleAmount: 0.88,
      haptic: false,
      onTap: () {
        HapticFeedback.heavyImpact();
        player.togglePlay();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: accent.withAlpha(100),
              blurRadius: player.isPlaying ? 14 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey(player.isPlaying),
            color: AurumTheme.bg,
            size: 20,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control Button
// ─────────────────────────────────────────────────────────────────────────────
class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final BuildContext context;

  const _ControlBtn({
    required this.icon,
    required this.onTap,
    required this.context,
    this.size = 24,
  });

  @override
  Widget build(BuildContext ctx) {
    return AurumPressable(
      scaleAmount: 0.82,
      haptic: false,
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(
          icon,
          color: AurumTheme.textSecondaryOf(context),
          size: size,
        ),
      ),
    );
  }
}
