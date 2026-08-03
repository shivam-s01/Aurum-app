import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/aurum_theme.dart';
import 'aurum_artwork.dart';
import 'aurum_pressable.dart';
import '../screens/full_player_screen.dart';
import '../main.dart' show aurumRouteObserver;
import '../utils/aurum_haptics.dart';
import '../services/audio_prefs.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> with RouteAware {
  double _dragY = 0;
  bool _dragging = false;

  // FIX ("back navigation feels stuck/slow/janky on EVERY screen"): the
  // mini player sits as a persistent overlay on every screen (home,
  // library, search, settings, ...) and renders its background via
  // BackdropFilter(ImageFilter.blur(sigmaX: 14, sigmaY: 14)). A
  // BackdropFilter has to re-sample and re-blur everything behind it on
  // EVERY frame it's asked to paint — it can't cache the blurred result,
  // because the content behind it can change. That's normally fine when
  // the screen is static. But during ANY push/pop transition, the whole
  // screen behind the mini player is sliding/fading every frame, which
  // means the expensive 14px-radius blur is being fully recomputed on
  // every single frame of the transition too — competing with the actual
  // transition animation for GPU time. That contention is exactly what
  // reads as "slow/awkward/stuck," and because the mini player is on
  // every screen, it happens on every back navigation, not just one
  // screen.
  //
  // MiniPlayer lives inside MainShell's bottomNavigationBar — MainShell
  // itself never transitions when e.g. Settings is pushed on top of it,
  // so ModalRoute.of(context) from inside MiniPlayer would always report
  // MainShell's own (never-animating) route, not whatever screen is
  // actually being pushed/popped. Subscribing to the app-wide
  // aurumRouteObserver instead (same pattern FullPlayerScreen already
  // uses for its own didPushNext/didPopNext) correctly reports ANY route
  // change above MainShell.
  bool _routeAnimating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      aurumRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    aurumRouteObserver.unsubscribe(this);
    super.dispose();
  }

  // A new route (Settings, Full Player, etc.) was just pushed on top of
  // MainShell — its push transition is about to animate, so drop to the
  // cheap tint immediately.
  @override
  void didPushNext() {
    if (mounted) setState(() => _routeAnimating = true);
    // Every close/open transition in this app uses AurumMotion.long1
    // (350ms) per aurum_transitions.dart. A short buffer (60ms) absorbs
    // minor scheduling jitter so this never restores the real blur a
    // frame or two before the transition has actually finished painting.
    Future.delayed(const Duration(milliseconds: 410), () {
      if (mounted) setState(() => _routeAnimating = false);
    });
  }

  // A route above MainShell was just popped (user backed out of
  // Settings/Full Player/etc.) — the reverse transition is about to
  // animate too.
  @override
  void didPopNext() {
    if (mounted) setState(() => _routeAnimating = true);
    Future.delayed(const Duration(milliseconds: 410), () {
      if (mounted) setState(() => _routeAnimating = false);
    });
  }

  static const double _dismissThreshold = 64.0;
  static const double _openThreshold = -60.0;

  // FIX (tap sometimes does nothing / feels random): onTap and
  // onVerticalDrag* used to sit on the SAME GestureDetector. Flutter's
  // gesture arena treats any tap with even a pixel or two of finger
  // movement — extremely common on a real screen, not a lab-perfect
  // tap — as a drag win, not a tap win. That silently ate a large
  // fraction of taps, which is exactly why it felt inconsistent rather
  // than reliably broken. Fix: don't register a separate onTap at all.
  // Track whether the gesture ever moved past a tiny slop; if it didn't,
  // treat the vertical-drag-end as a tap. One recognizer, one decision,
  // every gesture resolves predictably.
  double _totalMovement = 0;

  void _onDragStart(DragStartDetails d) {
    _totalMovement = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _totalMovement += d.delta.dy.abs();
    setState(() {
      _dragging = true;
      _dragY = (_dragY + d.delta.dy).clamp(-120.0, 160.0);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final velocity = d.primaryVelocity ?? 0;
    final y = _dragY;
    final wasBasicallyATap = _totalMovement < 8 && velocity.abs() < 200;
    setState(() {
      _dragging = false;
      _dragY = 0;
    });

    if (wasBasicallyATap) {
      _openFullPlayer();
      return;
    }
    if (y < _openThreshold || velocity < -400) {
      _openFullPlayer();
      return;
    }
    if (y > _dismissThreshold || velocity > 400) {
      AurumHaptics.medium();
      final player = context.read<PlayerProvider>();
      player.pause();
      player.dismissMiniPlayer();
    }
  }

  bool _opening = false;
  void _openFullPlayer() {
    if (_opening) return;
    _opening = true;
    AurumHaptics.light();

    // FIX ("artwork pops in after full player is already open"): the mini
    // player's own AurumArtwork decodes at a small size (44-108px
    // memCacheWidth), but the full player's hero artwork passes
    // size: double.infinity, which AurumArtwork._cacheSize maps to a fixed
    // 220px decode. That's a DIFFERENT memCacheWidth than the mini
    // player's — Flutter's image cache keys on (url, cacheWidth), so even
    // though the bytes are already on disk, the 220px-wide decode has
    // never happened yet and only starts once FullPlayerScreen actually
    // builds. That decode (plus a network round-trip if disk cache also
    // misses) is what shows up as the shimmer-then-pop-in during/after the
    // slide-up transition.
    // Kicking off that exact same 220px precache HERE, before the route
    // push, means the decode races the 380ms slide transition instead of
    // the user's patience — by the time the screen is visible the image
    // is already sitting in the in-memory cache and paints on the very
    // first frame.
    final artworkUrl = context.read<PlayerProvider>().currentSong?.artworkUrl;
    if (artworkUrl != null &&
        artworkUrl.isNotEmpty &&
        !artworkUrl.startsWith('content://') &&
        !artworkUrl.startsWith('/') &&
        !artworkUrl.startsWith('file://')) {
      precacheImage(
        CachedNetworkImageProvider(artworkUrl, maxWidth: 220),
        context,
      ).catchError((_) {
        // Fine to ignore — FullPlayerScreen's own AurumArtwork still
        // handles the fetch/retry/placeholder path normally if this
        // opportunistic precache fails for any reason.
      });
    }

    Navigator.of(context)
        .push(
      PageRouteBuilder(
        // FIX (background screen glitches/blinks during swipe-down-to-
        // dismiss): see the full explanation in home_screen.dart's
        // pushFullPlayer() — opaque:true stopped Flutter from actively
        // repainting whatever's underneath while FullPlayerScreen sits on
        // top, so its drag-to-dismiss fade briefly exposed a frozen frame
        // instead of a live one on every drag update.
        opaque: false,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        // FIX ("full player looks like a flat theme-colored screen for
        // 1-2s on open AND on swipe-down-close"): see the matching fix
        // (and full reasoning) in home_screen.dart's pushFullPlayer() —
        // FullPlayerScreen already paints its own opaque, theme-correct
        // background on its first frame, so wrapping it in a separate
        // flat ColoredBox here was redundant and is exactly what showed
        // through as an untinted flat color covering the whole screen
        // during the entire transition, both directions (this route's
        // reverseTransitionDuration below reuses this same builder for
        // the swipe-down dismiss).
        transitionsBuilder: (context, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 380),
        // FIX ("back feels stuck/not smooth"): matched to the forward
        // duration above — was 300ms vs 380ms open (same root-cause fix
        // as aurum_transitions.dart).
        reverseTransitionDuration: const Duration(milliseconds: 380),
      ),
    )
        .then((_) => _opening = false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.miniPlayerVisible || player.currentSong == null) {
          return const SizedBox.shrink();
        }

        final frac = (_dragY.abs() / 160.0).clamp(0.0, 1.0);
        final opacity = _dragging ? (1.0 - frac * 0.6).clamp(0.0, 1.0) : 1.0;
        final translateY = _dragging ? _dragY.clamp(-60.0, 200.0) : 0.0;

        return GestureDetector(
          onVerticalDragStart: _onDragStart,
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Opacity(
              opacity: opacity,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: _routeAnimating
                      ? Container(
                          height: 68,
                          decoration: BoxDecoration(
                            // FIX ("glass flash for ~0.1s on full player
                            // swipe-down close"): this fallback tint's alpha
                            // (0.62 dark / 0.82 light) was noticeably more
                            // opaque than the real blurred mini player's
                            // steady-state alpha (0.42 dark / 0.62 light,
                            // see the ValueListenableBuilder branch below).
                            // For ~410ms after didPopNext() fires, the mini
                            // player shows THIS more-opaque flat tint, then
                            // the instant _routeAnimating flips back to
                            // false it snaps to the lighter, more
                            // translucent blurred version — that mismatch
                            // is exactly what read as a brief "glass"
                            // flash. Matched to the same alpha as the real
                            // blurred state so the switch between the two
                            // is visually seamless.
                            color: (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.black
                                    : Colors.white)
                                .withValues(
                              alpha: Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? 0.42
                                  : 0.62,
                            ),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black)
                                  .withValues(alpha: 0.08),
                              width: 1,
                            ),
                          ),
                          child: _miniPlayerContent(context, player),
                        )
                      : ValueListenableBuilder<double>(
                          valueListenable: AudioPrefs.miniPlayerBlurSigmaNotifier,
                          builder: (context, blurSigma, _) {
                            // blurSigma <= 0 means the user explicitly
                            // turned blur OFF (Settings → Appearance →
                            // "Mini Player Blur" dragged to 0). That should
                            // read as a fully solid, opaque bar — not a
                            // translucent "glass without the blur" look —
                            // so nothing behind it shows through at all.
                            // Only the blurred variant keeps the
                            // semi-transparent tint that lets
                            // BackdropFilter's blur actually be visible.
                            final content = Container(
                              height: 68,
                              decoration: BoxDecoration(
                                color: blurSigma <= 0
                                    ? AurumTheme.bgCardOf(context)
                                    : (Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.black
                                            : Colors.white)
                                        .withValues(
                                        alpha: Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? 0.42
                                            : 0.62,
                                      ),
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: (Theme.of(context).brightness ==
                                              Brightness.dark
                                          ? Colors.white
                                          : Colors.black)
                                      .withValues(alpha: 0.08),
                                  width: 1,
                                ),
                              ),
                              child: _miniPlayerContent(context, player),
                            );
                            // PERF/HEAT SETTING: mini player is a persistent
                            // overlay on every screen, so its BackdropFilter
                            // blur runs on every frame it's visible — real,
                            // continuous GPU cost. sigma == 0 (user set via
                            // Settings → Appearance → "Mini Player Blur")
                            // skips BackdropFilter entirely for the cheapest
                            // possible steady-state render.
                            if (blurSigma <= 0) return content;
                            return BackdropFilter(
                              filter: ImageFilter.blur(
                                  sigmaX: blurSigma, sigmaY: blurSigma),
                              child: content,
                            );
                          },
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The mini player's actual row content (progress bar, artwork, title/
  /// artist, transport controls) — shared between the normal BackdropFilter
  /// path and the cheap-tint fallback used while a route transition is in
  /// flight (see _routeAnimating above).
  Widget _miniPlayerContent(BuildContext context, PlayerProvider player) {
    final song = player.currentSong!;
    return Column(
      children: [
        _MiniProgressBar(player: player),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                AurumArtwork(
                  url: song.artworkUrl,
                  size: 44,
                  borderRadius: 10,
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
                    AurumHaptics.selection();
                    player.skipPrev();
                  },
                  size: 22,
                ),
                const SizedBox(width: 4),
                _PlayBtn(player: player),
                const SizedBox(width: 4),
                _ControlBtn(
                  icon: Icons.skip_next_rounded,
                  onTap: () {
                    AurumHaptics.selection();
                    player.skipNext();
                  },
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniProgressBar extends StatelessWidget {
  final PlayerProvider player;
  const _MiniProgressBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, double>(
      selector: (_, p) => p.progress,
      builder: (context, progress, _) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: RepaintBoundary(
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: Colors.transparent,
            valueColor: const AlwaysStoppedAnimation<Color>(AurumTheme.gold),
            minHeight: 2,
          ),
        ),
      ),
    );
  }
}

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
        AurumHaptics.heavy();
        player.togglePlay();
      },
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: accent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          // FIX: was hardcoded AurumTheme.bg (always the app's dark
          // background color), which reads fine against a light accent
          // but goes near-invisible if the user picks a dark accent
          // color in Settings → Appearance — dark icon on a dark circle.
          // Deriving black/white from the accent's own luminance
          // guarantees the icon stays visible against whatever color
          // is actually behind it.
          color: accent.computeLuminance() > 0.5 ? Colors.black : Colors.white,
          size: 20,
        ),
      ),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _ControlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
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
