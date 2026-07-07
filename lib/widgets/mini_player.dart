import 'dart:ui';
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

  /// When home screen's hero card is visible, mini player hides.
  /// Home screen updates this via scroll while it is the ACTIVE tab.
  /// MainShell resets this to `false` whenever the active tab isn't Home.
  static final ValueNotifier<bool> heroVisibleNotifier =
      ValueNotifier<bool>(false);

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  double _dragY = 0;
  bool _isDragging = false;
  bool _dismissed = false;
  String? _dismissedSongId; // track which song was dismissed

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
    MiniPlayer.heroVisibleNotifier.addListener(_onHeroVisibilityChanged);
  }

  void _onHeroVisibilityChanged() {
    if (mounted) setState(() {});
  }

  void _onStyleChanged() {
    if (mounted) setState(() => _style = MiniPlayer.styleNotifier.value);
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
    MiniPlayer.heroVisibleNotifier.removeListener(_onHeroVisibilityChanged);
    _settleCtrl.dispose();
    _entryCtrl.dispose();
    _swipeCtrl.dispose();
    _slideInCtrl.dispose();
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
      _dismissPlayer();
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

  void _dismissPlayer() {
    _settleCtrl.stop();
    final gen = ++_settleGen;
    final from = _dragY;
    // Animate fully off-screen + faded out FIRST. Only once that's fully
    // complete (widget is already invisible) do we flip `_dismissed` and
    // pause playback. This guarantees there is never a frame where the
    // widget goes from "mid-drag visible" straight to "gone" — it always
    // fades/slides out first, exactly like the hero-hide transition does.
    _settleAnim = Tween<double>(begin: from, end: 200.0).animate(
      CurvedAnimation(parent: _settleCtrl, curve: Curves.easeInCubic),
    );
    _settleCtrl.forward(from: 0.0).whenComplete(() {
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
        final shouldReappear = _dismissed &&
            player.hasSong &&
            (player.currentSong?.id != _dismissedSongId || player.isPlaying);

        if (shouldReappear) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() {
                _dismissed = false;
                _dismissedSongId = null;
              });
            }
          });
        }

        // No song, or currently dismissed → render NOTHING. There is no
        // height animation guarding this transition; the widget is simply
        // absent from the tree. Nothing here ever mid-animates a height,
        // so there is no clip window that can slice a fixed-height child.
        if (!player.hasSong || _dismissed) {
          return const SizedBox.shrink();
        }

        // Trigger entry animation when song first appears, changes, or the
        // mini player reappears after a dismiss.
        final songId = player.currentSong?.id;
        if (songId != _lastSongId) {
          final isFirstSong = _lastSongId == null;
          _lastSongId = songId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (isFirstSong) {
              _entryCtrl.forward(from: 0.0);
            } else {
              _slideInCtrl.forward(from: 0.0);
            }
          });
        }

        // Hide mini player when home hero is visible — simple and
        // direct: render nothing at all, same pattern as the
        // !hasSong/_dismissed case above. No reserved space, no
        // AnimatedSize, no extra wrapping.
        return ValueListenableBuilder<bool>(
          valueListenable: MiniPlayer.heroVisibleNotifier,
          builder: (context, heroVisible, _) {
            if (heroVisible) {
              return const SizedBox.shrink();
            }
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
      },
    );
  }

  Widget _buildInner(BuildContext context, PlayerProvider player) {
    return AnimatedBuilder(
      animation: _settleCtrl,
      builder: (_, child) {
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
          return GestureDetector(
            onTap: _openFullPlayer,
            onVerticalDragStart: _onDragStart,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    return ValueListenableBuilder<String>(
      valueListenable: AudioPrefs.miniPlayerBgStyleNotifier,
      builder: (context, bgStyle, _) {
        final isSolid = bgStyle == 'Solid';
        final capsuleDecoration = BoxDecoration(
          color: isSolid
              ? (isDark ? const Color(0xFF1A1A22) : const Color(0xFFF5F2EA))
              : (isDark
                  ? Colors.white.withAlpha(isDragging ? 14 : 9)
                  : Colors.black.withAlpha(isDragging ? 12 : 7)),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDragging
                ? AurumTheme.gold.withAlpha(60)
                : AurumTheme.gold.withAlpha(isDark ? 35 : 50),
            width: 0.8,
          ),
          // FIX (glow-bleed): this used to carry a second BoxShadow tinted
          // with AurumTheme.gold at a 12px blur radius. That shadow paints
          // outside the capsule's own ClipRRect bounds — since Container's
          // boxShadow is drawn on the *undecorated* box before children are
          // clipped, a wide, colored blur there reads as a stray purple/
          // gold glow sitting above/around the capsule, most noticeable
          // during the hero-hide/reappear transform on Home. A single
          // plain black drop-shadow is enough for depth; removing the
          // tinted one eliminates the bleed entirely.
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 100 : 30),
              blurRadius: isDragging ? 20 : 14,
              offset: const Offset(0, 4),
            ),
          ],
        );

        Widget capsuleBody = AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: capsuleDecoration,
          child:
              _miniPlayerCapsuleContent(context, song, showUpHint, showDownHint),
        );

        if (!isSolid) {
          capsuleBody = BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: capsuleBody,
          );
        }

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          height: 68,
          // RepaintBoundary forces this blur onto its own compositing
          // layer so it can never bleed into/from sibling BackdropFilters
          // (e.g. the bottom nav bar's own blur) on Android's Skia
          // backend.
          child: RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: capsuleBody,
            ),
          ),
        );
      },
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showUpHint = dragY < -20;
    final showDownHint = dragY > 20;

    return RepaintBoundary(
      child: ClipRect(
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: isDragging
                    ? AurumTheme.gold.withAlpha(70)
                    : AurumTheme.gold.withAlpha(isDark ? 30 : 45),
                width: 0.6,
              ),
            ),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withAlpha(isDragging ? 16 : 11)
                    : Colors.black.withAlpha(isDragging ? 14 : 9),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(isDark ? 90 : 26),
                    blurRadius: isDragging ? 22 : 16,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
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
            ),
          ),
        ),
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
