import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../utils/artwork_palette_cache.dart';
import 'aurum_artwork.dart';
import 'aurum_pressable.dart';
import '../screens/home_screen.dart' show pushFullPlayer;
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

  // Spotify-style artwork-tinted background. Reuses the SAME palette
  // cache Full Player already populates (see artwork_palette_cache.dart)
  // — by the time a song is playing, Full Player (or the queue pre-warm)
  // has almost always already extracted and cached its palette, so this
  // is a near-zero-cost cache hit (peek()), not a fresh decode. No
  // AnimationController involved: the color transition between songs is
  // driven by a TweenAnimationBuilder, which only runs its short 420ms
  // tween while a song change is actually in flight and is fully idle
  // (zero ticks) the rest of the time — keeping the mini player's
  // steady-state cost at zero extra animation work.
  Color? _tintColor;
  String? _tintForUrl;

  void _syncTintForSong(Song? song) {
    final url = song?.artworkUrl;
    if (url == _tintForUrl) return;
    _tintForUrl = url;
    if (url == null || url.isEmpty || !url.startsWith('http')) {
      if (mounted) setState(() => _tintColor = null);
      return;
    }
    // Instant path: Full Player almost always already cached this exact
    // song's palette (it's playing, after all). No async gap, no flash.
    final cached = ArtworkPaletteCache.peek(url);
    if (cached != null) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      if (mounted) {
        setState(() => _tintColor = ensureContrastSafe(
            isDark ? cached.darkMuted : cached.lightVibrant,
            isLight: !isDark));
      }
      return;
    }
    // Cold path (rare — e.g. app cold-started straight into a playing
    // song before Full Player has ever been opened): extract once,
    // cached for every future look so this only happens per-song, ever.
    ArtworkPaletteCache.get(url).then((p) {
      if (!mounted || _tintForUrl != url) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      setState(() => _tintColor =
          ensureContrastSafe(isDark ? p.darkMuted : p.lightVibrant, isLight: !isDark));
    });
  }

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
  // FIX ("kabhi kabhi mini player poora stuck ho jata hai"): didPushNext
  // and didPopNext each schedule their own Future.delayed to flip
  // _routeAnimating back to false. If the user navigates quickly — pushes
  // Settings, then immediately backs out again before the first 410ms
  // timer has fired — the OLD timer from the push is still pending when
  // the pop's own 80ms timer fires and clears it first; then the old
  // push timer fires afterward and sets _routeAnimating = true again,
  // this time with no future timer left to ever clear it. The mini
  // player is then stuck showing the cheap flat-tint fallback (visually
  // "frozen") until some unrelated rebuild happens to reset it. Giving
  // each scheduled callback its own generation token means a stale timer
  // from a superseded navigation can no longer stomp on a newer one.
  int _routeAnimGen = 0;

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
    final gen = ++_routeAnimGen;
    if (mounted) setState(() => _routeAnimating = true);
    // Every close/open transition in this app uses AurumMotion.long1
    // (350ms) per aurum_transitions.dart. A short buffer (60ms) absorbs
    // minor scheduling jitter so this never restores the real blur a
    // frame or two before the transition has actually finished painting.
    Future.delayed(const Duration(milliseconds: 410), () {
      if (mounted && gen == _routeAnimGen) {
        setState(() => _routeAnimating = false);
      }
    });
  }

  // A route above MainShell was just popped (user backed out of
  // Settings/Full Player/etc.) — the reverse transition is about to
  // animate too.
  //
  // FIX ("mini player stuck as flat glass for a couple seconds after
  // swipe-down close"): this used to share the same fixed 410ms delay as
  // didPushNext(). That's correct for a normal push (a real 350ms
  // AurumMotion.long1 route transition is animating) but wrong here for
  // Full Player's swipe-to-dismiss specifically: _completeDismissDrag()
  // in full_player_screen.dart runs its own variable-length drag
  // animation (140-300ms, scaled to however far the finger already was)
  // and only calls Navigator.pop() AFTER that finishes — by which point
  // the screen is already fully off-screen. So didPopNext() fires with
  // nothing left animating, yet still held the cheap flat tint for
  // another fixed 410ms on top of that, for no visual reason — which is
  // exactly the multi-second "stuck glass" gap. A short fixed buffer
  // (80ms, just enough to absorb scheduling jitter for the rare
  // programmatic Navigator.pop() cases) replaces the long delay since
  // there's no ongoing transition left to protect here.
  // FIX ("full player swipe-down se close karte hi mini player 1-2 second
  // ke liye ekdam flat/glass dikhta hai, phir sahi ho jata hai"): this
  // still set _routeAnimating = true immediately (even though the fixed
  // delay was already shortened to 80ms above). Full Player's own
  // swipe-to-dismiss (_completeDismissDrag() in full_player_screen.dart)
  // only calls Navigator.pop() AFTER its own 140-300ms slide-off
  // animation has already finished — the screen is already fully
  // off-screen and invisible by the time didPopNext() fires here. So
  // flipping to the flat-tint fallback at all, even briefly, was pure
  // unnecessary flicker: real BackdropFilter blur was already safe to
  // keep showing the whole time, since nothing was left animating on top
  // of it. Removed entirely for the swipe-dismiss case — the flat
  // fallback is now reserved for didPushNext(), where a route really is
  // sliding on top and the cheap tint genuinely saves GPU work during
  // that transition.
  @override
  void didPopNext() {
    // Nothing to do: no fallback tint needed here anymore (see FIX above).
  }

  // FIX ("halka sa neeche swipe karte hi gaana pause/dismiss ho jata
  // hai"): 64px is roughly a single accidental thumb-drag on a real
  // phone — especially easy to trigger by mistake while trying to just
  // tap or reposition your finger near the mini player. Raised to 110px
  // (a clearly deliberate downward swipe) so casual touches no longer
  // pause+dismiss the song.
  static const double _dismissThreshold = 110.0;
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

  void _openFullPlayer() {
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

    // BUGFIX ("offline song → back leaves a dead white/grey screen until
    // app restart", also reported as songs randomly not playing after a
    // full-player round trip): this used to push its own inline
    // PageRouteBuilder with its own LOCAL `_opening` guard — a hand-copied
    // duplicate of home_screen.dart's pushFullPlayer(), search_screen.dart's
    // push, and the old library_screen.dart/song_tile.dart pushes (those
    // two were already migrated to the shared helper — see their FIX
    // comments). A local guard only protects THIS widget's own tap from
    // double-firing; it does nothing to stop mini_player.dart and (before
    // this fix) search_screen.dart each independently passing their own
    // guard and both pushing a route in the same frame — e.g. tapping the
    // mini player at the same instant a search result or song tile tap is
    // still resolving. With opaque:false, the loser of that race can end
    // up attached to the Navigator stack but never properly composited —
    // an invisible barrier that still hit-tests every tap and swallows
    // the back gesture, which is exactly the "screen goes dead, only a
    // restart fixes it" report, and far more likely for local/offline
    // songs since they resolve near-instantly with no network round-trip
    // to naturally space two taps apart. Routing through the single
    // shared pushFullPlayer() helper (same one every other entry point
    // now uses) removes this duplicate, unguarded route definition and
    // gets the real cross-widget guard for free.
    pushFullPlayer(context);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, player, _) {
        if (!player.miniPlayerVisible || player.currentSong == null) {
          return const SizedBox.shrink();
        }

        // Kick off (or reuse the cached) palette lookup for whatever song
        // is now playing. Deferred a frame — calling setState() directly
        // inside build() isn't safe, and the cache-hit path (the common
        // case) resolves so fast the one-frame delay is imperceptible.
        final currentSong = player.currentSong;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncTintForSong(currentSong);
        });

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
                // FIX ("mini player bahut upar/floaty lagta hai"): 8px
                // bottom gap plus the nav bar's own internal padding
                // stacked up to a visibly large empty gap between the
                // mini player and the nav bar in the screenshot. Tightened
                // to sit snug just above the nav bar, matching the tight
                // Spotify-style stacked look instead of floating.
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  // Spotify-style tinted background: smoothly cross-fades
                  // toward the current song's artwork color whenever it
                  // changes. TweenAnimationBuilder only runs its own short
                  // tween while _tintColor is actually changing — no
                  // AnimationController, no continuous ticking, fully idle
                  // between song changes.
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: _tintColor),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedTint, _) {
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      // FIX ("home pe wapas aate hi mini player ek pal ke
                      // liye poora white/blank dikhta hai"): the fallback
                      // used to be plain Colors.white in light mode. Any
                      // time this widget rebuilds before _syncTintForSong's
                      // post-frame callback has actually resolved a real
                      // artwork tint (e.g. right after navigating back to
                      // Home, before the cache peek() result lands), that
                      // pure-white fallback painted the ENTIRE 68px bar —
                      // reading as "the whole mini player goes white" for a
                      // frame or two. The app's own themed card color
                      // blends into the UI instead of flashing as a stark
                      // white/blank block while waiting for the real tint.
                      final fallback = AurumTheme.bgCardOf(context);
                      final baseTint = animatedTint ?? fallback;
                      return _routeAnimating
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
                            color: baseTint.withValues(
                              alpha: isDark ? 0.42 : 0.62,
                            ),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: (isDark ? Colors.white : Colors.black)
                                  .withValues(alpha: 0.08),
                              width: 1,
                            ),
                          ),
                          child: _miniPlayerContent(context, player,
                              onTint: baseTint.computeLuminance() > 0.5
                                  ? Colors.black
                                  : Colors.white),
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
                            final solidBg =
                                _tintColor ?? AurumTheme.bgCardOf(context);
                            final barBg = blurSigma <= 0
                                ? solidBg
                                : baseTint.withValues(
                                    alpha: isDark ? 0.42 : 0.62,
                                  );
                            final content = Container(
                              height: 68,
                              decoration: BoxDecoration(
                                color: barBg,
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: (isDark ? Colors.white : Colors.black)
                                      .withValues(alpha: 0.08),
                                  width: 1,
                                ),
                              ),
                              // FIX ("theme ke hisab se artwork awkward
                              // lagta hai"): title/artist text used to
                              // always use the app's fixed dark/light-mode
                              // text color, completely independent of the
                              // actual artwork-derived color this bar is
                              // painted with. A light/pastel album cover in
                              // dark mode produced a light tint background
                              // with white theme text on top — low/no
                              // contrast, unreadable. Deriving on/off text
                              // straight from the bar's own real background
                              // luminance (same pattern already used for
                              // the play button icon below) guarantees
                              // readable text against whatever color this
                              // specific song's artwork actually painted.
                              child: _miniPlayerContent(context, player,
                                  onTint: (blurSigma <= 0 ? solidBg : baseTint)
                                              .computeLuminance() >
                                          0.5
                                      ? Colors.black
                                      : Colors.white),
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
  ///
  /// [onTint] is the black/white color that's actually readable against
  /// THIS render's real background color (solid tint, blurred tint, or
  /// route-animating fallback tint — whichever one is currently painted).
  /// Title/artist text uses it directly instead of the app's fixed
  /// dark/light-mode text color, so a light album cover in dark mode (or
  /// vice versa) never produces low-contrast text on top of its own
  /// artwork-derived background.
  Widget _miniPlayerContent(BuildContext context, PlayerProvider player,
      {required Color onTint}) {
    final song = player.currentSong!;
    final secondaryOnTint = onTint.withValues(alpha: 0.72);
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
                          color: onTint,
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
                          color: secondaryOnTint,
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
                  color: secondaryOnTint,
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
                  color: secondaryOnTint,
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
  final Color? color;

  const _ControlBtn({
    required this.icon,
    required this.onTap,
    this.size = 24,
    this.color,
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
          // FIX: was always the app's fixed theme text-secondary color,
          // ignoring the mini player's own artwork-tinted background —
          // same contrast bug as the title/artist text above. Falls back
          // to the old theme color only when no tint is supplied (keeps
          // every other caller of _ControlBtn, if any, unaffected).
          color: color ?? AurumTheme.textSecondaryOf(context),
          size: size,
        ),
      ),
    );
  }
}
