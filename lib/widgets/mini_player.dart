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
// MiniPlayer v2.1 — Fautune-style Premium
// • Swipe UP  → open FullPlayerScreen (smooth slide)
// • Swipe DOWN → stop music + dismiss with fade+scale out
// • Drag tracking: real-time translate + opacity + scale
// • Spring-settle back if drag cancelled
// • Gold progress bar, glassmorphism, haptics
//
// FIXES vs v2.0:
//   FIX 1: opaque:false -> opaque:true on FullPlayerScreen push. opaque:false
//      made Flutter stop fully repainting the screen underneath (Home/
//      Search/Library) while the full player was open, leaving a stale
//      frozen frame behind after closing it. FullPlayerScreen already
//      paints its own full opaque background, so opaque:true changes
//      nothing visually and fixes the freeze.
//   FIX 2: _dismissed reset now tracks the dismissed song's id instead of
//      only resetting on `!player.hasSong`. Previously, swiping the mini
//      player down only paused playback (didn't clear the queue), so
//      `hasSong` stayed true forever -- meaning `_dismissed` never reset
//      and the mini player stayed permanently hidden even after resuming/
//      playing again. Now it reappears as soon as a different song starts,
//      or playback resumes on the same song.
// ─────────────────────────────────────────────────────────────────────────────

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  /// Broadcasts the current mini-player style ('Capsule' / 'Compact Bar') so
  /// any live MiniPlayer instance updates INSTANTLY when the setting is
  /// changed in Settings → Appearance, without depending on
  /// didChangeDependencies (which does NOT fire just from a child route
  /// popping back to a persistent shell widget like this one — that was the
  /// root cause of the style not visibly updating after picking it in
  /// Settings, even though it was being saved to SharedPreferences correctly).
  static final ValueNotifier<String> styleNotifier =
      ValueNotifier<String>('Capsule');

  /// When home screen's hero card is visible, mini player hides.
  /// Home screen updates this via scroll; other screens leave it true.
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
  // +1 = went to prev (content exits right). Drives the settle-out animation
  // and the following slide-in animation for the new song.
  int _swipeDir = 0;

  late final AnimationController _swipeCtrl;
  Animation<double> _swipeAnim = const AlwaysStoppedAnimation(0.0);

  // Plays once per song change: new content slides in from the direction
  // opposite the swipe, so it feels like the old song was pushed off and
  // the new one pulled into place — one continuous motion, not two.
  late final AnimationController _slideInCtrl;
  late Animation<double> _slideInAnim;

  // 'Capsule' = original floating glass pill. 'Compact Bar' = new premium
  // edge-to-edge bar style, selectable from Settings → Appearance.
  static const String prefsKeyMiniPlayerStyle = 'mini_player_style';
  String _style = 'Capsule';

  late final AnimationController _settleCtrl;
  late Animation<double> _settleAnim;

  // Entry animation — plays once when mini player first appears or song changes
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
      duration: const Duration(milliseconds: 320),
    );
    _settleAnim = AlwaysStoppedAnimation(0.0);

    _entryCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
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
      duration: const Duration(milliseconds: 260),
    );

    _slideInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _slideInAnim = CurvedAnimation(
        parent: _slideInCtrl, curve: Curves.easeOutCubic);

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
  // interrupted. A completion callback only commits its result if the
  // generation hasn't changed, so starting a NEW drag while a dismiss/
  // springback animation is still finishing (which calls _settleCtrl.stop(),
  // and .whenComplete() ALSO fires on stop(), not just natural completion)
  // can no longer wrongly commit a pause/dismiss while the user is actively
  // dragging again. This was the "mini player randomly vanishes mid-drag"
  // bug.
  int _settleGen = 0;

  void _onDragStart(DragStartDetails _) {
    _settleGen++; // invalidate any in-flight settle completion
    _settleCtrl.stop();
    setState(() {
      _isDragging = true;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragY += details.delta.dy;
      // Allow both up and down with resistance
      _dragY = _dragY.clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDragging = false);

    // Swipe UP → open full player immediately, snap drag offset back to 0
    // with NO animation (we're navigating away, an animated springback here
    // just races the route push and leaves _settleCtrl mid-flight for the
    // next time this widget rebuilds — that stale animation state was the
    // "stuck" feeling on the following swipe).
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

  // ── Horizontal drag handlers ─────────────────────────────────────────
  void _onDragStartX(DragStartDetails _) {
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
    final from = _dragX;
    _swipeAnim = Tween<double>(begin: from, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted) return;
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }

  // Animates the CURRENT content the rest of the way off-screen, then
  // switches the song (build()'s songId-change check triggers slide-in for
  // the new content).
  void _commitSwipe({required bool next}) {
    _swipeCtrl.stop();
    final from = _dragX;
    final exitTo = next ? -220.0 : 220.0;
    _swipeAnim = Tween<double>(begin: from, end: exitTo).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeInCubic),
    );
    _swipeDir = next ? -1 : 1;
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted) return;
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
    Navigator.of(context)
        .push(
      PageRouteBuilder(
        // FIX: opaque:false caused the screen underneath (Home/Search/
        // Library) to freeze while the full player was open — Flutter
        // skips repainting routes it thinks may still be partially
        // visible. FullPlayerScreen paints its own full background, so
        // opaque:true is visually identical and fixes the freeze.
        opaque: true,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        // FullPlayerScreen already runs its own polished entry animation
        // internally (_entryCtrl: slide-up + fade + staggered content +
        // Hero artwork flight). Wrapping the route in a SECOND
        // SlideTransition here made two slide animations run at once,
        // fighting each other — that's what made open/close feel janky
        // instead of premium. The route transition is now just a quick
        // fade so the Hero flight + FullPlayerScreen's own entry motion
        // reads as one continuous, intentional movement.
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
      ),
    )
        .then((_) {
      _opening = false; // route closed — allow opening again
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        // Reset dismissed when a DIFFERENT song starts playing, OR when
        // playback resumes on the SAME song (e.g. user hits play again
        // from elsewhere). Must use postFrameCallback — mutating state
        // inside build() causes Flutter to skip renders, making the mini
        // player disappear.
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

        if (!player.hasSong) return const SizedBox.shrink();
        if (_dismissed) return const SizedBox.shrink();

        // Trigger entry animation when song first appears or changes
        final songId = player.currentSong?.id;
        if (songId != _lastSongId) {
          final isFirstSong = _lastSongId == null;
          _lastSongId = songId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (isFirstSong) {
              // First-ever appearance keeps the original bottom-up entry.
              _entryCtrl.forward(from: 0.0);
            } else {
              // Song changed via swipe (or skip buttons) — slide the new
              // content in from the side, continuing the swipe's motion.
              _slideInCtrl.forward(from: 0.0);
            }
          });
        }

        // Hide mini player when home hero is visible — no space left behind
        final heroVisible = MiniPlayer.heroVisibleNotifier.value;
        if (heroVisible) return const SizedBox.shrink();

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
    // Calculate visual transforms
    final currentY = _settleCtrl.isAnimating ? _settleAnim.value : _dragY;
    final dragFraction = (currentY.abs() / 160.0).clamp(0.0, 1.0);

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
      child: GestureDetector(
        onTap: _openFullPlayer,
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        onHorizontalDragStart: _onDragStartX,
        onHorizontalDragUpdate: _onDragUpdateX,
        onHorizontalDragEnd: _onDragEndX,
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
    // FIX: this used to force-unwrap (`player.currentSong!`). The parent
    // Consumer guards on `player.hasSong` one frame before this widget
    // builds, but currentSong is also re-read live inside AnimatedBuilder's
    // child (rebuilt independently of the Consumer on every settle-animation
    // tick) — if the queue resolve fails and clears the song in between
    // those two reads, the `!` throws here and crashes the whole app to a
    // blank white screen, which is exactly what was happening intermittently
    // on local/offline playback. Render nothing instead; the parent's
    // hasSong guard will hide this widget on the very next frame anyway.
    if (song == null) return const SizedBox.shrink();

    if (style == 'Compact Bar') {
      return _buildCompactBar(context, song);
    }
    return _buildCapsule(context, song);
  }

  Widget _buildCapsule(BuildContext context, dynamic song) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Hint: show up/down arrows while dragging
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(isDark ? 100 : 30),
              blurRadius: isDragging ? 28 : 20,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: AurumTheme.gold.withAlpha(isDragging ? 20 : 10),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        );

        Widget capsuleBody = AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: capsuleDecoration,
          child: _miniPlayerCapsuleContent(context, song, showUpHint, showDownHint),
        );

        // "Solid" skips the BackdropFilter blur entirely — cheaper to
        // render and gives a flat, opaque card look.
        if (!isSolid) {
          capsuleBody = BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: capsuleBody,
          );
        }

        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          height: 68,
          // RepaintBoundary forces this blur onto its OWN compositing layer.
          // FIX: without this, having multiple BackdropFilters active at once
          // (mini player + anything else mounted underneath, e.g. right as a
          // song starts and the mini player appears) can make some Android
          // GPU/Skia configs blur the entire shared backdrop layer instead of
          // just this clipped capsule — which is what was making the WHOLE
          // Home screen appear blurred the instant the mini player showed up,
          // and fixing itself the moment the mini player (and its filter) was
          // removed via swipe-down dismiss.
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

  Widget _miniPlayerCapsuleContent(BuildContext context, dynamic song, bool showUpHint, bool showDownHint) {
    return Stack(
              children: [
                // Main row
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Progress bar at top
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20)),
                      child: LinearProgressIndicator(
                        value: player.progress,
                        backgroundColor: Colors.transparent,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(AurumTheme.gold),
                        minHeight: 2,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            // Artwork
                            Hero(
                              tag: 'aurum_artwork',
                              flightShuttleBuilder:
                                  (ctx, anim, dir, from, to) =>
                                      ScaleTransition(
                                          scale: anim, child: to.widget),
                              child: AurumArtwork(
                                url: song.artworkUrl,
                                size: 44,
                                borderRadius: 10,
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Song info
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
                            // Controls
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

                // Drag hint overlay
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
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
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
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // Edge-to-edge progress line
                  LinearProgressIndicator(
                    value: player.progress,
                    backgroundColor: Colors.transparent,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        AurumTheme.gold),
                    minHeight: 2,
                  ),
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        children: [
                          // Square-ish artwork, slightly smaller than capsule
                          Hero(
                            tag: 'aurum_artwork',
                            flightShuttleBuilder:
                                (ctx, anim, dir, from, to) =>
                                    ScaleTransition(
                                        scale: anim, child: to.widget),
                            child: AurumArtwork(
                              url: song.artworkUrl,
                              size: 40,
                              borderRadius: 8,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                Text(
                                  song.title,
                                  style: TextStyle(
                                    color:
                                        AurumTheme.textPrimaryOf(context),
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
                                    color: AurumTheme.textSecondaryOf(
                                        context),
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
          width: 36, height: 36,
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
