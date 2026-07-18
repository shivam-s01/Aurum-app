import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../main.dart' show aurumRouteObserver;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:share_plus/share_plus.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/download_provider.dart';
import '../providers/premium_provider.dart';
import '../providers/theme_provider.dart';
import '../models/song.dart';
import '../models/lyrics.dart';
import '../theme/aurum_theme.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/audio_prefs.dart';
import '../services/waveform_service.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_like_button.dart';
import '../widgets/premium_gate.dart';
import 'library_screen.dart' show showAddToPlaylistSheet;
import 'settings_player_screen.dart' show SleepTimerService, SleepTimerSheet, EqualizerScreen;

// ─────────────────────────────────────────────────────────────────────────────
// FullPlayerScreen v5.0 — Echo Nightly Premium
// Changes from v4.3:
//   • _BgLayer: 3-color palette extraction (vibrant + dominant + dark muted)
//   • _BgLayer: breathing gradient animation via _breatheCtrl (4s loop)
//   • _BgLayer: blur sigma reduced 60→50 for lighter GPU load
//   • _showOptions: replaced basic list with premium grid sheet (JioSaavn style)
//   • _QueuePage: Echo Nightly style — "Now Playing" header, gradient tiles
//   • _QueueTile: album art, gradient highlight on current, cleaner layout
//   • _PremiumOptionsSheet: new widget — 2-col grid, song header, all actions
// ─────────────────────────────────────────────────────────────────────────────

class FullPlayerScreen extends StatefulWidget {
  const FullPlayerScreen({super.key});

  @override
  State<FullPlayerScreen> createState() => _FullPlayerScreenState();
}

class _FullPlayerScreenState extends State<FullPlayerScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {

  // ── Entry animation (420ms, easeOutCubic) ──
  // Note: entry slide/fade used to be driven by an internal _entryCtrl
  // here, stacked on top of the route's own PageRouteBuilder transition
  // (see mini_player.dart / home_screen.dart / search_screen.dart /
  // song_tile.dart, all standardized to a 380ms slide-up / 300ms
  // slide-down). That meant every open played TWO slide-in animations
  // back to back with different durations/curves, and every close played
  // a 480ms internal reverse THEN a separate 300ms route-pop reverse
  // (~780ms total) — the double-animation is what read as "awkward, not
  // premium". Removed: the route transition is now the single source of
  // truth for open/close motion, and _close() below just pops instead of
  // running its own reverse first.

  // ── Staggered entry: info, seekbar, controls fade in after artwork ──
  late final AnimationController _staggerCtrl;
  late final Animation<double> _infoStagger;
  late final Animation<double> _seekStagger;
  late final Animation<double> _ctrlStagger;

  // ── Song change: title cross-fade ──
  late final AnimationController _titleChangeCtrl;
  late final Animation<double> _titleFadeAnim;
  late final Animation<Offset> _titleSlideAnim;

  // ── Artwork scale on play/pause/song change ──
  late final AnimationController _artworkCtrl;
  late final Animation<double> _artworkAnim;

  // ── Play button tactile scale (110ms) ──
  late final AnimationController _playBtnCtrl;
  late final Animation<double> _playBtnAnim;

  // ── Background color morphing (700ms) ──
  late final AnimationController _bgColorCtrl;
  Color _targetBg1 = const Color(0xFF0D0D18);
  Color _targetBg2 = const Color(0xFF060608);
  Color _targetBg3 = const Color(0xFF030305);
  Color _targetBg4 = const Color(0xFF0A0A14);
  Color _currentBg1 = const Color(0xFF0D0D18);
  Color _currentBg2 = const Color(0xFF060608);
  Color _currentBg3 = const Color(0xFF030305);
  Color _currentBg4 = const Color(0xFF0A0A14);

  // ── Breathing gradient (12s loop, reverse) ──
  late final AnimationController _breatheCtrl;

  // ── Artwork float (5.5s loop, reverse) ──
  late final AnimationController _artworkFloatCtrl;

  // ── Swipe-down to dismiss / swipe-up to open panel ──
  double _dragY = 0;
  bool _isDragging = false;
  bool _dragIsUpward = false;
  // Tracks how far the finger has moved upward during this gesture, purely
  // for the release-time "did they mean to open Up Next" threshold check
  // below. Deliberately NOT applied to _dragY / screen position (see
  // onVerticalDragUpdate) — this fixes the full player visibly sliding up
  // while swiping to open Up Next.
  double _upwardDragDistance = 0;

  // ── Spring-back after a cancelled drag ──
  // Previously a cancelled drag (released before crossing the dismiss
  // threshold) snapped _dragY straight to 0 via setState with no
  // animation at all — visually a hard jump/jerk. This controller
  // animates that snap-back smoothly instead.
  late final AnimationController _springBackCtrl;

  // ── Palette / song cache ──
  String? _lastArtUrl;
  String? _lastSongId;

  // Bumped every time _extractColor is (re)triggered by a song change.
  // Palette extraction is async (PaletteGenerator awaits an image decode),
  // so on very fast song switching, an OLDER song's extraction can finish
  // AFTER a newer one's — e.g. song A's decode is slow, song C's is fast,
  // so C's colors land first and A's then overwrite them a moment later.
  // That read as the background trailing behind what the UI (artwork/
  // title) was already showing on rapid skips. Only the extraction whose
  // captured generation still matches the current one when it completes
  // is allowed to commit its colors — every stale, superseded one is
  // silently discarded, however late it finishes.
  int _artGen = 0;
  // Bumped every time the title cross-fade is (re)triggered — guards the
  // chained reverse().then(forward()) below so a stale completion from an
  // earlier, now-superseded skip can never fire its .forward() after a
  // newer skip has already started its own reverse, which under fast
  // spam-skipping could otherwise interleave and leave the title
  // mid-fade/stuck instead of cleanly settled on the current song.
  int _titleGen = 0;

  // ── Favourite toggle (local) ──
  // NOTE: local _isFav bool removed — liked state now reads/writes directly
  // through FavoritesProvider (see _SongInfo's onFavTap wiring below),
  // which is the single real source of truth already used everywhere else
  // (mini player, bottom sheet actions).

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Entry slide/fade now handled entirely by the route's own
    // PageRouteBuilder transition — see note above _entryCtrl's old
    // declaration for why the internal copy was removed.

    // Stagger: artwork appears with entry, info/seekbar/controls follow
    _staggerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _infoStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.18, 0.75, curve: Curves.easeOutCubic)));
    _seekStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.30, 0.85, curve: Curves.easeOutCubic)));
    _ctrlStagger = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _staggerCtrl,
            curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic)));
    _staggerCtrl.forward();

    // Song title cross-fade on track change
    _titleChangeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _titleFadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _titleChangeCtrl, curve: Curves.easeOut));
    _titleSlideAnim = Tween<Offset>(
            begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(CurvedAnimation(
            parent: _titleChangeCtrl, curve: Curves.easeOutCubic));
    _titleChangeCtrl.value = 1.0; // starts fully visible

    _artworkCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _artworkAnim = Tween<double>(begin: 0.94, end: 1.0)
        .animate(CurvedAnimation(parent: _artworkCtrl, curve: Curves.easeOutCubic));

    _playBtnCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 110),
    );
    _playBtnAnim = Tween<double>(begin: 1.0, end: 0.87)
        .animate(CurvedAnimation(parent: _playBtnCtrl, curve: Curves.easeInOut));

    _bgColorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    // Breathing: slow 18s cycle — very subtle ambient drift
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 18000),
    );

    // Artwork float: 6s pure vertical — Echo Nightly spec
    _artworkFloatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6000),
    );

    // Only start the ambient loops if the user hasn't disabled animations.
    // Previously these always started with ..repeat(reverse: true), so even
    // with the setting off the controllers kept ticking at 60fps forever
    // while the full player was open - pure wasted GPU/battery, since
    // _BgLayer clamps the consumed value to 0.5 either way when off.
    if (AudioPrefs.enableAnimationsNotifier.value) {
      _breatheCtrl.repeat(reverse: true);
      _artworkFloatCtrl.repeat(reverse: true);
    }

    _springBackCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    )..addListener(() {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    aurumRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _staggerCtrl.dispose();
    _titleChangeCtrl.dispose();
    _artworkCtrl.dispose();
    _artworkFloatCtrl.dispose();
    _playBtnCtrl.dispose();
    _bgColorCtrl.dispose();
    _breatheCtrl.dispose();
    _springBackCtrl.dispose();
    super.dispose();
  }

  /// Smoothly animates _dragY back to 0 after a cancelled drag, instead
  /// of snapping instantly. Uses an easeOutBack curve for a subtle
  /// "settle" feel rather than a linear slide.
  void _springBackDrag() {
    final start = _dragY;
    _springBackCtrl.reset();
    final anim = Tween<double>(begin: start, end: 0.0).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.easeOutCubic),
    );
    void listener() {
      if (!mounted) return;
      // setState is required here — without it _dragY changes but the
      // Transform.translate never rebuilds mid-animation, so the sheet
      // appears to jump/snap back instead of smoothly sliding down.
      setState(() => _dragY = anim.value);
    }

    anim.addListener(listener);
    _springBackCtrl.forward().whenCompleteOrCancel(() {
      anim.removeListener(listener);
      if (mounted) setState(() => _dragY = 0);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause ambient/breathing animations whenever app isn't actively
    // visible on screen — no point burning GPU ticks while backgrounded,
    // locked, or in app-switcher.
    if (state == AppLifecycleState.resumed) {
      if (!_panelOpen) _resumeAmbientAnims();
    } else {
      _pauseAmbientAnims();
    }
  }

  // ── RouteAware — pause ambient anims when a route is pushed on top ──
  // (lyrics screen, queue screen, options sheet, etc.)
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    aurumRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void didPushNext() {
    // A new route was pushed on top — pause GPU-heavy loops
    _pauseAmbientAnims();
  }

  @override
  void didPopNext() {
    // The route on top was popped — we're visible again, resume
    if (!_panelOpen) _resumeAmbientAnims();
  }

  bool _panelOpen = false;
  bool _ambientPaused = false;

  void _pauseAmbientAnims() {
    if (_ambientPaused) return;
    _ambientPaused = true;
    _breatheCtrl.stop();
    _artworkFloatCtrl.stop();
  }

  void _resumeAmbientAnims() {
    if (!_ambientPaused) return;
    _ambientPaused = false;
    // Respect the Appearance -> Animations setting: if the user has turned
    // ambient motion off, don't spin these controllers at all - no point
    // burning GPU/battery on a value that _BgLayer will just clamp to 0.5.
    if (AudioPrefs.enableAnimationsNotifier.value) {
      _breatheCtrl.repeat(reverse: true);
      _artworkFloatCtrl.repeat(reverse: true);
    }
  }

  // ── Palette extraction → 4 colors, theme-adaptive, on track change only ──
  Future<void> _extractColor(String url, {bool isLight = false}) async {
    if (url.isEmpty || url == _lastArtUrl) return;
    _lastArtUrl = url;
    final gen = ++_artGen;
    try {
      final ImageProvider provider;
      if (url.startsWith('http')) {
        provider = CachedNetworkImageProvider(url);
      } else {
        return;
      }
      // 120x120 gives better palette quality with minimal decode cost
      final pg = await PaletteGenerator.fromImageProvider(
          provider, size: const Size(120, 120));

      // Stale check: a newer song was switched to while this decode was
      // still in flight. Bail out without touching any color/animation
      // state — whatever the newer call already committed (or is about
      // to) stays authoritative. This is what actually stops the
      // background from ever trailing behind fast rapid-fire switching.
      if (gen != _artGen) return;

      // 4 distinct roles: vibrant glow, dominant base, muted mid, dark anchor
      final c1 = pg.vibrantColor?.color ??
          pg.lightVibrantColor?.color ??
          pg.dominantColor?.color ??
          const Color(0xFF1A1630);
      final c2 = pg.dominantColor?.color ??
          pg.mutedColor?.color ??
          const Color(0xFF120F24);
      final c3 = pg.darkMutedColor?.color ??
          pg.mutedColor?.color ??
          const Color(0xFF080810);
      final c4 = pg.lightVibrantColor?.color ??
          pg.vibrantColor?.color ??
          pg.lightMutedColor?.color ??
          c1;

      if (!mounted || gen != _artGen) return;

      // Snapshot current lerped position before morphing
      final t = _bgColorCtrl.value;
      _currentBg1 = Color.lerp(_currentBg1, _targetBg1, t) ?? _currentBg1;
      _currentBg2 = Color.lerp(_currentBg2, _targetBg2, t) ?? _currentBg2;
      _currentBg3 = Color.lerp(_currentBg3, _targetBg3, t) ?? _currentBg3;
      _currentBg4 = Color.lerp(_currentBg4, _targetBg4, t) ?? _currentBg4;

      if (isLight) {
        // Previously blended 35-58% toward white, which washed the
        // artwork's actual colors out into a flat grey/white haze (the
        // "bekar" light-mode look). Cut the white blend way down so the
        // extracted palette stays visibly saturated — matching how the
        // dark-mode branch keeps most of the color and only deepens it
        // toward black. Light mode now lightens just enough to keep dark
        // text/icons readable, without losing the artwork's identity.
        _targetBg1 = Color.lerp(c1, Colors.white, 0.16)!;
        _targetBg2 = Color.lerp(c2, Colors.white, 0.10)!;
        _targetBg3 = Color.lerp(c3, Colors.white, 0.04)!;
        _targetBg4 = Color.lerp(c4, Colors.white, 0.20)!;
      } else {
        // Less black = more saturated, more cinematic — Echo Nightly style
        _targetBg1 = Color.lerp(c1, Colors.black, 0.22)!;
        _targetBg2 = Color.lerp(c2, Colors.black, 0.48)!;
        _targetBg3 = Color.lerp(c3, Colors.black, 0.70)!;
        _targetBg4 = Color.lerp(c4, Colors.black, 0.30)!;
      }

      _bgColorCtrl.forward(from: 0.0);
    } catch (_) {}
  }

  void _triggerArtworkAnimation() {
    // FIX — "fast spam-skip makes the artwork/UI lag behind the actual
    // song": this used to only call forward(from: 0.0) when the artwork
    // controller WASN'T already animating — meaning if you skipped again
    // while the previous song's artwork transition was still mid-flight,
    // the new trigger was silently dropped and the OLD artwork animation
    // was left to finish on its own timeline before anything reflected the
    // real current song. Under rapid repeated skips this stacked into
    // visibly stale artwork trailing behind, no matter how fast the user
    // tapped. Always restarting from 0.0 (regardless of current animation
    // state) guarantees the artwork transition always represents the
    // LATEST song the instant a skip lands — old in-flight animations are
    // simply superseded, never queued or waited on.
    if (mounted) {
      _artworkCtrl.forward(from: 0.0);
    }
    // Title cross-fade: fade out → snap new title → fade in
    if (mounted) {
      final gen = ++_titleGen;
      _titleChangeCtrl.reverse(from: 1.0).then((_) {
        if (mounted && gen == _titleGen) _titleChangeCtrl.forward();
      });
    }
  }

  void _close() {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    if (_dragY != 0) setState(() => _dragY = 0);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _onPlayTap(PlayerProvider player) async {
    HapticFeedback.heavyImpact();
    await _playBtnCtrl.forward();
    await _playBtnCtrl.reverse();
    player.togglePlay();
    _triggerArtworkAnimation();
  }

  void _openPanel() {
    HapticFeedback.mediumImpact();
    _panelOpen = true;
    _pauseAmbientAnims();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withAlpha(165),
      useSafeArea: false,
      builder: (_) => _PremiumContentPanel(
        bg1: _currentBg1,
        bg2: _currentBg2,
        bg3: _currentBg3,
      ),
    ).whenComplete(() {
      _panelOpen = false;
      if (mounted &&
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) {
        _resumeAmbientAnims();
      }
    });
  }

  void _showOptions(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withAlpha(150),
      builder: (_) => _PremiumOptionsSheet(
        song: song,
        player: player,
        accentColor: _targetBg1,
        rootContext: context,
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (String?, bool, bool, LoopMode, bool, int)>(
      selector: (_, player) => (
        player.currentSong?.id,
        player.isPlaying,
        player.isLoading,
        player.loopMode,
        player.shuffle,
        player.queue.length,
      ),
      builder: (context, _, __) {
        final player = context.read<PlayerProvider>();
        final song = player.currentSong;
        if (song == null) {
          // currentSong went null while this screen is open (e.g. stream
          // resolve failed and the queue got cleared). Rendering nothing
          // here just leaves a black/blank screen sitting on top of the
          // app — close it automatically instead so the user lands back
          // on whatever screen they came from.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const SizedBox.shrink();
        }

        // Trigger artwork + color extraction on song change only
        if (song.id != _lastSongId) {
          _lastSongId = song.id;
          final isLight = Theme.of(context).brightness == Brightness.light;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _triggerArtworkAnimation();
            if (song.artworkUrl.isNotEmpty) _extractColor(song.artworkUrl, isLight: isLight);
          });
        }

        final dragOpacity =
            (1.0 - (_dragY / 320).clamp(0.0, 0.55)).clamp(0.0, 1.0);
        final dragScale =
            (1.0 - (_dragY / 2200).clamp(0.0, 0.06)).clamp(0.0, 1.0);

        return GestureDetector(
              // Single gesture owner for the whole screen — swipe down
              // dismisses, swipe up opens the queue/lyrics panel. Having
              // this logic split across two nested GestureDetectors (one
              // wrapping the whole screen, one wrapping just the body)
              // put both in the same Flutter gesture arena on the same
              // axis, so the arena's win/lose resolution was effectively
              // arbitrary — sometimes swallowing the swipe-up-to-open
              // gesture, sometimes double-firing, sometimes leaving
              // _dragY in a stuck state. One detector removes the
              // ambiguity entirely.
              onVerticalDragStart: (_) {
                _dragIsUpward = false;
                _upwardDragDistance = 0;
                setState(() => _isDragging = true);
              },
              onVerticalDragUpdate: (d) {
                if (_panelOpen) return;
                if (d.delta.dy > 0 && !_dragIsUpward) {
                  // Downward: drag-to-dismiss follows the finger.
                  setState(() => _dragY += d.delta.dy);
                } else if (d.delta.dy < 0 || _dragIsUpward) {
                  // Upward: STRICT FIX — this used to nudge _dragY negative
                  // (clamped to -60) and Transform.translate applied that
                  // immediately, so the instant you started swiping up to
                  // open Up Next, the *entire full player screen* visibly
                  // slid upward underneath your finger — worse and more
                  // jarring the faster you swiped. The Up Next panel opens
                  // as its own bottom sheet with its own slide-in transition
                  // (see _openPanel/showModalBottomSheet below); the full
                  // player underneath has no reason to move at all during
                  // that gesture. We track the raw distance separately
                  // (_upwardDragDistance) purely so onVerticalDragEnd's
                  // threshold check below keeps working for slow deliberate
                  // swipes, not just fast flicks — without ever touching
                  // the screen's position.
                  _dragIsUpward = true;
                  _upwardDragDistance += d.delta.dy; // negative while moving up
                }
              },
              onVerticalDragEnd: (d) {
                setState(() => _isDragging = false);
                final velocity = d.primaryVelocity ?? 0;

                if (!_dragIsUpward && (_dragY > 110 || velocity > 750)) {
                  // Reset drag offset before popping — _close() now just
                  // pops the route directly, so the route's own reverse
                  // transition (see PageRouteBuilder callers) takes over
                  // immediately with no extra internal animation in front
                  // of it.
                  setState(() => _dragY = 0);
                  _close();
                } else if (_dragIsUpward &&
                    (_upwardDragDistance < -20 || velocity < -400)) {
                  setState(() => _dragY = 0);
                  _openPanel();
                } else {
                  _springBackDrag();
                }
                _dragIsUpward = false;
              },
              child: Transform.translate(
                offset: Offset(0, _dragY.clamp(0.0, 280.0)),
                child: Transform.scale(
                  scale: dragScale,
                  child: Opacity(
                    opacity: dragOpacity,
                    child: Scaffold(
                      // Was Colors.transparent — combined with the
                      // route's opaque:true (needed to stop the screen
                      // behind from freezing), any frame where this
                      // Scaffold hadn't yet painted its own background
                      // (e.g. right at the start of the slide-up
                      // transition) showed through as a flash of plain
                      // white instead of the previous route or the
                      // player's own gradient. A real background color
                      // matching the current theme removes that gap.
                      backgroundColor:
                          Theme.of(context).brightness == Brightness.light
                              ? const Color(0xFFF5F0EA)
                              : Colors.black,
                      body: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Background: isolated repaint boundary
                          RepaintBoundary(
                            child: _BgLayer(
                              song: song,
                              bgCtrl: _bgColorCtrl,
                              breatheCtrl: _breatheCtrl,
                              startBg1: _currentBg1,
                              startBg2: _currentBg2,
                              startBg3: _currentBg3,
                              startBg4: _currentBg4,
                              targetBg1: _targetBg1,
                              targetBg2: _targetBg2,
                              targetBg3: _targetBg3,
                              targetBg4: _targetBg4,
                            ),
                          ),
                          SafeArea(
                            child: RepaintBoundary(
                              child: _buildBody(context, player, song),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, PlayerProvider player, Song song) {
    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final w = constraints.maxWidth;
      final isCompact = h < 640;
      final isTablet = w > 600;

      final vGapSm = isCompact ? 8.0 : 16.0;
      final vGapMd = isCompact ? 12.0 : 20.0;
      final hPad = isTablet ? w * 0.16 : 28.0;

      return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DragHandle(isDragging: _isDragging),
            _TopBar(song: song, onMore: () => _showOptions(context)),
            SizedBox(height: vGapMd),
            // Artwork — enters with the screen slide (no extra delay)
            _Artwork(
              song: song,
              player: player,
              hPad: hPad,
              h: h,
              w: w,
              artworkAnim: _artworkAnim,
              breatheCtrl: _artworkFloatCtrl,
            ),
            SizedBox(height: vGapMd),
            // Song info — staggered fade+slide up (delay ~90ms)
            FadeTransition(
              opacity: _infoStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.06), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.18, 0.75, curve: Curves.easeOutCubic))),
                child: FadeTransition(
                  opacity: _titleFadeAnim,
                  child: SlideTransition(
                    position: _titleSlideAnim,
                    child: _SongInfo(
                      song: song,
                      hPad: hPad,
                      isTablet: isTablet,
                      // FIX — "like button not wired, doesn't actually
                      // save/count as liked": this used to read/write a
                      // local `_isFav` bool that had NO connection to
                      // FavoritesProvider at all. It always opened showing
                      // unliked (even for an actually-liked song) and
                      // tapping it only flipped that local visual bool —
                      // nothing was ever persisted, and the song was never
                      // really added to/removed from Favorites. Now reads
                      // the real state straight from FavoritesProvider
                      // (same source of truth the bottom-sheet's "Like"
                      // action and the mini player's AurumLikeButton
                      // already correctly use) so the heart always
                      // reflects — and actually changes — the song's real
                      // liked status.
                      isFav: context.watch<FavoritesProvider>().isFavorite(song.id),
                      onFavTap: () {
                        PremiumGate.guard(
                          context,
                          feature: AppLocalizations.of(context)!.fpLikeSongsFeature,
                          description: AppLocalizations.of(context)!.fpLikeSongsSignIn,
                          requiresLoginOnly: true,
                          onAllowed: () {
                            HapticFeedback.lightImpact();
                            context.read<FavoritesProvider>().toggleFavorite(song);
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: vGapSm),
            // Seek bar — delay ~150ms
            FadeTransition(
              opacity: _seekStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.30, 0.85, curve: Curves.easeOutCubic))),
                child: _SeekBar(player: player, hPad: hPad),
              ),
            ),
            SizedBox(height: vGapSm),
            // Controls — delay ~220ms
            FadeTransition(
              opacity: _ctrlStagger,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: _staggerCtrl,
                        curve: const Interval(0.42, 1.0, curve: Curves.easeOutCubic))),
                child: _Controls(
                  player: player,
                  hPad: hPad,
                  playBtnAnim: _playBtnAnim,
                  bg1: _currentBg1,
                  onPlayTap: () => _onPlayTap(player),
                ),
              ),
            ),
            SizedBox(height: isCompact ? 8.0 : 12.0),
            _QualityPills(song: song, hPad: hPad),
            const Spacer(),
            _BottomPill(hPad: hPad, onTap: _openPanel),
            SizedBox(height: isCompact ? 8.0 : 12.0),
          ],
        );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drag Handle
// ─────────────────────────────────────────────────────────────────────────────
class _DragHandle extends StatelessWidget {
  final bool isDragging;
  const _DragHandle({required this.isDragging});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: isDragging ? 44 : 32,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(isDragging ? 80 : 45),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top Bar
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final Song song;
  final VoidCallback onMore;
  const _TopBar({required this.song, required this.onMore});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textMuted = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(72);
    final pillBg = isLight ? AurumTheme.lightBgSurface.withAlpha(180) : Colors.white.withAlpha(8);
    final pillBorder = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(12);
    final iconColor = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(200);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        _IconBtn(
          icon: Icons.keyboard_arrow_down_rounded,
          size: 26,
          color: iconColor,
          onTap: () => Navigator.pop(context),
          semanticLabel: l10n.fpClosePlayer,
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: pillBorder, width: 0.5),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                l10n.fpNowPlaying,
                style: TextStyle(
                  color: textMuted,
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                song.album.isNotEmpty ? song.album : 'Aurum Music', // brand name — not translated
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ),
        _IconBtn(
          icon: Icons.more_vert_rounded,
          size: 22,
          color: iconColor,
          onTap: onMore,
          semanticLabel: l10n.fpMoreOptions,
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Artwork
// ─────────────────────────────────────────────────────────────────────────────
class _Artwork extends StatefulWidget {
  final Song song;
  final PlayerProvider player;
  final double hPad, h, w;
  final Animation<double> artworkAnim;
  final Animation<double> breatheCtrl;

  const _Artwork({
    required this.song,
    required this.player,
    required this.hPad,
    required this.h,
    required this.w,
    required this.artworkAnim,
    required this.breatheCtrl,
  });

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  double _dragDx = 0;
  bool _dragging = false;

  // Higher sensitivity (closer to 100) means a shorter swipe triggers a
  // skip. We map the 0–100 setting onto a 220px (least sensitive) down to
  // 70px (most sensitive) drag-distance threshold.
  double _thresholdFor(double sensitivity) {
    final t = sensitivity.clamp(0.0, 100.0) / 100.0;
    return 220.0 - (150.0 * t);
  }

  void _handleDragEnd() {
    final sensitivity = AudioPrefs.swipeSensitivity;
    final threshold = _thresholdFor(sensitivity);
    if (_dragDx <= -threshold) {
      HapticFeedback.mediumImpact();
      widget.player.skipNext().then((allowed) {
        if (!allowed && mounted) {
          PremiumGate.show(
            context,
            feature: AppLocalizations.of(context)!.fpUnlimitedSkipsFeature,
            description: AppLocalizations.of(context)!.fpUnlimitedSkipsSignIn,
            requiresLoginOnly: true,
          );
        }
      });
    } else if (_dragDx >= threshold) {
      HapticFeedback.mediumImpact();
      widget.player.skipPrev();
    }
    setState(() {
      _dragDx = 0;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final maxArtSize = (widget.w - widget.hPad * 2).clamp(0.0, widget.h * 0.42);
    return ValueListenableBuilder<bool>(
      valueListenable: AudioPrefs.swipeToChangeNotifier,
      builder: (context, swipeEnabled, _) {
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: swipeEnabled
              ? (_) => setState(() => _dragging = true)
              : null,
          onHorizontalDragUpdate: swipeEnabled
              ? (d) => setState(() => _dragDx += d.delta.dx)
              : null,
          onHorizontalDragEnd: swipeEnabled ? (_) => _handleDragEnd() : null,
          onHorizontalDragCancel: swipeEnabled
              ? () => setState(() {
                    _dragDx = 0;
                    _dragging = false;
                  })
              : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.hPad),
            child: Center(
              child: SizedBox(
                width: maxArtSize,
                height: maxArtSize + 8, // headroom for float offset
                child: AnimatedBuilder(
                  animation: widget.breatheCtrl,
                  builder: (_, child) {
                    // Pure vertical float: 0 → -7px → 0, easeInOut — Echo Nightly spec.
                    // No horizontal drift, no scale — just a clean gentle rise and fall.
                    final t = Curves.easeInOut.transform(widget.breatheCtrl.value);
                    final floatY = -7.0 * t;
                    final dragScale = _dragging
                        ? (1.0 - (_dragDx.abs() / 800).clamp(0.0, 0.08))
                        : 1.0;
                    return Transform.translate(
                      offset: Offset(_dragDx * 0.3, floatY),
                      child: Transform.scale(scale: dragScale, child: child),
                    );
                  },
                  child: AnimatedBuilder(
                  animation: widget.artworkAnim,
                  builder: (_, child) => Transform.scale(
                    scale: widget.artworkAnim.value,
                    child: child,
                  ),
                  child: Hero(
                    tag: 'aurum_artwork',
                    flightShuttleBuilder: (context, animation, direction, from, to) {
                      return Material(
                        color: Colors.transparent,
                        child: ScaleTransition(scale: animation, child: to.widget),
                      );
                    },
                    child: ValueListenableBuilder<String>(
                      valueListenable: AudioPrefs.artworkShapeNotifier,
                      builder: (context, shape, _) {
                        final radius = shape == 'Circle'
                            ? maxArtSize / 2
                            : shape == 'Square'
                                ? 4.0
                                : 20.0;
                        return RepaintBoundary(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 500),
                            curve: Curves.easeOutCubic,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(radius),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withAlpha(widget.player.isPlaying ? 180 : 110),
                                  blurRadius: widget.player.isPlaying ? 64 : 40,
                                  offset: const Offset(0, 24),
                                  spreadRadius: widget.player.isPlaying ? 4 : 0,
                                ),
                                BoxShadow(
                                  color: Colors.black.withAlpha(90),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(radius),
                              child: AurumArtwork(
                                url: widget.song.artworkUrl,
                                size: double.infinity,
                                borderRadius: radius,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song Info
// ─────────────────────────────────────────────────────────────────────────────
class _SongInfo extends StatelessWidget {
  final Song song;
  final double hPad;
  final bool isTablet, isFav;
  final VoidCallback onFavTap;

  const _SongInfo({
    required this.song,
    required this.hPad,
    required this.isTablet,
    required this.isFav,
    required this.onFavTap,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(128);
    final titleSize = isTablet ? 26.0 : 22.0;
    // Text sits on top of dynamic, artwork-derived background (_BgLayer),
    // whose color varies per song. A single static text color can't
    // guarantee contrast against every possible artwork — a soft shadow
    // (opposite tone from the text) keeps title/artist legible no matter
    // how light or dark the underlying art is, in both themes.
    final shadowColor = isLight
        ? Colors.white.withAlpha(200)
        : Colors.black.withAlpha(160);
    final textShadows = [
      Shadow(color: shadowColor, blurRadius: 16),
      Shadow(color: shadowColor, blurRadius: 6),
    ];
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MarqueeText(
                  text: song.title,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: titleSize,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    letterSpacing: -0.5,
                    shadows: textShadows,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  style: TextStyle(
                    color: textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.1,
                    shadows: textShadows,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          _FavButton(isFav: isFav, onTap: onFavTap),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seek Bar
// ─────────────────────────────────────────────────────────────────────────────
class _SeekBar extends StatefulWidget {
  final PlayerProvider player;
  final double hPad;
  const _SeekBar({required this.player, required this.hPad});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  bool _dragging = false;
  double? _dragValue;
  List<double>? _waveform;
  String? _waveformFor;

  Future<void> _loadWaveform() async {
    final song = widget.player.currentSong;
    if (song == null) return;
    final key = song.localPath ?? song.streamUrl ?? song.id;
    if (_waveformFor == key) return;
    _waveformFor = key;
    final isLocal = song.isLocal;
    final path = song.localPath ?? song.streamUrl ?? '';
    if (path.isEmpty) return;
    final wf = await WaveformService.getWaveform(path, isLocal: isLocal);
    if (mounted && _waveformFor == key) {
      setState(() => _waveform = wf);
    }
  }

  @override
  Widget build(BuildContext context) {
    // PERF FIX: _SeekBar used to rely on `widget.player` handed down from
    // the parent screen's Consumer, which rebuilt every tick anyway. Now
    // that the parent is gated by Selector (see _FullPlayerScreenState),
    // this widget listens to progress/position/buffered directly so the
    // slider still updates smoothly every tick without pulling the rest
    // of the (much heavier) screen along with it.
    return Selector<PlayerProvider, (double, int, int, String, String)>(
      selector: (_, player) => (
        player.progress,
        player.duration.inMilliseconds,
        player.buffered.inMilliseconds,
        player.positionString,
        player.durationString,
      ),
      builder: (context, _, __) => _buildSeekBar(context),
    );
  }

  Widget _buildSeekBar(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final trackActive = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final trackInactive = isLight ? AurumTheme.lightBgSurface : Colors.white.withAlpha(28);
    final timeColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(92);

    // Settings → Appearance → "Player Slider Style"
    final sliderStyle = context.watch<ThemeProvider>().playerSliderStyle;
    final double baseTrackHeight;
    final double thumbRadius;
    switch (sliderStyle) {
      case 'Slim':
        baseTrackHeight = 1.5;
        thumbRadius = 4.5;
        break;
      case 'Thick':
        baseTrackHeight = 6.0;
        thumbRadius = 7.0;
        break;
      case 'Waveform':
        baseTrackHeight = 0;
        thumbRadius = 0;
        break;
      case 'Rounded':
      default:
        baseTrackHeight = 3.0;
        thumbRadius = 5.5;
    }

    if (sliderStyle == 'Waveform') {
      _loadWaveform();
      return _WaveformSeekBar(
        player: widget.player,
        hPad: widget.hPad,
        waveform: _waveform,
        activeColor: trackActive,
        inactiveColor: trackInactive,
        timeColor: timeColor,
        dragging: _dragging,
        dragValue: _dragValue,
        onDragStart: () {
          HapticFeedback.selectionClick();
          setState(() => _dragging = true);
        },
        onDrag: (v) => setState(() => _dragValue = v),
        onDragEnd: (v) {
          HapticFeedback.selectionClick();
          widget.player.seek(v);
          setState(() { _dragging = false; _dragValue = null; });
        },
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _dragging ? baseTrackHeight + 1 : baseTrackHeight,
              thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _dragging ? thumbRadius + 2 : thumbRadius,
                  elevation: _dragging ? 4 : 1,
                  pressedElevation: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
              activeTrackColor: trackActive,
              inactiveTrackColor: trackInactive,
              thumbColor: trackActive,
              overlayColor: trackActive.withAlpha(22),
              trackShape: const _BufferedTrackShape(),
            ),
            child: Slider(
              value: widget.player.progress,
              secondaryTrackValue: widget.player.duration.inMilliseconds > 0
                  ? (widget.player.buffered.inMilliseconds /
                          widget.player.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0,
              onChangeStart: (_) {
                HapticFeedback.selectionClick();
                setState(() => _dragging = true);
              },
              onChanged: widget.player.seek,
              onChangeEnd: (_) {
                HapticFeedback.selectionClick();
                setState(() => _dragging = false);
              },
            ),
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.player.positionString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              Text(widget.player.durationString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _WaveformSeekBar — premium waveform-style progress bar
// ─────────────────────────────────────────────────────────────────────────────
class _WaveformSeekBar extends StatelessWidget {
  final PlayerProvider player;
  final double hPad;
  final List<double>? waveform;
  final Color activeColor;
  final Color inactiveColor;
  final Color timeColor;
  final bool dragging;
  final double? dragValue;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onDragEnd;

  const _WaveformSeekBar({
    required this.player,
    required this.hPad,
    required this.waveform,
    required this.activeColor,
    required this.inactiveColor,
    required this.timeColor,
    required this.dragging,
    required this.dragValue,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final progress = dragging ? (dragValue ?? player.progress) : player.progress;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad - 4),
      child: Column(children: [
        SizedBox(
          height: 32,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              void handleUpdate(Offset local) {
                final v = (local.dx / width).clamp(0.0, 1.0);
                onDrag(v);
              }
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  onDragStart();
                  handleUpdate(d.localPosition);
                },
                onHorizontalDragUpdate: (d) => handleUpdate(d.localPosition),
                onHorizontalDragEnd: (_) => onDragEnd(dragValue ?? progress),
                onTapDown: (d) {
                  onDragStart();
                  handleUpdate(d.localPosition);
                },
                onTapUp: (_) => onDragEnd(dragValue ?? progress),
                child: CustomPaint(
                  size: Size(width, 32),
                  painter: _WaveformPainter(
                    bars: waveform,
                    progress: progress,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(player.positionString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
              Text(player.durationString,
                style: TextStyle(color: timeColor, fontSize: 11,
                    fontWeight: FontWeight.w500, letterSpacing: 0.3)),
            ],
          ),
        ),
      ]),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double>? bars;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final data = bars ?? List.filled(60, 0.4);
    final count = data.length;
    if (count == 0) return;

    final gap = 2.5;
    final barWidth = (size.width - gap * (count - 1)) / count;
    final centerY = size.height / 2;
    final progressX = size.width * progress;

    final activePaint = Paint()
      ..color = activeColor
      ..strokeCap = StrokeCap.round;
    final inactivePaint = Paint()
      ..color = inactiveColor
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < count; i++) {
      final x = i * (barWidth + gap) + barWidth / 2;
      final h = (data[i].clamp(0.08, 1.0)) * (size.height * 0.85);
      final isActive = x <= progressX;
      final paint = isActive ? activePaint : inactivePaint;
      paint.strokeWidth = barWidth.clamp(1.5, 4.0);
      canvas.drawLine(
        Offset(x, centerY - h / 2),
        Offset(x, centerY + h / 2),
        paint,
      );
    }

    // Playhead dot
    canvas.drawCircle(
      Offset(progressX, centerY),
      3.5,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      old.progress != progress || old.bars != bars ||
      old.activeColor != activeColor || old.inactiveColor != inactiveColor;
}


class _Controls extends StatelessWidget {
  final PlayerProvider player;
  final double hPad;
  final Animation<double> playBtnAnim;
  final Color bg1;
  final VoidCallback onPlayTap;

  const _Controls({
    required this.player,
    required this.hPad,
    required this.playBtnAnim,
    required this.bg1,
    required this.onPlayTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLoopOne = player.loopMode == LoopMode.one;
    final isLoopAll = player.loopMode == LoopMode.all;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad - 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CtrlBtn(
            icon: Icons.shuffle_rounded,
            size: 20,
            active: player.shuffle,
            semanticLabel: l10n.fpShuffle,
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleShuffle();
            },
          ),
          _CtrlBtn(
            icon: Icons.skip_previous_rounded,
            size: 38,
            color: Colors.white.withAlpha(210),
            semanticLabel: l10n.fpPrevious,
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipPrev();
            },
          ),
          ScaleTransition(
            scale: playBtnAnim,
            child: _PremiumPlayButton(
              isPlaying: player.isPlaying,
              isLoading: player.isLoading,
              bg1: bg1,
              onTap: onPlayTap,
            ),
          ),
          _CtrlBtn(
            icon: Icons.skip_next_rounded,
            size: 38,
            color: Colors.white.withAlpha(210),
            semanticLabel: l10n.fpNext,
            onTap: () {
              HapticFeedback.mediumImpact();
              player.skipNext().then((allowed) {
                if (!allowed && context.mounted) {
                  PremiumGate.show(
                    context,
                    feature: AppLocalizations.of(context)!.fpUnlimitedSkipsFeature,
                    description: AppLocalizations.of(context)!.fpUnlimitedSkipsSignIn,
                    requiresLoginOnly: true,
                  );
                }
              });
            },
          ),
          _CtrlBtn(
            icon: isLoopOne
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            size: 20,
            active: isLoopAll || isLoopOne,
            semanticLabel: l10n.fpRepeat,
            onTap: () {
              HapticFeedback.selectionClick();
              player.toggleLoop();
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pills
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPills extends StatelessWidget {
  final Song song;
  final double hPad;
  const _QualityPills({required this.song, required this.hPad});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final parts = <String>[];
    if (song.isLocal) parts.add(l10n.fpLocalBadge);
    if (song.language != null && song.language!.isNotEmpty) {
      parts.add(song.language!.toUpperCase());
    }
    if (song.year != null && song.year!.isNotEmpty) parts.add(song.year!);
    if (parts.isEmpty) return const SizedBox(height: 8);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        children: parts.map((p) => _QualityPill(label: p)).toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bottom Pill
// ─────────────────────────────────────────────────────────────────────────────
class _BottomPill extends StatelessWidget {
  final double hPad;
  final VoidCallback onTap;
  const _BottomPill({required this.hPad, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final pillBg = isLight ? AurumTheme.lightBgSurface.withAlpha(200) : Colors.white.withAlpha(10);
    final pillBorder = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(18);
    final iconColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(96);
    final textColor = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(112);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hPad),
      child: GestureDetector(
        onTap: onTap,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -300) onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: pillBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pillBorder, width: 0.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.keyboard_arrow_up_rounded, color: iconColor, size: 16),
              const SizedBox(width: 8),
              Text(
                l10n.fpQueueLyricsInfo,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Play Button
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumPlayButton extends StatelessWidget {
  final bool isPlaying, isLoading;
  final Color bg1;
  final VoidCallback onTap;

  const _PremiumPlayButton({
    required this.isPlaying,
    required this.isLoading,
    required this.bg1,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Settings → Appearance → "Player Button Colors": 'Primary' (default,
    // white circle / black icon — current design), 'White' (explicit, same
    // as Primary), 'Accent' (uses the user's chosen accent color).
    final buttonColorMode = context.watch<ThemeProvider>().playerButtonColorMode;
    final accent = context.watch<ThemeProvider>().accentColor;
    final circleColor = buttonColorMode == 'Accent' ? accent : Colors.white;
    final iconColor = buttonColorMode == 'Accent'
        ? (ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : Colors.black)
        : Colors.black;

    return Semantics(
      label: isPlaying ? l10n.fpPause : l10n.fpPlay,
      button: true,
      child: GestureDetector(
        onTap: isLoading ? null : onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            color: circleColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: circleColor.withAlpha(38),
                blurRadius: 32,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: bg1.withAlpha(128),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: isLoading
                ? const SizedBox(
                    key: ValueKey('loading'),
                    width: 26,
                    height: 26,
                    child: Center(child: AurumM3Loader(width: 26, height: 2.5)),
                  )
                : Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(isPlaying),
                    color: iconColor,
                    size: 36,
                  ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Favourite Button
// ─────────────────────────────────────────────────────────────────────────────
class _FavButton extends StatelessWidget {
  final bool isFav;
  final VoidCallback onTap;
  const _FavButton({required this.isFav, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<ThemeProvider>().accentColor;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: AurumLikeButton(
        isLiked: isFav,
        size: 24,
        likedColor: accent,
        unlikedColor: Colors.white.withAlpha(128),
        onTap: onTap,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quality Pill
// ─────────────────────────────────────────────────────────────────────────────
class _QualityPill extends StatelessWidget {
  final String label;
  const _QualityPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withAlpha(20), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withAlpha(88),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared action helpers — used by both the Full Player options sheet and the
// SongTile quick-actions sheet, so the behaviour (and its fixes) live once.
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the platform share sheet with a clean "Artist — Title" message.
void shareSong(BuildContext context, Song song) {
  final l10n = AppLocalizations.of(context)!;
  final text = l10n.fpShareText(song.artist, song.title);
  Share.share(text, subject: song.title);
}

/// Opens the existing premium Sleep Timer sheet (built for Settings → Player)
/// from anywhere a [PlayerProvider] is available, e.g. the Full Player screen.
void showSleepTimerForSong(BuildContext context, PlayerProvider player) {
  final handler = player.handler;
  bool finishSong = false;
  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withAlpha(150),
    builder: (_) => SleepTimerSheet(
      engine: handler,
      finishSong: finishSong,
      onFinishSongChanged: (v) => finishSong = v,
    ),
  );
}

/// Premium song-details sheet: title, artist, album, duration, year, source.
void showSongInfoDialog(BuildContext context, Song song) {
  final l10n = AppLocalizations.of(context)!;
  final isLight = Theme.of(context).brightness == Brightness.light;
  final bgColor = isLight ? AurumTheme.lightBgCard : const Color(0xFF15131C);
  final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
  final textMuted = isLight ? AurumTheme.lightTextSecondary : Colors.white60;
  final divider = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);

  final rows = <MapEntry<String, String>>[
    MapEntry(l10n.fpSongInfoTitle, song.title),
    MapEntry(l10n.fpSongInfoArtist, song.artist),
    if (song.album.isNotEmpty) MapEntry(l10n.fpSongInfoAlbum, song.album),
    if (song.durationString.isNotEmpty) MapEntry(l10n.fpSongInfoDuration, song.durationString),
    if (song.year != null && song.year!.isNotEmpty) MapEntry(l10n.fpSongInfoYear, song.year!),
    if (song.language != null && song.language!.isNotEmpty) MapEntry(l10n.fpSongInfoLanguage, song.language!),
    // Source row intentionally omitted — backend origin (YouTube/JioSaavn/
    // Local) is an internal implementation detail and should never surface
    // in user-facing UI.
  ];

  HapticFeedback.lightImpact();
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withAlpha(150),
    builder: (_) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor.withAlpha(245),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(top: BorderSide(color: divider, width: 0.5)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36, height: 4,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: textMuted.withAlpha(80),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(Icons.info_outline_rounded, color: AurumTheme.gold, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        l10n.fpSongInfo,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  for (final row in rows) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              row.key,
                              style: TextStyle(
                                color: textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              row.value,
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (row.key != rows.last.key)
                      Divider(height: 1, color: divider),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}


class _PremiumOptionsSheet extends StatefulWidget {
  final Song song;
  final PlayerProvider player;
  final Color accentColor;
  final BuildContext rootContext;

  const _PremiumOptionsSheet({
    required this.song,
    required this.player,
    required this.accentColor,
    required this.rootContext,
  });

  @override
  State<_PremiumOptionsSheet> createState() => _PremiumOptionsSheetState();
}

class _PremiumOptionsSheetState extends State<_PremiumOptionsSheet> {
  @override
  void initState() {
    super.initState();
    SleepTimerService.instance.addListener(_onSleepTimerTick);
  }

  @override
  void dispose() {
    SleepTimerService.instance.removeListener(_onSleepTimerTick);
    super.dispose();
  }

  void _onSleepTimerTick() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  void _downloadSong() {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final downloads = context.read<DownloadProvider>();

    if (downloads.isDownloaded(song.id)) {
      _snack(l10n.fpAlreadyDownloaded);
      return;
    }
    if (downloads.isDownloading(song.id)) {
      _snack(l10n.fpAlreadyDownloading);
      return;
    }
    if (song.isLocal) {
      _snack(l10n.fpAlreadyOnDevice);
      return;
    }

    Navigator.pop(context);
    _snack(l10n.fpDownloadingSong(song.title));

    downloads.download(song).then((started) {
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l10n.fpDownloadFailed(song.title)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final song = widget.song;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final fav = context.watch<FavoritesProvider>();
    final isLiked = fav.isFavorite(song.id);
    final downloads = context.watch<DownloadProvider>();
    final dlItem = downloads.statusOf(song.id);
    final isDownloaded = downloads.isDownloaded(song.id);
    final isDownloading = downloads.isDownloading(song.id);

    final bgColor = isLight
        ? AurumTheme.lightBgCard
        : Color.lerp(widget.accentColor, const Color(0xFF0C0C18), 0.55)!;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textMuted = isLight ? AurumTheme.lightTextSecondary : Colors.white70;
    final tileColor = isLight
        ? AurumTheme.lightBgSurface
        : Colors.white.withAlpha(10);
    final tileBorder = isLight
        ? AurumTheme.lightDivider
        : Colors.white.withAlpha(18);

    final sleepActive = SleepTimerService.instance.isActive;
    final sleepRemainingLabel = sleepActive
        ? '${(SleepTimerService.instance.remaining.inSeconds / 60).ceil()}m'
        : '';

    final actions = [
      _SheetAction(Icons.skip_next_rounded, l10n.fpPlayNext, AurumTheme.gold, () {
        Navigator.pop(context);
        widget.player.playNext(song);
      }),
      _SheetAction(Icons.queue_music_rounded, l10n.fpAddToQueue, Colors.purpleAccent, () {
        Navigator.pop(context);
        widget.player.addToQueue(song);
        _snack(l10n.fpAddedToQueue);
      }),
      _SheetAction(
        isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        isLiked ? l10n.fpLiked : l10n.fpLikeAction,
        const Color(0xFFE1306C),
        () {
          PremiumGate.guard(
            context,
            feature: l10n.fpLikeSongsFeature,
            description: l10n.fpLikeSignInBuildLibrary,
            requiresLoginOnly: true,
            onAllowed: () {
              fav.toggleFavorite(song);
              final nowLiked = fav.isFavorite(song.id);
              _snack(nowLiked ? l10n.fpAddedToLiked : l10n.fpRemovedFromLiked);
            },
          );
        },
      ),
      _SheetAction(Icons.share_rounded, l10n.fpShare, Colors.greenAccent, () {
        Navigator.pop(context);
        shareSong(context, song);
      }),
      _SheetAction(Icons.playlist_add_rounded, l10n.fpSaveToPlaylist, Colors.blueAccent, () {
        Navigator.pop(context);
        showAddToPlaylistSheet(widget.rootContext, song);
      }),
      _SheetAction(Icons.equalizer_rounded, l10n.fpAudioEffects, Colors.orangeAccent, () {
        Navigator.pop(context);
        Navigator.of(widget.rootContext).push(MaterialPageRoute(
          builder: (_) => EqualizerScreen(audioEngine: widget.player.handler),
        ));
      }),
      _SheetAction(
        sleepActive ? Icons.bedtime_rounded : Icons.timer_outlined,
        sleepActive ? l10n.fpSleepRemaining(sleepRemainingLabel) : l10n.fpSleepTimer,
        Colors.cyan,
        () {
          Navigator.pop(context);
          showSleepTimerForSong(widget.rootContext, widget.player);
        },
      ),
      _SheetAction(
        isDownloaded
            ? Icons.download_done_rounded
            : isDownloading
                ? Icons.downloading_rounded
                : Icons.download_rounded,
        isDownloaded
            ? l10n.fpDownloaded
            : isDownloading
                ? l10n.fpDownloading
                : l10n.fpDownload,
        AurumTheme.gold,
        () {
          if (isDownloaded) {
            _snack(l10n.fpAlreadyDownloaded);
          } else if (isDownloading) {
            _snack(l10n.fpAlreadyDownloading);
          } else {
            _downloadSong();
          }
        },
      ),
      _SheetAction(Icons.info_outline_rounded, l10n.fpSongInfo, textMuted, () {
        Navigator.pop(context);
        showSongInfoDialog(widget.rootContext, song);
      }),
    ];

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor.withAlpha(isLight ? 240 : 245),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: isLight
                    ? AurumTheme.lightDivider
                    : Colors.white.withAlpha(14),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 16),
                  decoration: BoxDecoration(
                    color: isLight
                        ? AurumTheme.lightTextMuted.withAlpha(80)
                        : Colors.white.withAlpha(40),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Song header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AurumArtwork(url: song.artworkUrl, size: 52, borderRadius: 10),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(song.title,
                            style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 3),
                          Text(song.artist,
                            style: TextStyle(color: textMuted, fontSize: 12),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Divider(
                    color: isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14),
                    height: 1,
                  ),
                ),
                // Download progress
                if (isDownloading)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(children: [
                      Row(children: [
                        Icon(Icons.download_rounded, size: 14, color: AurumTheme.gold),
                        const SizedBox(width: 8),
                        Text('Downloading ${((dlItem?.progress ?? 0) * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: textMuted, fontSize: 12)),
                      ]),
                      const SizedBox(height: 6),
                      const AurumM3Loader(height: 3, borderRadius: 2),
                    ]),
                  ),
                // Action grid
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.7,
                    ),
                    itemCount: actions.length,
                    itemBuilder: (_, i) => _SheetActionTile(
                      action: actions[i],
                      tileColor: tileColor,
                      tileBorder: tileBorder,
                      textColor: textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetAction {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _SheetAction(this.icon, this.label, this.color, this.onTap);
}

class _SheetActionTile extends StatefulWidget {
  final _SheetAction action;
  final Color tileColor;
  final Color tileBorder;
  final Color textColor;
  const _SheetActionTile({
    required this.action,
    required this.tileColor,
    required this.tileBorder,
    required this.textColor,
  });

  @override
  State<_SheetActionTile> createState() => _SheetActionTileState();
}

class _SheetActionTileState extends State<_SheetActionTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        setState(() => _pressed = false);
        HapticFeedback.selectionClick();
        widget.action.onTap();
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          color: _pressed
              ? widget.action.color.withAlpha(isLight ? 30 : 22)
              : widget.tileColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _pressed
                ? widget.action.color.withAlpha(60)
                : widget.tileBorder,
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(widget.action.icon, size: 18, color: widget.action.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.action.label,
                style: TextStyle(
                  color: widget.textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Premium Content Panel — Queue / Lyrics / Info
// ─────────────────────────────────────────────────────────────────────────────
class _PremiumContentPanel extends StatefulWidget {
  final Color bg1, bg2, bg3;
  const _PremiumContentPanel(
      {required this.bg1, required this.bg2, required this.bg3});

  @override
  State<_PremiumContentPanel> createState() => _PremiumContentPanelState();
}

class _PremiumContentPanelState extends State<_PremiumContentPanel>
    with TickerProviderStateMixin {
  int _activeTab = 0;
  double _dragY = 0;

  late final AnimationController _tabCtrl;
  late final Animation<double> _tabFade;

  // Spring-back-to-zero controller for an aborted drag-to-dismiss.
  late final AnimationController _springBackCtrl;
  Animation<double>? _springBackAnim;

  // Reverse exit animation (translate down + fade out) played before pop.
  late final AnimationController _exitCtrl;
  late final Animation<double> _exitTranslate;
  late final Animation<double> _exitFade;

  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _tabFade = CurvedAnimation(parent: _tabCtrl, curve: Curves.easeOut);
    _tabCtrl.forward();

    _springBackCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 420));
    _springBackCtrl.addListener(() {
      if (_springBackAnim != null) {
        setState(() => _dragY = _springBackAnim!.value);
      }
    });

    _exitCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 280));
    _exitTranslate = Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInCubic));
    _exitFade = Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInCubic));
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _springBackCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  void _switchTab(int idx) {
    if (idx == _activeTab) return;
    HapticFeedback.selectionClick();
    _tabCtrl.reverse().then((_) {
      if (!mounted) return;
      setState(() => _activeTab = idx);
      _tabCtrl.forward();
    });
  }

  void _springBackToZero() {
    _springBackAnim = Tween<double>(begin: _dragY, end: 0).animate(
      CurvedAnimation(parent: _springBackCtrl, curve: Curves.elasticOut),
    );
    _springBackCtrl
      ..reset()
      ..forward();
  }

  void _dismiss() {
    if (_isDismissing) return;
    _isDismissing = true;
    HapticFeedback.lightImpact();
    _exitCtrl.forward().then((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final screenH = MediaQuery.of(context).size.height;
    final topInset = MediaQuery.of(context).padding.top;
    // Previously 0.95 * screenH — tall enough to reach almost the very top
    // of the screen, under the status bar/notch, which read as the whole
    // full player relocating upward rather than a sheet rising over it.
    // Cap it well below the safe-area top so there's always a clear gap
    // showing the full player (and status bar) behind the sheet.
    final panelHeight =
        (screenH * 0.80).clamp(360.0, screenH - topInset - 56.0);
    final dragFraction = (_dragY / screenH).clamp(0.0, 1.0);
    final dragOpacity = (1.0 - dragFraction * 2.5).clamp(0.0, 1.0);
    final scale = (1.0 - dragFraction * 0.06).clamp(0.88, 1.0);

    // Exit animation (translate down + fade) layers on top of any
    // drag-driven offset/opacity when the panel is being dismissed.
    final exitOffsetY = _exitTranslate.value * screenH * 0.4;
    final opacity = (dragOpacity * _exitFade.value).clamp(0.0, 1.0);

    // ── Theme-aware glass tint ──
    // Lowered alphas + a thin top highlight = genuine see-through glass
    // depth (you can sense the artwork/bg colors through it) instead of a
    // near-opaque tinted panel. Blur sigma is untouched (still 12) so this
    // stays just as cheap on the GPU — only the paint values changed.
    final List<Color> glassColors = isLight
        ? [
            Color.lerp(widget.bg1, Colors.white, 0.86)!.withAlpha(196),
            Color.lerp(widget.bg2, Colors.white, 0.90)!.withAlpha(204),
            Color.lerp(widget.bg3, Colors.white, 0.94)!.withAlpha(214),
          ]
        : [
            Color.lerp(widget.bg1, const Color(0xFF0A0A16), 0.5)!
                .withAlpha(168),
            Color.lerp(widget.bg2, const Color(0xFF060610), 0.5)!
                .withAlpha(180),
            Color.lerp(widget.bg3, const Color(0xFF020206), 0.6)!
                .withAlpha(198),
          ];

    final borderColor =
        isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(28);
    final highlightColor =
        isLight ? Colors.white.withAlpha(140) : Colors.white.withAlpha(40);
    final handleColor = isLight
        ? AurumTheme.lightTextMuted.withAlpha(90)
        : Colors.white.withAlpha(40);

    return AnimatedBuilder(
      animation: _exitCtrl,
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(
              0, _dragY.clamp(0.0, screenH * 0.5) + exitOffsetY),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topCenter,
            child: Opacity(
              opacity: opacity,
              child: SizedBox(
                height: panelHeight,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(32)),
                  // Lightweight glass: sigma 16 instead of 24 — still reads as
                  // frosted but noticeably cheaper on GPU. RepaintBoundary
                  // stops it from repainting on every parent rebuild (e.g.
                  // progress-bar ticks from the player above it).
                  child: RepaintBoundary(
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Stack(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(32)),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: glassColors,
                                stops: const [0.0, 0.5, 1.0],
                              ),
                              border: Border(
                                top: BorderSide(color: borderColor, width: 0.5),
                              ),
                            ),
                            child: Column(children: [
                              // Drag-to-dismiss lives ONLY on this handle strip
                              // now. Previously the whole panel (including the
                              // list) was one big GestureDetector for vertical
                              // drag, which raced the CustomScrollView for
                              // gesture-arena ownership on every drag-from-top —
                              // that's what made scrolling feel like it needed
                              // a "second pull" to actually start. Confining it
                              // to the handle means the scrollable area below
                              // has zero competing recognizers — native,
                              // instant, smooth scroll from the very first
                              // pixel of drag.
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragUpdate: (d) {
                                  if (d.delta.dy > 0) {
                                    _springBackCtrl.stop();
                                    setState(() => _dragY += d.delta.dy);
                                  }
                                },
                                onVerticalDragEnd: (d) {
                                  if (_dragY > 90 ||
                                      (d.primaryVelocity ?? 0) > 600) {
                                    _dismiss();
                                  } else {
                                    _springBackToZero();
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                      top: 12, bottom: 6),
                                  child: Container(
                                    width: 32,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: handleColor,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: FadeTransition(
                                  opacity: _tabFade,
                                  child: _buildTabContent(),
                                ),
                              ),
                              _buildTabBar(isLight),
                            ]),
                          ),
                          // Thin top edge-light — the bit of light a real
                          // glass pane catches. Pure paint, no extra blur,
                          // so it's free performance-wise.
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              height: 1,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(32)),
                                gradient: LinearGradient(
                                  colors: [
                                    highlightColor,
                                    highlightColor.withAlpha(0),
                                  ],
                                  stops: const [0.0, 1.0],
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
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabContent() {
    switch (_activeTab) {
      case 0:
        return const _QueuePage();
      case 1:
        return const _LyricsPage();
      case 2:
        return const _InfoPage();
      default:
        return const _QueuePage();
    }
  }

  Widget _buildTabBar(bool isLight) {
    final l10n = AppLocalizations.of(context)!;
    final tabs = [
      (Icons.queue_music_rounded, l10n.fpQueue),
      (Icons.lyrics_rounded, l10n.fpLyrics),
      (Icons.info_outline_rounded, l10n.fpInfo),
    ];

    final dividerColor =
        isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);
    final accent = context.watch<ThemeProvider>().accentColor;
    final inactiveColor =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(80);
    final inactiveTextColor =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(color: dividerColor, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: List.generate(tabs.length, (i) {
                final isActive = _activeTab == i;
                return Expanded(
                  child: AurumPressable(
                    scaleAmount: 0.94,
                    haptic: false,
                    onTap: () => _switchTab(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            tabs[i].$1,
                            size: 20,
                            color: isActive ? accent : inactiveColor,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tabs[i].$2,
                            style: TextStyle(
                              color: isActive
                                  ? accent
                                  : inactiveTextColor,
                              fontSize: 11,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: isActive ? 18 : 0,
                            height: 2,
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Page — Echo Nightly style
// ─────────────────────────────────────────────────────────────────────────────
class _QueuePage extends StatelessWidget {
  const _QueuePage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final mutedIcon =
        isLight ? AurumTheme.lightTextMuted.withAlpha(70) : Colors.white.withAlpha(22);
    final mutedText =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(60);

    return Selector<PlayerProvider, ({List<Song> queue, int? current})>(
      selector: (_, player) => (queue: player.queue, current: player.currentIndex),
      builder: (context, data, _) {
        final queue = data.queue;
        final current = data.current;

        if (queue.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.queue_music_rounded,
                    color: mutedIcon, size: 56),
                const SizedBox(height: 16),
                Text(
                  l10n.fpQueueEmpty,
                  style: TextStyle(
                    color: mutedText,
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          );
        }

        // Separate now playing from up next
        final upNext = <int>[];
        for (int i = 0; i < queue.length; i++) {
          if (i != current) upNext.add(i);
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Now Playing header
            if (current != null && current < queue.length)
              SliverToBoxAdapter(
                child: _NowPlayingHeader(song: queue[current]),
              ),
            // Up Next label
            if (upNext.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                  child: Text(
                    l10n.fpUpNext,
                    style: TextStyle(
                      color: mutedText,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.8,
                    ),
                  ),
                ),
              ),
            // Up next list — drag handle reorders, swipe reveals delete,
            // long-press opens quick actions. SliverReorderableList keeps
            // this on the same lightweight sliver scroll as everything
            // else above (no nested scrollables, no extra scroll
            // controller wiring needed).
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              sliver: SliverReorderableList(
                itemCount: upNext.length,
                onReorder: (oldListIdx, newListIdx) {
                  HapticFeedback.mediumImpact();
                  final fromQueueIdx = upNext[oldListIdx];
                  // ReorderableList gives newIndex assuming the item has
                  // already been removed from oldIndex — adjust the same
                  // way ReorderableListView does internally.
                  var toListIdx = newListIdx;
                  if (oldListIdx < newListIdx) toListIdx -= 1;
                  final toQueueIdx = upNext[toListIdx];
                  context.read<PlayerProvider>().moveQueueItem(fromQueueIdx, toQueueIdx);
                },
                itemBuilder: (context, listIdx) {
                  final queueIdx = upNext[listIdx];
                  final isNextUp = listIdx == 0;
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('${queue[queueIdx].id}_$queueIdx'),
                    index: listIdx,
                    child: _QueueTile(
                      song: queue[queueIdx],
                      isCurrent: false,
                      isNextUp: isNextUp,
                      index: listIdx + 1,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        context.read<PlayerProvider>().skipToIndex(queueIdx);
                      },
                      onRemove: () {
                        HapticFeedback.mediumImpact();
                        context.read<PlayerProvider>().removeFromQueue(queueIdx);
                      },
                      onPlayNext: () async {
                        HapticFeedback.selectionClick();
                        final song = queue[queueIdx];
                        final p = context.read<PlayerProvider>();
                        await p.removeFromQueue(queueIdx);
                        await p.playNext(song);
                      },
                      onMoveToTop: () {
                        HapticFeedback.selectionClick();
                        final p = context.read<PlayerProvider>();
                        final target = (p.currentIndex ?? 0) + 1;
                        p.moveQueueItem(queueIdx, target);
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Now Playing Header — large card at top of queue
// ─────────────────────────────────────────────────────────────────────────────
class _NowPlayingHeader extends StatelessWidget {
  final Song song;
  const _NowPlayingHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(110);
    final cardBg = isLight
        ? AurumTheme.gold.withAlpha(22)
        : AurumTheme.gold.withAlpha(18);
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AurumTheme.gold.withAlpha(40), width: 0.5),
        ),
        child: Row(children: [
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AurumArtwork(url: song.artworkUrl, size: 54, borderRadius: 12),
            ),
            Positioned(
              bottom: 0, right: 0,
              child: Container(
                width: 18, height: 18,
                decoration: BoxDecoration(
                  color: AurumTheme.gold,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(child: _MiniEqualizerIcon(isPlaying: isPlaying)),
              ),
            ),
          ]),
          const SizedBox(width: 14),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.fpNowPlaying,
                style: TextStyle(color: AurumTheme.gold.withAlpha(200),
                    fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.6)),
              const SizedBox(height: 3),
              Text(song.title,
                style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600, height: 1.2),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(song.artist,
                style: TextStyle(color: textSecondary, fontSize: 12),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          )),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mini Equalizer Icon — for now playing badge. Bars animate only while
// actually playing; they settle to a calm low state when paused, instead of
// endlessly bouncing regardless of playback state.
// ─────────────────────────────────────────────────────────────────────────────
class _MiniEqualizerIcon extends StatefulWidget {
  final bool isPlaying;
  const _MiniEqualizerIcon({this.isPlaying = true});

  @override
  State<_MiniEqualizerIcon> createState() => _MiniEqualizerIconState();
}

class _MiniEqualizerIconState extends State<_MiniEqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700));
    if (widget.isPlaying) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_MiniEqualizerIcon old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying && !old.isPlaying) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.isPlaying && old.isPlaying) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        // While paused, bars settle to a low static height instead of
        // freezing mid-bounce at an arbitrary point.
        final v = widget.isPlaying ? _ctrl.value : 0.0;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar(widget.isPlaying ? 0.4 + 0.6 * v : 0.3, 7),
            const SizedBox(width: 1),
            _bar(widget.isPlaying ? 0.9 - 0.5 * v : 0.45, 7),
            const SizedBox(width: 1),
            _bar(widget.isPlaying ? 0.6 + 0.4 * v : 0.3, 7),
          ],
        );
      },
    );
  }

  Widget _bar(double f, double maxH) => AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 2,
        height: maxH * f,
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(180),
          borderRadius: BorderRadius.circular(1),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Tile — Echo Nightly style with swipe-to-reveal delete + long-press
// quick actions + next-up accent highlight.
// ─────────────────────────────────────────────────────────────────────────────
class _QueueTile extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final bool isNextUp;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onPlayNext;
  final VoidCallback onMoveToTop;

  const _QueueTile({
    required this.song,
    required this.isCurrent,
    this.isNextUp = false,
    required this.index,
    required this.onTap,
    required this.onRemove,
    required this.onPlayNext,
    required this.onMoveToTop,
  });

  @override
  State<_QueueTile> createState() => _QueueTileState();
}

class _QueueTileState extends State<_QueueTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _swipeCtrl;
  late Animation<double> _settleAnim;
  double _dragOffset = 0;
  bool _swiped = false;

  static const double _deleteRevealWidth = 76.0;
  static const double _swipeOpenThreshold = 56.0;

  @override
  void initState() {
    super.initState();
    _swipeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _settleAnim = AlwaysStoppedAnimation(0.0);
  }

  @override
  void dispose() {
    _swipeCtrl.dispose();
    super.dispose();
  }

  void _handleSwipeEnd() {
    // Past the full delete-reveal width + a firm flick → remove outright.
    if (_dragOffset.abs() > _deleteRevealWidth + 30) {
      HapticFeedback.heavyImpact();
      _swiped = true;
      _swipeCtrl.forward().then((_) {
        if (mounted) widget.onRemove();
      });
      return;
    }
    // Past the open threshold → snap fully open to reveal the delete
    // button (Spotify/YT Music style), rather than springing back.
    if (_dragOffset.abs() > _swipeOpenThreshold) {
      HapticFeedback.lightImpact();
      final fromOffset = _dragOffset;
      _settleAnim = Tween<double>(begin: fromOffset, end: -_deleteRevealWidth)
          .animate(CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic));
      _swipeCtrl.forward(from: 0.0).then((_) {
        if (mounted) setState(() => _dragOffset = -_deleteRevealWidth);
        _swipeCtrl.reset();
      });
      return;
    }
    // Otherwise spring back closed.
    final fromOffset = _dragOffset;
    _settleAnim = Tween<double>(begin: fromOffset, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _dragOffset = 0);
      _swipeCtrl.reset();
    });
  }

  void _closeSwipe() {
    if (_dragOffset == 0) return;
    final fromOffset = _dragOffset;
    _settleAnim = Tween<double>(begin: fromOffset, end: 0.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeOutCubic),
    );
    _swipeCtrl.forward(from: 0.0).then((_) {
      if (mounted) setState(() => _dragOffset = 0);
      _swipeCtrl.reset();
    });
  }

  void _confirmDelete() {
    HapticFeedback.heavyImpact();
    setState(() => _swiped = true);
    widget.onRemove();
  }

  void _showQuickActions() {
    HapticFeedback.mediumImpact();
    final isLight = Theme.of(context).brightness == Brightness.light;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (sheetCtx) => _QueueQuickActionsSheet(
        song: widget.song,
        isLight: isLight,
        onPlayNext: () {
          Navigator.pop(sheetCtx);
          widget.onPlayNext();
        },
        onMoveToTop: () {
          Navigator.pop(sheetCtx);
          widget.onMoveToTop();
        },
        onRemove: () {
          Navigator.pop(sheetCtx);
          _confirmDelete();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_swiped) return const SizedBox.shrink();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _swipeCtrl,
        builder: (_, child) {
          final offset = _swiped
              ? _dragOffset
              : (_swipeCtrl.isAnimating || _dragOffset == _settleAnim.value)
                  ? _settleAnim.value
                  : _dragOffset;
          final revealFrac =
              (offset.abs() / _deleteRevealWidth).clamp(0.0, 1.0);
          return Stack(
            children: [
              // ── Delete action revealed behind the tile (Spotify/YT
              // Music style) — fades/scales in as the tile slides away,
              // never visible at rest.
              if (revealFrac > 0)
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: GestureDetector(
                          onTap: _confirmDelete,
                          child: Container(
                            width: _deleteRevealWidth - 8,
                            height: double.infinity,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Color.lerp(
                                  Colors.red.withAlpha(140),
                                  Colors.red.withAlpha(230),
                                  revealFrac),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Opacity(
                              opacity: revealFrac,
                              child: const Icon(Icons.delete_rounded,
                                  color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(offset, 0),
                child: child,
              ),
            ],
          );
        },
        child: GestureDetector(
          onTap: () {
            if (_dragOffset != 0) {
              _closeSwipe();
              return;
            }
            widget.onTap();
          },
          onLongPress: _showQuickActions,
          onHorizontalDragUpdate: (d) {
            _swipeCtrl.stop();
            setState(() {
              _dragOffset += d.delta.dx;
              _dragOffset = _dragOffset.clamp(-_deleteRevealWidth - 30, 0.0);
            });
          },
          onHorizontalDragEnd: (_) => _handleSwipeEnd(),
          child: Builder(builder: (context) {
            final tileBg = widget.isNextUp
                ? (isLight
                    ? AurumTheme.gold.withAlpha(20)
                    : AurumTheme.gold.withAlpha(16))
                : (isLight
                    ? AurumTheme.lightBgSurface.withAlpha(180)
                    : Colors.white.withAlpha(7));
            final tileBorder = widget.isNextUp
                ? AurumTheme.gold.withAlpha(isLight ? 70 : 55)
                : (isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(10));
            final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white.withAlpha(220);
            final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(80);
            final indexColor = widget.isNextUp
                ? AurumTheme.gold.withAlpha(200)
                : (isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(45));
            final dragColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(40);

            return Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: tileBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: tileBorder,
                  width: widget.isNextUp ? 1.0 : 0.5,
                ),
              ),
              child: Row(children: [
                // Subtle next-up accent bar — a quiet gradient sliver,
                // not a loud badge, so it reads as "this one's coming up"
                // without competing with the now-playing card above.
                if (widget.isNextUp)
                  Container(
                    width: 3,
                    height: 36,
                    margin: const EdgeInsets.only(right: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AurumTheme.gold.withAlpha(220),
                          AurumTheme.gold.withAlpha(90),
                        ],
                      ),
                    ),
                  ),
                SizedBox(
                  width: 22,
                  child: Text('${widget.index}',
                    style: TextStyle(color: indexColor, fontSize: 12, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center),
                ),
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(url: widget.song.artworkUrl, size: 44, borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.song.title,
                      style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(widget.song.artist,
                      style: TextStyle(color: textSecondary, fontSize: 11.5),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
                const SizedBox(width: 8),
                Icon(Icons.drag_handle_rounded, color: dragColor, size: 18),
              ]),
            );
          }),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue Quick Actions Sheet — Play Next / Move to Top / Remove
// ─────────────────────────────────────────────────────────────────────────────
class _QueueQuickActionsSheet extends StatelessWidget {
  final Song song;
  final bool isLight;
  final VoidCallback onPlayNext;
  final VoidCallback onMoveToTop;
  final VoidCallback onRemove;

  const _QueueQuickActionsSheet({
    required this.song,
    required this.isLight,
    required this.onPlayNext,
    required this.onMoveToTop,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bg = isLight ? Colors.white : const Color(0xFF15141C);
    final textPrimary = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final textSecondary = isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(120);
    final dividerColor = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(14);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AurumArtwork(url: song.artworkUrl, size: 44, borderRadius: 10),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song.title,
                      style: TextStyle(color: textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(song.artist,
                      style: TextStyle(color: textSecondary, fontSize: 12),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                )),
              ]),
            ),
            Divider(color: dividerColor, height: 1),
            _actionTile(
              icon: Icons.skip_next_rounded,
              label: l10n.fpPlayNext,
              textPrimary: textPrimary,
              onTap: onPlayNext,
            ),
            _actionTile(
              icon: Icons.vertical_align_top_rounded,
              label: l10n.fpMoveToTop,
              textPrimary: textPrimary,
              onTap: onMoveToTop,
            ),
            _actionTile(
              icon: Icons.delete_outline_rounded,
              label: l10n.fpRemoveFromQueue,
              textPrimary: Colors.redAccent,
              onTap: onRemove,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required Color textPrimary,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(children: [
          Icon(icon, color: textPrimary, size: 21),
          const SizedBox(width: 16),
          Text(label,
              style: TextStyle(
                  color: textPrimary, fontSize: 14.5, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lyrics Page
// ─────────────────────────────────────────────────────────────────────────────
class _LyricsPage extends StatefulWidget {
  const _LyricsPage();

  @override
  State<_LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<_LyricsPage> {
  LyricsResult? _result;
  bool _loading = true;
  bool _notFound = false;
  Song? _loadedFor;
  int _activeIndex = -1;

  final ItemScrollController _scrollController = ItemScrollController();
  final ItemPositionsListener _positionsListener = ItemPositionsListener.create();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _loadedFor?.id) {
      _loadedFor = song;
      _fetchLyrics();
    }
  }

  Future<void> _fetchLyrics() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _notFound = false;
      _result = null;
      _activeIndex = -1;
    });
    final result = await context.read<PlayerProvider>().fetchSyncedLyrics();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.hasAny) {
        _result = result;
      } else {
        _notFound = true;
      }
    });
  }

  void _onPositionChanged(Duration position) {
    final result = _result;
    if (result == null || !result.hasSynced) return;
    final idx = result.activeIndexFor(position);
    if (idx != _activeIndex) {
      _activeIndex = idx;
      if (idx >= 0 && _scrollController.isAttached) {
        _scrollController.scrollTo(
          index: idx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          // Keeps the active line roughly a third of the way down the
          // viewport instead of pinned to the very top.
          alignment: 0.35,
        );
      }
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final mutedIcon =
        isLight ? AurumTheme.lightTextMuted.withAlpha(80) : Colors.white.withAlpha(25);
    final primaryMuted =
        isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(140);
    final secondaryMuted =
        isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);

    Widget content;
    if (_loading) {
      content = const Center(
        key: ValueKey('loading'),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 48),
          child: AurumMorphLoader(),
        ),
      );
    } else if (_notFound) {
      content = Center(
        key: const ValueKey('not-found'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lyrics_rounded, color: mutedIcon, size: 52),
            const SizedBox(height: 16),
            Text(
              l10n.fpNoLyricsFound,
              style: TextStyle(
                color: primaryMuted,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.fpLyricsNotAvailable,
              style: TextStyle(color: secondaryMuted, fontSize: 13),
            ),
          ],
        ),
      );
    } else if (_result!.hasSynced) {
      content = _SyncedLyricsView(
        key: const ValueKey('synced-lyrics'),
        lines: _result!.synced!,
        activeIndex: _activeIndex,
        scrollController: _scrollController,
        positionsListener: _positionsListener,
        onPositionChanged: _onPositionChanged,
      );
    } else {
      content = ValueListenableBuilder<LyricsStyle>(
        valueListenable: AudioPrefs.lyricsStyleNotifier,
        builder: (context, style, _) {
          final lyricsColor =
              isLight ? AurumTheme.lightTextPrimary : Colors.white.withAlpha(200);
          return TweenAnimationBuilder<double>(
            key: const ValueKey('plain-lyrics'),
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            builder: (_, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(0, (1 - v) * 12),
                child: child,
              ),
            ),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: Text(
                _result!.plain ?? '',
                textAlign: style.position == 'Left' ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: lyricsColor,
                  fontSize: style.textSize,
                  height: style.lineSpacing,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          );
        },
      );
    }

    // Keep listening for playback position even while showing loading/
    // not-found content, so a late-arriving fetch is synced immediately.
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: content,
          ),
        ),
        Positioned.fill(
          child: _PositionListenerBridge(onPositionChanged: _onPositionChanged),
        ),
      ],
    );
  }
}

/// Invisible widget that just re-runs [onPositionChanged] whenever
/// PlayerProvider's position updates, without rebuilding the lyrics list
/// itself (that's handled manually via setState in the parent for the
/// active-line index only — avoids rebuilding all lyric rows every tick).
class _PositionListenerBridge extends StatelessWidget {
  final void Function(Duration) onPositionChanged;
  const _PositionListenerBridge({required this.onPositionChanged});

  @override
  Widget build(BuildContext context) {
    final position = context.select<PlayerProvider, Duration>((p) => p.position);
    WidgetsBinding.instance.addPostFrameCallback((_) => onPositionChanged(position));
    return const SizedBox.shrink();
  }
}

class _SyncedLyricsView extends StatelessWidget {
  final List<LyricLine> lines;
  final int activeIndex;
  final ItemScrollController scrollController;
  final ItemPositionsListener positionsListener;
  final void Function(Duration) onPositionChanged;

  const _SyncedLyricsView({
    super.key,
    required this.lines,
    required this.activeIndex,
    required this.scrollController,
    required this.positionsListener,
    required this.onPositionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return ValueListenableBuilder<LyricsStyle>(
      valueListenable: AudioPrefs.lyricsStyleNotifier,
      builder: (context, style, _) {
        final activeColor =
            isLight ? AurumTheme.lightTextPrimary : Colors.white;
        final inactiveColor = isLight
            ? AurumTheme.lightTextMuted.withAlpha(160)
            : Colors.white.withAlpha(90);

        return ScrollablePositionedList.builder(
          key: const ValueKey('synced-list'),
          itemScrollController: scrollController,
          itemPositionsListener: positionsListener,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 200),
          itemCount: lines.length,
          itemBuilder: (context, index) {
            final line = lines[index];
            final isActive = index == activeIndex;
            if (line.text.isEmpty) {
              return const SizedBox(height: 20);
            }
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.read<PlayerProvider>().seekTo(line.time),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOut,
                style: TextStyle(
                  color: isActive ? activeColor : inactiveColor,
                  fontSize: isActive ? style.textSize + 2 : style.textSize,
                  height: style.lineSpacing,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: 0.1,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    line.text,
                    textAlign:
                        style.position == 'Left' ? TextAlign.left : TextAlign.center,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Info Page
// ─────────────────────────────────────────────────────────────────────────────
class _InfoPage extends StatelessWidget {
  const _InfoPage();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return const SizedBox.shrink();

    final cardBg = isLight ? AurumTheme.lightBgSurface : Colors.white.withAlpha(7);
    final cardBorder = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(12);
    final dividerColor = isLight ? AurumTheme.lightDivider : Colors.white.withAlpha(10);
    final labelColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(70);
    final valueColor = isLight ? AurumTheme.lightTextPrimary : Colors.white;

    final rows = <_InfoRow>[];
    if (song.album.isNotEmpty) rows.add(_InfoRow(l10n.fpSongInfoAlbum, song.album));
    if (song.artist.isNotEmpty) rows.add(_InfoRow(l10n.fpSongInfoArtist, song.artist));
    if (song.year != null && song.year!.isNotEmpty) {
      rows.add(_InfoRow(l10n.fpSongInfoYear, song.year!));
    }
    if (song.language != null && song.language!.isNotEmpty) {
      rows.add(_InfoRow(l10n.fpSongInfoLanguage, song.language!));
    }
    if (song.duration != null) {
      rows.add(_InfoRow(l10n.fpSongInfoDuration, song.durationString));
    }
    rows.add(_InfoRow(l10n.fpSourceLabel, song.isLocal ? l10n.fpLocalLibrary : l10n.fpOnlineStream));

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        _InfoHeader(song: song),
        const SizedBox(height: 24),
        Container(
          decoration: BoxDecoration(
            color: cardBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cardBorder, width: 0.5),
          ),
          child: Column(
            children: List.generate(rows.length, (i) {
              return Column(children: [
                _buildInfoRow(rows[i].label, rows[i].value, labelColor, valueColor),
                if (i < rows.length - 1)
                  Divider(
                    color: dividerColor,
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                  ),
              ]);
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value, Color labelColor, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: labelColor,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoHeader extends StatelessWidget {
  final Song song;
  const _InfoHeader({required this.song});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final titleColor = isLight ? AurumTheme.lightTextPrimary : Colors.white;
    final artistColor = isLight ? AurumTheme.lightTextMuted : Colors.white.withAlpha(120);

    return Row(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AurumArtwork(url: song.artworkUrl, size: 72, borderRadius: 14),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              song.title,
              style: TextStyle(
                color: titleColor,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              song.artist,
              style: TextStyle(
                color: artistColor,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    ]);
  }
}

class _InfoRow {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
}

// ─────────────────────────────────────────────────────────────────────────────
// _BgLayer — Flagship quality background
//
// Architecture (GPU-budget aware):
//   Layer 0: Solid base color (0 cost)
//   Layer 1: Blurred artwork — rendered ONCE via ImageFiltered, no reblur on anim
//   Layer 2: Gradient overlay — cheap Container, no blur
//   Layer 3: 3 ambient glow orbs via CustomPainter (drawOval, no shader)
//   Layer 4: Vignette gradient — cheap Container
//
// Single AnimationController drives everything via AnimatedBuilder.
// RepaintBoundary isolates all repaints from parent tree.
// ─────────────────────────────────────────────────────────────────────────────
class _BgLayer extends StatelessWidget {
  final Song song;
  final AnimationController bgCtrl;
  final AnimationController breatheCtrl;
  final Color startBg1, startBg2, startBg3, startBg4;
  final Color targetBg1, targetBg2, targetBg3, targetBg4;

  const _BgLayer({
    required this.song,
    required this.bgCtrl,
    required this.breatheCtrl,
    required this.startBg1,
    required this.startBg2,
    required this.startBg3,
    required this.startBg4,
    required this.targetBg1,
    required this.targetBg2,
    required this.targetBg3,
    required this.targetBg4,
  });

  // FIX (lag): this used to be built entirely inside the AnimatedBuilder
  // driven by the breathe controller (18s continuous loop). That forced
  // the 40-42σ blurred-artwork layer — the most expensive single paint
  // op on this whole screen — to rebuild its widget subtree 60 times a
  // second, forever, any time the full player was on screen, whether or
  // not the song ever changed. RepaintBoundary alone doesn't prevent that
  // rebuild cost; only building it outside the animated scope does.
  //
  // Now: the blurred artwork is built ONCE per song (via a ValueKey on
  // song.id + bg1, so it only rebuilds on an actual track/palette change),
  // and only the cheap orb/gradient/vignette layers sit inside the
  // breathe-driven AnimatedBuilder.
  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;

    return AnimatedBuilder(
      animation: bgCtrl,
      builder: (context, _) {
        final t = bgCtrl.value; // 0→1: song change morph
        final bg1 = Color.lerp(startBg1, targetBg1, t)!;
        final bg2 = Color.lerp(startBg2, targetBg2, t)!;
        final bg3 = Color.lerp(startBg3, targetBg3, t)!;
        final bg4 = Color.lerp(startBg4, targetBg4, t)!;

        final staticBlur = _StaticBlurArtwork(
          key: ValueKey('${song.id}_${song.artworkUrl}'),
          song: song,
          isLight: isLight,
        );

        return isLight
            ? _buildLight(bg1, bg2, bg3, bg4, staticBlur)
            : _buildDark(bg1, bg2, bg3, bg4, staticBlur);
      },
    );
  }

  // ── LIGHT MODE ── artwork color reads through clearly, just enough
  // warm-white lift to keep the "light mode" feel and text legible.
  Widget _buildLight(Color bg1, Color bg2, Color bg3, Color bg4, Widget staticBlur) {
    final dynamicColor = AudioPrefs.dynamicPlayerColorNotifier.value;
    final bgStyle = AudioPrefs.playerBgStyleNotifier.value;
    if (!dynamicColor) {
      bg1 = Color.lerp(AurumTheme.gold, Colors.white, 0.52)!;
      bg2 = Color.lerp(AurumTheme.goldDark, Colors.white, 0.44)!;
      bg3 = Color.lerp(AurumTheme.goldDark, Colors.white, 0.35)!;
      bg4 = Color.lerp(AurumTheme.goldLight, Colors.white, 0.58)!;
    }

    if (bgStyle == 'Solid') return ColoredBox(color: bg1);

    // L1 (static blur) is passed in pre-built and does NOT rebuild on the
    // breathe tick anymore — only L3 (orbs) sits inside the AnimatedBuilder.
    return Stack(fit: StackFit.expand, children: [
      // L0: Neutral warm-grey base (was near-white — that pre-tinted
      // everything before the artwork colour even landed, which is what
      // made light mode read as washed out regardless of the art).
      const ColoredBox(color: Color(0xFFEDE9E2)),

      // L1: Artwork fills screen — blurred into color atmosphere. Built
      // once per song, not every breathe frame.
      staticBlur,

      // L2: Barely-there white lift — was strong enough before to flatten
      // the artwork's actual saturation. Cut way down so colour carries.
      const RepaintBoundary(child: ColoredBox(color: Color(0x0AFFFFFF))),

      // L3: Ambient glow orbs — the only layer that actually needs to
      // rebuild on every breathe tick, isolated in its own AnimatedBuilder.
      RepaintBoundary(
        child: AnimatedBuilder(
          animation: breatheCtrl,
          builder: (context, _) {
            final bRaw = (AudioPrefs.enableAnimationsNotifier.value &&
                    AudioPrefs.bgGradientAnimationNotifier.value)
                ? breatheCtrl.value
                : 0.5;
            final b = Curves.easeInOut.transform(bRaw);
            return CustomPaint(
              painter: _AmbientGlowPainter(
                color1: bg1, color2: bg4, color3: bg2,
                breathe: b, isLight: true,
              ),
              size: Size.infinite,
            );
          },
        ),
      ),

      // L4: Vignette for text readability — tightened to the very edges
      // only (was a broad, strong white gradient eating into the middle
      // of the artwork colour; now it only does its job at the top/bottom
      // safe zones where text actually sits).
      const RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x3DFFFFFF),
                Colors.transparent,
                Colors.transparent,
                Color(0x4EFFFFFF),
              ],
              stops: [0.0, 0.09, 0.78, 1.0],
            ),
          ),
        ),
      ),
    ]);
  }

  // ── DARK MODE ── Echo Nightly spec: artwork IS the background
  Widget _buildDark(Color bg1, Color bg2, Color bg3, Color bg4, Widget staticBlur) {
    final dynamicColor = AudioPrefs.dynamicPlayerColorNotifier.value;
    final bgStyle = AudioPrefs.playerBgStyleNotifier.value;
    if (!dynamicColor) {
      bg1 = Color.lerp(AurumTheme.gold, Colors.black, 0.35)!;
      bg2 = Color.lerp(AurumTheme.goldDark, Colors.black, 0.58)!;
      bg3 = Color.lerp(AurumTheme.goldDark, Colors.black, 0.78)!;
      bg4 = Color.lerp(AurumTheme.goldLight, Colors.black, 0.42)!;
    }

    if (bgStyle == 'Solid') {
      return ColoredBox(color: Color.lerp(bg1, Colors.black, 0.35)!);
    }

    // L1 (static blur) is passed in pre-built — no longer recomposites on
    // every breathe tick. Only L2 (gradient tint, whose center drifts
    // slightly) and L3 (orbs) still need the live breathe value.
    return Stack(fit: StackFit.expand, children: [
      // L0: Pure black base
      const ColoredBox(color: Color(0xFF000000)),

      // L1: Artwork fills entire background — built once per song.
      staticBlur,

      // L2 + L3: everything that actually needs the breathe value, in one
      // shared AnimatedBuilder so there's a single rebuild per tick
      // instead of two separate ones.
      RepaintBoundary(
        child: AnimatedBuilder(
          animation: breatheCtrl,
          builder: (context, _) {
            final bRaw = (AudioPrefs.enableAnimationsNotifier.value &&
                    AudioPrefs.bgGradientAnimationNotifier.value)
                ? breatheCtrl.value
                : 0.5;
            final b = Curves.easeInOut.transform(bRaw);
            return Stack(fit: StackFit.expand, children: [
              // Color palette gradient tint — deepens the artwork colors
              // so they stay saturated even on AMOLED.
              if (bgStyle != 'Gradient')
                Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(-0.25 + b * 0.08, -0.55),
                      radius: 1.35,
                      colors: [
                        bg1.withAlpha(130),
                        bg2.withAlpha(90),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              // Ambient glow orbs — palette-colored soft blobs
              CustomPaint(
                painter: _AmbientGlowPainter(
                  color1: bg1,
                  color2: bg4,
                  color3: bg2,
                  breathe: b,
                  isLight: false,
                ),
                size: Size.infinite,
              ),
            ]);
          },
        ),
      ),

      // L4: Vignette — keeps text perfectly readable. Static, never
      // needs to rebuild.
      //     Top: darkened for status bar / drag handle
      //     Bottom: heavy dark gradient so controls pop
      const RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xA0000000),
                Colors.transparent,
                Colors.transparent,
                Color(0xD2000000),
              ],
              stops: [0.0, 0.18, 0.60, 1.0],
            ),
          ),
        ),
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _StaticBlurArtwork — built once per song (keyed on song id + artwork url)
// instead of every breathe-controller tick. This single change removes the
// majority of the full player's idle GPU cost, since this was previously
// rebuilding 60x/sec forever.
//
// BUGFIX (perf): sigma was 40-42, which on a 1.55x-scaled full-screen layer
// is one of the single most expensive paint ops Flutter can do on a mobile
// GPU — this alone was responsible for the visible stall on full-player
// open and the stutter on every song change/skip (the layer is rebuilt
// once per song, so every song change re-paid this cost). Dropped to
// 20/22σ: after the 1.55x scale-up and the existing 220px capped decode
// (see AurumArtwork._cacheSize), detail is already destroyed well before
// 40σ — visually the two are effectively indistinguishable, but 20-22σ is
// roughly a quarter of the GPU cost.
//
// Also: AurumArtwork's CachedNetworkImage normally fades in over 280ms —
// fine for artwork you look at directly, but wasteful here since this
// layer sits under Opacity(~0.88) and a blur filter, both of which hide
// any pop-in anyway. Every frame of that 280ms fade was forcing Flutter to
// re-composite the blur, on top of the blur's own per-song cost. Passing
// fadeIn: false skips that animation for this specific instance only.
// ─────────────────────────────────────────────────────────────────────────────
class _StaticBlurArtwork extends StatelessWidget {
  final Song song;
  final bool isLight;

  const _StaticBlurArtwork({super.key, required this.song, required this.isLight});

  @override
  Widget build(BuildContext context) {
    if (song.artworkUrl.isEmpty) return const SizedBox.shrink();
    return RepaintBoundary(
      child: Opacity(
        opacity: isLight ? 0.90 : 0.88,
        child: Transform.scale(
          scale: 1.55,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(
              sigmaX: isLight ? 20 : 22,
              sigmaY: isLight ? 20 : 22,
              tileMode: TileMode.clamp,
            ),
            child: AurumArtwork(
              url: song.artworkUrl,
              size: double.infinity,
              borderRadius: 0,
              fadeIn: false,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AmbientGlowPainter — 3 soft drifting orbs, CustomPainter, zero blur cost
//
// Uses drawOval with radial gradient paint.
// Orbs drift on Lissajous-like paths (sin/cos offsets) for organic motion.
// shouldRepaint only triggers when breathe value changes meaningfully.
// ─────────────────────────────────────────────────────────────────────────────
class _AmbientGlowPainter extends CustomPainter {
  final Color color1, color2, color3;
  final double breathe; // 0.0 → 1.0 → 0.0
  final bool isLight;

  const _AmbientGlowPainter({
    required this.color1,
    required this.color2,
    required this.color3,
    required this.breathe,
    required this.isLight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final b = breathe;

    // Echo Nightly spec: large saturated orbs that own the whole canvas.
    // Dark mode: stronger alpha — the background IS the orb color.
    // Light mode: softer, warm.
    final baseAlpha = isLight ? 62 : 52;

    // ── Orb 1: Upper-left, primary palette color — dominates top half ──
    _drawOrb(
      canvas,
      center: Offset(w * (0.12 + b * 0.08), h * (0.08 + b * 0.06)),
      radiusX: w * 0.75,
      radiusY: h * 0.52,
      color: color1.withAlpha(baseAlpha + (b * 14).toInt()),
    );

    // ── Orb 2: Bottom-right, secondary color — dominates lower half ──
    _drawOrb(
      canvas,
      center: Offset(w * (0.92 - b * 0.07), h * (0.82 - b * 0.05)),
      radiusX: w * 0.70,
      radiusY: h * 0.48,
      color: color2.withAlpha(baseAlpha - 6 + (b * 10).toInt()),
    );

    // ── Orb 3: Center, tertiary — ties the two together ──
    _drawOrb(
      canvas,
      center: Offset(w * (0.48 + b * 0.04), h * (0.44 - b * 0.03)),
      radiusX: w * (0.50 + b * 0.08),
      radiusY: h * (0.36 + b * 0.06),
      color: color3.withAlpha(baseAlpha - 18 + (b * 8).toInt()),
    );
  }

  void _drawOrb(
    Canvas canvas, {
    required Offset center,
    required double radiusX,
    required double radiusY,
    required Color color,
  }) {
    final rect = Rect.fromCenter(
        center: center, width: radiusX * 2, height: radiusY * 2);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withAlpha(0)],
        stops: const [0.0, 1.0],
      ).createShader(rect)
      ..blendMode = BlendMode.srcOver;
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(_AmbientGlowPainter old) =>
      (breathe - old.breathe).abs() > 0.004 ||
      color1 != old.color1 ||
      color2 != old.color2 ||
      color3 != old.color3;
}

// ─────────────────────────────────────────────────────────────────────────────
// Marquee Text
// ─────────────────────────────────────────────────────────────────────────────
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scrollAnim;
  bool _overflowing = false;

  // Cached TextPainter + the (text, style) it was built for. Rebuilding
  // and re-laying-out a TextPainter on every animation tick (60/sec while
  // scrolling) was a real perf hit — measurable jank that made drag
  // gestures on this screen feel like they were dropping frames /
  // "auto-snapping". Now layout only runs when the text or style
  // actually changes.
  TextPainter? _tp;
  String? _tpText;
  TextStyle? _tpStyle;

  TextPainter _painterFor(String text, TextStyle style) {
    if (_tp != null && _tpText == text && _tpStyle == style) return _tp!;
    _tpText = text;
    _tpStyle = style;
    _tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    return _tp!;
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 10500));
    _scrollAnim = CurvedAnimation(
      parent: _ctrl,
      curve: const Interval(0.0, 0.857, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final tp = _painterFor(widget.text, widget.style);

      final overflow = tp.width > constraints.maxWidth;

      if (overflow != _overflowing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _overflowing = overflow);
          if (overflow) {
            _ctrl.repeat();
          } else {
            _ctrl.stop();
            _ctrl.reset();
          }
        });
      }

      if (!overflow) {
        return Text(widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis);
      }

      return ShaderMask(
        shaderCallback: (rect) => const LinearGradient(
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent
          ],
          stops: [0.0, 0.04, 0.92, 1.0],
        ).createShader(rect),
        blendMode: BlendMode.dstIn,
        child: SizedBox(
          height: tp.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                final shift = -(tp.width + 40) * _scrollAnim.value;
                return Stack(children: [
                  Positioned(
                      left: shift,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                  Positioned(
                      left: shift + tp.width + 40,
                      child: Text(widget.text,
                          style: widget.style, maxLines: 1, softWrap: false)),
                ]);
              },
            ),
          ),
        ),
      );
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Buffered Track Shape
// ─────────────────────────────────────────────────────────────────────────────
class _BufferedTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(context, offset,
        parentBox: parentBox,
        sliderTheme: sliderTheme,
        enableAnimation: enableAnimation,
        textDirection: textDirection,
        thumbCenter: thumbCenter,
        secondaryOffset: secondaryOffset,
        isDiscrete: isDiscrete,
        isEnabled: isEnabled,
        additionalActiveTrackHeight: additionalActiveTrackHeight);

    if (secondaryOffset != null) {
      final trackRect = getPreferredRect(
          parentBox: parentBox,
          offset: offset,
          sliderTheme: sliderTheme,
          isEnabled: isEnabled,
          isDiscrete: isDiscrete);
      final paint = Paint()
        ..color = Colors.white.withAlpha(40)
        ..style = PaintingStyle.fill;
      final bufferedRect = Rect.fromLTRB(
          trackRect.left, trackRect.top, secondaryOffset.dx, trackRect.bottom);
      context.canvas.drawRRect(
          RRect.fromRectAndRadius(bufferedRect, const Radius.circular(2)),
          paint);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Equalizer Icon — animated bars
// ─────────────────────────────────────────────────────────────────────────────
class _EqualizerIcon extends StatefulWidget {
  const _EqualizerIcon();

  @override
  State<_EqualizerIcon> createState() => _EqualizerIconState();
}

class _EqualizerIconState extends State<_EqualizerIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final v = _ctrl.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(0.3 + 0.7 * v),
              _bar(0.8 - 0.6 * v),
              _bar(0.5 + 0.5 * v),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double f) => Container(
        width: 3.5,
        height: 18 * f,
        decoration: BoxDecoration(
          color: AurumTheme.gold,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Icon Button
// ─────────────────────────────────────────────────────────────────────────────
class _IconBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final Color? color;
  final String? semanticLabel;

  const _IconBtn({
    required this.icon,
    required this.size,
    required this.onTap,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final c = color ?? (isLight ? AurumTheme.lightTextSecondary : Colors.white.withAlpha(200));
    return Semantics(
      label: semanticLabel,
      button: true,
      child: AurumPressable(
        scaleAmount: 0.85,
        haptic: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: size, color: c),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Control Button
// ─────────────────────────────────────────────────────────────────────────────
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool active;
  final Color? color;
  final String? semanticLabel;
  final VoidCallback onTap;

  const _CtrlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
    this.active = false,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final inactiveColor = isLight
        ? AurumTheme.lightTextMuted
        : Colors.white.withAlpha(100);
    final c = color ?? (active ? AurumTheme.gold : inactiveColor);
    return Semantics(
      label: semanticLabel,
      button: true,
      child: AurumPressable(
        scaleAmount: 0.85,
        haptic: false, // callers already fire their own haptic per action
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: size, color: c),
        ),
      ),
    );
  }
}
