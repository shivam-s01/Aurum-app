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
import '../utils/aurum_haptics.dart';
import '../services/audio_prefs.dart';

// ═══════════════════════════════════════════════════════════════════════
// NOTICE FOR ANY FUTURE EDITS TO THIS FILE (human or AI assistant):
//
// This file previously carried a `_kDebugMiniPlayerStuckDrag` flag and a
// `_flashDebugBanner()` on-screen banner helper, used while confirming a
// "mini player left visibly offset/faded after a cancelled/interrupted
// swipe-to-dismiss gesture" theory. That debug tooling has been removed —
// the REAL fix (`_onDragCancel()` resetting `_dragging`/`_dragY`, plus the
// `didChangeAppLifecycleState` reset for a drag interrupted by the app
// being backgrounded) is still fully in place below and untouched; only
// the diagnostic on/off flag and banner were dead weight.
//
// Separately, offline/local song artwork (file://, content:// URIs) no
// longer falls back to a flat gray tint — see the tint-resolution logic
// further down in this file. DO NOT reintroduce a debug flag/banner here.
// If a similar "mini player stuck visually offset" bug resurfaces, check
// `_onDragCancel()` and `didChangeAppLifecycleState()` first — they're the
// two places _dragging/_dragY get reset outside a normal completed drag.
// ═══════════════════════════════════════════════════════════════════════

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> with WidgetsBindingObserver {
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
    // BUGFIX ("gray/stuck layer specifically on downloaded/offline songs,
    // tap opens full player, swipe-up/down behaves like the mini player" —
    // this is the mini player itself, not a duplicate route): this used
    // to bail out to a null tint (flat AurumTheme.bgCardOf fallback —
    // Material 3's colorScheme.surface, a muted dark charcoal/gray) for
    // ANY url that didn't start with 'http'. A downloaded/local song's
    // artworkUrl is a file:// or content:// path or bare device path —
    // NEVER http — so every single offline song hit this branch and
    // permanently got the flat gray fallback with no real per-song tint,
    // while online (http) artwork correctly extracted its own color.
    // That's exactly why the "gray layer" was specific to offline
    // songs: it isn't corrupted state, it's the intended fallback color
    // for "no tint available" — just wrongly applied to every local song
    // (ArtworkPaletteCache.get()/_resolveArtworkProvider ALREADY know how
    // to decode file://content://local paths just fine — this early
    // return in the mini player never even asked). In solid mode
    // (Settings → Appearance → Mini Player Blur = 0) this fallback color
    // paints completely flat and opaque with nothing else to break it up,
    // reading as a stuck gray block; in blur mode the same flat color is
    // there too, just less obvious because it's blurring page content
    // underneath. Only genuinely missing/empty artwork should skip
    // straight to the null/gray fallback now — local file paths go
    // through the exact same cache lookup as http ones.
    if (url == null || url.isEmpty) {
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

  // REMOVED (per explicit request — this entire route-observer /
  // flat-tint-during-transition system was the root of the multi-day mini
  // player "gray/stuck" saga): MiniPlayer used to subscribe to
  // aurumRouteObserver purely to detect push/pop transitions above
  // MainShell and swap in a cheap flat-tint fallback during them, to save
  // GPU cost while BackdropFilter's blur would otherwise re-run every
  // frame of the transition. The bookkeeping around that (didPushNext /
  // didPopNext / a generation counter) was fragile enough that a State
  // recreation (e.g. on theme change) could leave the fallback stuck on
  // forever with nothing left to ever clear it. Removed entirely — the
  // real blurred mini player now always renders, unconditionally, so there
  // is no fallback state left to get stuck in. RouteAware subscription
  // removed since nothing in this widget needs it anymore.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // FIX ("offline song bajao, app background karo, wapas aao — mini
  // player/screen permanently dim ya offset lagta hai, swipe-up kabhi kaam
  // karta hai kabhi stuck ho jata hai"): the GestureDetector below only
  // wired onVerticalDragStart/Update/End — there was no
  // onVerticalDragCancel at all. If the gesture arena takes the pointer
  // away mid-drag (a competing scroll winning resolution) OR the app
  // itself gets backgrounded mid-drag (user's thumb still down on the mini
  // player exactly when they hit Recents/home — easy to do with a local
  // song, since there's no network round-trip keeping their attention on
  // the screen a moment longer first), neither onVerticalDragEnd nor any
  // cancel handler ever fires. _dragging stays stuck true and _dragY stays
  // frozen at whatever partial value the drag had reached — and both
  // directly drive this widget's opacity/translateY in build() below, so
  // the mini player (and by extension whatever's behind/around it) is left
  // visibly offset and faded until something unrelated happens to call
  // setState() again. This matches the local/offline-specific "white layer
  // / dim" report: same root shape as the already-fixed
  // "offline song → back leaves a dead white/grey screen" bug above (a
  // dropped gesture/frame leaving stale visual state), just via the
  // vertical drag-to-dismiss gesture instead of the full-player route
  // push. Fix: add the missing onVerticalDragCancel (resets exactly like a
  // non-dismissing drag-end would), and also observe app lifecycle so a
  // pause/inactive/detached transition mid-drag resets this state
  // immediately rather than waiting on a pointer event that may never
  // arrive.
  void _onDragCancel() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _dragY = 0;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) &&
        _dragging &&
        mounted) {
      setState(() {
        _dragging = false;
        _dragY = 0;
      });
    }
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
          onVerticalDragCancel: _onDragCancel,
          child: Transform.translate(
            offset: Offset(0, translateY),
            child: Opacity(
              opacity: opacity,
              child: ValueListenableBuilder<String>(
                valueListenable: AudioPrefs.navBarStyleNotifier,
                builder: (context, navStyle, _) {
                  final docked = navStyle == 'Docked';
                  return Padding(
                // FIX ("mini player bahut upar/floaty lagta hai"): 8px
                // bottom gap plus the nav bar's own internal padding
                // stacked up to a visibly large empty gap between the
                // mini player and the nav bar in the screenshot. Tightened
                // to sit snug just above the nav bar, matching the tight
                // Spotify-style stacked look instead of floating.
                //
                // Docked style (Settings → Appearance → "Nav Bar Style"):
                // a small consistent 6px side margin (not full edge-to-edge)
                // plus a small 3px bottom gap — matches the reference look
                // of a classic docked bar that still breathes slightly off
                // the screen edges instead of touching them directly.
                padding: docked
                    ? const EdgeInsets.fromLTRB(6, 0, 6, 3)
                    : const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: ClipRRect(
                  borderRadius:
                      docked ? BorderRadius.circular(10) : BorderRadius.circular(28),
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
                      // REMOVED (per explicit request — this whole
                      // "_routeAnimating" flat-tint fallback was the root of
                      // the multi-day "mini player gray/stuck" saga): this
                      // branch used to swap in a cheap flat-color Container
                      // for ~410ms every time a route pushed/popped on top
                      // of MainShell, to save GPU cost during the
                      // transition. The bookkeeping that drove it
                      // (didPushNext/didPopNext/_routeAnimGen) was fragile —
                      // a State recreation (e.g. on theme change) could
                      // leave it permanently stuck true with nothing left to
                      // ever clear it, which read as "mini player
                      // permanently gray until app restart." Rather than
                      // patch the bookkeeping further, the flat-tint path is
                      // gone entirely: the real blurred mini player now
                      // renders unconditionally, always. The only cost is
                      // the BackdropFilter blur also running during route
                      // transitions instead of being swapped out — a minor,
                      // bounded perf tradeoff, not a correctness bug that
                      // can get permanently stuck.
                      return ValueListenableBuilder<double>(
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
                            final barBg = (docked || blurSigma <= 0)
                                ? solidBg
                                : baseTint.withValues(
                                    alpha: isDark ? 0.42 : 0.62,
                                  );
                            final content = Container(
                              height: docked ? 60 : 68,
                              decoration: BoxDecoration(
                                color: barBg,
                                borderRadius: docked
                                    ? BorderRadius.circular(10)
                                    : BorderRadius.circular(28),
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
                                  onTint: ((docked || blurSigma <= 0)
                                              ? solidBg
                                              : baseTint)
                                          .computeLuminance() >
                                          0.5
                                      ? Colors.black
                                      : Colors.white,
                                  compact: docked),
                            );
                            // PERF/HEAT SETTING: mini player is a persistent
                            // overlay on every screen, so its BackdropFilter
                            // blur runs on every frame it's visible — real,
                            // continuous GPU cost. sigma == 0 (user set via
                            // Settings → Appearance → "Mini Player Blur")
                            // skips BackdropFilter entirely for the cheapest
                            // possible steady-state render. Docked mode
                            // ALWAYS skips it too, regardless of the blur
                            // slider — Docked is meant to be the flat,
                            // lightweight classic look, and the whole point
                            // (both visually and for perf) is that it never
                            // pays for glass/blur at all.
                            if (docked || blurSigma <= 0) return content;
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
              );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// The mini player's actual row content (progress bar, artwork, title/
  /// artist, transport controls).
  ///
  /// [onTint] is the black/white color that's actually readable against
  /// THIS render's real background color (solid tint or blurred tint,
  /// whichever one is currently painted).
  /// Title/artist text uses it directly instead of the app's fixed
  /// dark/light-mode text color, so a light album cover in dark mode (or
  /// vice versa) never produces low-contrast text on top of its own
  /// artwork-derived background.
  ///
  /// [compact] (Docked nav bar style only — see AudioPrefs.navBarStyleNotifier)
  /// renders the same content at JioSaavn-style thin-strip proportions:
  /// smaller artwork, tighter type, and smaller control icons, matching the
  /// shorter 52px container height used for Docked mode. It also swaps the
  /// full prev/play/next transport row for just Play/Pause + a Close (✕)
  /// button — the compact-strip control set most streaming apps' docked
  /// mini players use, and simpler to render reliably at 52px than three
  /// tap targets. Floating mode's prev/play/next row is completely
  /// unaffected — this only ever runs when compact is true.
  Widget _miniPlayerContent(BuildContext context, PlayerProvider player,
      {required Color onTint, bool compact = false}) {
    final song = player.currentSong!;
    final secondaryOnTint = onTint.withValues(alpha: 0.72);
    final artSize = compact ? 38.0 : 44.0;
    final artRadius = compact ? 8.0 : 10.0;
    final titleSize = compact ? 13.0 : 13.0;
    final artistSize = compact ? 11.0 : 11.0;
    final gapAfterArt = compact ? 10.0 : 12.0;
    final gapBeforeControls = compact ? 8.0 : 8.0;
    final controlSize = compact ? 22.0 : 22.0;
    // Docked's Play/Pause + Close pair needs real breathing room between
    // them (matches the reference layout) — 2px read as the two icons
    // being glued together. Floating's tighter 3-icon row (prev/play/next)
    // keeps its own smaller gap since it has three targets to fit.
    final controlGap = compact ? 14.0 : 4.0;
    return Column(
      children: [
        _MiniProgressBar(player: player, squareTop: compact),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
            child: Row(
              children: [
                AurumArtwork(
                  url: song.artworkUrl,
                  size: artSize,
                  borderRadius: artRadius,
                ),
                SizedBox(width: gapAfterArt),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        song.title,
                        style: TextStyle(
                          color: onTint,
                          fontSize: titleSize,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: compact ? 1 : 2),
                      Text(
                        song.artist,
                        style: TextStyle(
                          color: secondaryOnTint,
                          fontSize: artistSize,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: gapBeforeControls),
                if (compact) ...[
                  _PlayBtn(player: player, compact: true),
                  SizedBox(width: controlGap),
                  _ControlBtn(
                    icon: Icons.close_rounded,
                    onTap: () {
                      AurumHaptics.selection();
                      player.stopAndClear();
                    },
                    size: controlSize,
                    color: secondaryOnTint,
                  ),
                ] else ...[
                  _ControlBtn(
                    icon: Icons.skip_previous_rounded,
                    onTap: () {
                      AurumHaptics.selection();
                      player.skipPrev();
                    },
                    size: controlSize,
                    color: secondaryOnTint,
                  ),
                  SizedBox(width: controlGap),
                  _PlayBtn(player: player, compact: false),
                  SizedBox(width: controlGap),
                  _ControlBtn(
                    icon: Icons.skip_next_rounded,
                    onTap: () {
                      AurumHaptics.selection();
                      player.skipNext();
                    },
                    size: controlSize,
                    color: secondaryOnTint,
                  ),
                ],
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
  // Docked mode has square corners on the container itself, so the
  // progress bar's own top-rounding (which floating mode needs to match
  // the pill's 28px radius) would just clip a rounded strip onto a square
  // bar — mismatched and visually wrong. squareTop drops the rounding
  // entirely for Docked, matching its flat/square container.
  final bool squareTop;
  const _MiniProgressBar({required this.player, this.squareTop = false});

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, double>(
      selector: (_, p) => p.progress,
      builder: (context, progress, _) => ClipRRect(
        borderRadius: BorderRadius.vertical(
            top: Radius.circular(squareTop ? 10 : 28)),
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
  final bool compact;
  const _PlayBtn({required this.player, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<ThemeProvider>().accentColor;
    final btnSize = compact ? 34.0 : 36.0;
    final iconSize = compact ? 18.0 : 20.0;
    if (player.isLoading) {
      return Opacity(
        opacity: 0.35,
        child: SizedBox(
          width: btnSize,
          height: btnSize,
          child: Icon(Icons.play_arrow_rounded, color: accent, size: iconSize + 6),
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
        width: btnSize,
        height: btnSize,
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
          size: iconSize,
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
