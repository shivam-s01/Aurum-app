import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/source_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
import '../services/api_service.dart';
import '../services/audio_prefs.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_loader.dart';
import '../widgets/aurum_morph_loader.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/mini_player.dart';
import '../utils/aurum_transitions.dart';
import 'package:shimmer/shimmer.dart';
import 'settings_screen.dart';
import 'artist_screen.dart';
import 'profile_screen.dart';
import 'login_screen.dart';
import 'full_player_screen.dart';
import 'premium_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/premium_provider.dart';
import '../services/sync_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Public so MainShell can type a GlobalKey against this and call
/// resyncHeroVisibility() without needing access to the private
/// _HomeScreenState class itself.
abstract class HomeScreenState extends State<HomeScreen> {
  void resyncHeroVisibility();
}

// ── Curated playlists shown as Spotify/JioSaavn-style cards ──
// Focused on current-era (2025/2026) Bollywood trending music instead of
// generic mood buckets — these queries are written to surface recent
// releases first on Saavn's search ranking (which favors recency +
// popularity for these kinds of phrasing).
const List<_PlaylistMeta> _kCuratedPlaylists = [
  _PlaylistMeta('Trending Now',        'bollywood songs 2026',            '🔥', Color(0xFF8B1A1A)),
  _PlaylistMeta('New Releases',        'new bollywood songs 2026',        '🆕', Color(0xFF1A3A8B)),
  _PlaylistMeta('2025 Chartbusters',   'top bollywood songs 2025',        '⭐', Color(0xFF7B3F00)),
  _PlaylistMeta('Arijit Singh Hits',   'arijit singh new songs 2025',     '🎤', Color(0xFF3A2A00)),
  _PlaylistMeta('Romantic This Week',  'bollywood romantic songs 2025',   '❤️', Color(0xFF8B1A1A)),
  _PlaylistMeta('Party Anthems',       'bollywood party songs 2025',      '🎉', Color(0xFF1A3A8B)),
  _PlaylistMeta('Fresh Bollywood',     'latest bollywood songs',          '✨', Color(0xFF2A1A00)),
  _PlaylistMeta('Movie Blockbusters',  'bollywood movie songs 2025 2026', '🎬', Color(0xFF1A3A3A)),
];

class _PlaylistMeta {
  final String name;
  final String query;
  final String emoji;
  final Color color;
  const _PlaylistMeta(this.name, this.query, this.emoji, this.color);
}

// Note: previously cached query→artwork permanently across the whole app
// session (_kPlaylistArtCache). Removed so art genuinely refreshes each
// pull-to-refresh along with the songs — a stale thumbnail next to a fresh
// random tracklist looked broken/cheap, not premium.

// ══════════════════════════════════════════════════════════════════
// NOTE: the previous hand-rolled `_HeroPullToRefresh` + `_RingPainter`
// (custom NotificationListener-based pull gesture) has been removed.
// ROOT CAUSE of "refresh hota hi nahi": that custom gesture detector sat
// directly above `_HeroNowPlaying`, which has its own horizontal-drag
// GestureDetector for song swipe. Flutter's gesture arbitration between
// the two competed for the same touch sequence, and a plain vertical
// pull starting at the very top of the list (pixels == 0, right where
// SliverAppBar's floating/snap behavior also has its own claim on the
// first bit of scroll delta) frequently lost that arbitration silently
// — no ring, no refresh, no error.
//
// Fixed by switching to Flutter's own `RefreshIndicator` (wired directly
// in HomeScreen.build() below), which owns gesture arbitration correctly
// against sibling GestureDetectors out of the box. Styled with the app's
// gold accent so it still matches the rest of Aurum instead of looking
// like a stock Material widget.

class _HomeScreenState extends HomeScreenState {
  List<SongSection> _onlineSections = [];
  bool _onlineLoading = true;
  String? _onlineError;
  // Bumped on every pull-to-refresh so the "Playlists for You" cards (which
  // cache their own art/songs in initState) get fresh widget identities and
  // refetch a brand-new random Saavn-first set instead of showing stale data.
  int _playlistRefreshKey = 0;

  List<ArtistSimple> _homeArtists = [];
  bool _artistsLoading = true;

  final ScrollController _scrollCtrl = ScrollController();
  // Hero card is ~190px tall (168 height + 22 vertical padding).
  // Once user scrolls past this, mini player should appear.
  static const double _heroHeight = 190.0;

  void _onScroll() {
    final heroGone = _scrollCtrl.offset >= _heroHeight;
    MiniPlayer.heroVisibleNotifier.value = !heroGone;
  }

  /// Re-derives heroVisibleNotifier from the CURRENT scroll offset.
  ///
  /// _onScroll only fires on an actual scroll event. HomeScreen is kept
  /// alive in MainShell's IndexedStack (never disposed on tab switch),
  /// so if the user switches away to Search/Library and back to Home
  /// WITHOUT scrolling in between, nothing re-runs _onScroll — the
  /// notifier is left holding whatever value the *previous* tab switch
  /// forced it to (always false, per MainShell's onTap handler), even
  /// if Home's scroll position says the hero card is still on-screen.
  /// That mismatch is what caused the mini player to occasionally stay
  /// hidden (or, on fast repeated switching, land in the wrong
  /// show/hide state) after returning to Home. MainShell calls this
  /// via a GlobalKey the moment tab 0 becomes active again, so the
  /// flag always matches reality instead of a stale write from the
  /// tab-switch that happened to run last.
  @override
  void resyncHeroVisibility() {
    if (!mounted) return;
    final heroGone = _scrollCtrl.offset >= _heroHeight;
    MiniPlayer.heroVisibleNotifier.value = !heroGone;
  }

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadOnline();
    _loadArtists();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lib = context.read<LibraryProvider>();
      if (!lib.hasLoaded) lib.load();

      // Surface real playback failures immediately via SnackBar — no
      // logcat/adb needed to see exactly why a tap didn't start sound.
      // See player_provider.dart's onPlaybackError (wired from
      // NativeAudioEngine.errorStream) for where these messages come from.
      final player = context.read<PlayerProvider>();
      player.onPlaybackError = (error, {silent = false}) {
        debugPrint('[Aurum] Playback error${silent ? " (silent, auto-recovered)" : ""}: $error');
        if (!mounted || silent) return;
        // Only reaches here when every automatic retry/skip attempt has
        // been exhausted — a single flaky song no longer triggers this.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.red.shade900,
            duration: const Duration(seconds: 4),
            content: Text(
              error,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        );
      };
    });
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    MiniPlayer.heroVisibleNotifier.value = true; // reset when leaving home
    super.dispose();
  }

  Future<void> _loadArtists() async {
    try {
      final artists = await ApiService.fetchHomeArtists();
      if (mounted) setState(() { _homeArtists = artists; _artistsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _artistsLoading = false);
    }
  }

  Future<void> _loadOnline() async {
    setState(() {
      _onlineLoading = true;
      _onlineError = null;
      _playlistRefreshKey++;
      _onlineSections = []; // cleared until the full batch is ready
    });
    try {
      final recentlyPlayedProvider = context.read<RecentlyPlayedProvider>();
      final topArtists  = recentlyPlayedProvider.topArtists(count: 3);
      // Fresh random seed every pull so, when learned affinity data is too
      // sparse for RecommendationEngine's own rotation, this fallback list
      // of "Made for You" artists still changes from refresh to refresh
      // instead of always featuring the exact same top-3-by-play-count.
      final topArtistsRotating = recentlyPlayedProvider.rotatingTopArtists(
        count: 3,
        seed: math.Random().nextInt(1000000),
      );
      final recentSongs = recentlyPlayedProvider.history.take(10).toList();
      // Collect every section locally as it streams in from the API, but
      // don't touch UI state per-section anymore — the user wants the
      // whole home page to appear at once instead of sections trickling
      // in one by one. setState only fires once, after everything is in.
      final collected = <SongSection>[];
      await ApiService.fetchHomeStreaming(
        topArtists: topArtists,
        topArtistsRotating: topArtistsRotating,
        recentlyPlayed: recentSongs,
        onSection: (section) {
          collected.add(section);
        },
      ).timeout(const Duration(seconds: 25));
      if (mounted) {
        setState(() {
          _onlineSections = collected;
          _onlineLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _onlineLoading = false;
          if (_onlineSections.isEmpty) _onlineError = 'Failed to load. Check connection.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final src = context.watch<SourceProvider>();
    final isOnline = src.isOnline;

    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: Stack(
        children: [
          // ── Top ambient glow layer (behind everything) ──
          const _TopAmbientGlow(),

          // ── Main scroll content ──
          // Native RefreshIndicator — see the note above _TopAmbientGlow's
          // old _HeroPullToRefresh definition for why the custom gesture
          // detector was replaced. This owns gesture arbitration against
          // the hero's horizontal swipe detector correctly out of the box,
          // so a plain downward pull at the top of the list reliably
          // triggers a refresh every time. Styled gold/dark to match the
          // rest of Aurum rather than looking like a stock widget.
          RefreshIndicator(
            color: AurumTheme.gold,
            backgroundColor: AurumTheme.bgCardOf(context),
            strokeWidth: 2.6,
            displacement: 48,
            onRefresh: () => isOnline
                ? Future.wait([_loadOnline(), _loadArtists()])
                : context.read<LibraryProvider>().refresh(),
            child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                _buildAppBar(context, src),
                const SliverToBoxAdapter(child: _HeroNowPlaying()),
                SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: isOnline
                              ? const Offset(-0.06, 0)
                              : const Offset(0.06, 0),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: isOnline
                        ? Column(
                            key: const ValueKey('online'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // ── Curated Playlists ──
                              _CuratedPlaylistsSection(refreshKey: _playlistRefreshKey),
                              // ── Premium upsell banner (free users only) ──
                              const _HomePremiumBanner(),
                              // ── Song sections ──
                              _OnlineContent(
                                sections: _onlineSections,
                                loading: _onlineLoading,
                                error: _onlineError,
                                onRetry: _loadOnline,
                              ),
                              // ── Artist Strip (after recommendations) ──
                              _ArtistStrip(
                                artists: _homeArtists,
                                loading: _artistsLoading,
                              ),
                            ],
                          )
                        : const _OfflineContent(key: ValueKey('offline')),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, SourceProvider src) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverAppBar(
      backgroundColor: Colors.transparent,
      floating: true,
      snap: true,
      elevation: 0,
      titleSpacing: 20,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      title: AurumPressable(
        scaleAmount: 0.95,
        onTap: () => Navigator.of(context).push(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 380),
            pageBuilder: (_, __, ___) => const PremiumScreen(),
            transitionsBuilder: (_, animation, __, child) {
              final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
              final slide = Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
              return FadeTransition(
                opacity: fade,
                child: SlideTransition(position: slide, child: child),
              );
            },
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Aurum',
              style: TextStyle(
                color: AurumTheme.gold,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [AurumTheme.goldDark, AurumTheme.gold, AurumTheme.goldLight],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.45),
                    blurRadius: 10,
                    spreadRadius: 0.5,
                  ),
                ],
              ),
              child: const Text(
                '✦ Plus',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        _StatusPill(onTap: () => _showSourceSheet(context, src)),
        if (kDebugMode)
          IconButton(
            icon: Icon(Icons.bug_report_outlined,
                color: AurumTheme.textSecondaryOf(context)),
            onPressed: () async {
              // Wire the REAL engine in, so the "REAL PLAYBACK TEST" step
              // tests actual in-app playback instead of a throwaway player.
              // See api_service.dart / player_provider.dart for why this
              // distinction matters — it's what made this bug ambiguous.
              final playerProvider = context.read<PlayerProvider>();
              final result = await ApiService.debugPlaybackPath(
                realPlaybackTest: playerProvider.runRealPlaybackTest,
              );
              if (!context.mounted) return;
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Playback Diagnostics'),
                  content: SingleChildScrollView(
                    child: SelectableText(result),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => AurumPageRoute.to(context, const SettingsScreen()),
        ),
        const _ProfileAvatarButton(),
      ],
    );
  }

  void _showSourceSheet(BuildContext context, SourceProvider src) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (_) => _SourceSheet(src: src),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero Now Playing — premium immersive section + floating glass card.
// Lives inside HomeScreen's IndexedStack tab, so Flutter's TickerMode
// automatically pauses the AnimationController when this tab is offstage —
// no manual lifecycle wiring needed for the breathing animation.
// ─────────────────────────────────────────────────────────────────────────────

class _HeroNowPlaying extends StatefulWidget {
  const _HeroNowPlaying();

  @override
  State<_HeroNowPlaying> createState() => _HeroNowPlayingState();
}

class _HeroNowPlayingState extends State<_HeroNowPlaying>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _breatheCtrl;
  String? _lastUrl;
  bool _appInForeground = true;

  // ── Left/right swipe → prev/next song ──
  double _dragX = 0;
  bool _isDraggingX = false;
  int _swipeDir = 0;
  String? _lastSongId;
  static const double _swipeThreshold = 70.0;
  static const double _swipeVelocityThreshold = 500.0;

  late final AnimationController _swipeCtrl;
  Animation<double> _swipeAnim = const AlwaysStoppedAnimation(0.0);
  late final AnimationController _slideInCtrl;
  late Animation<double> _slideInAnim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 13s full cycle — within spec's 12-15s range
    _breatheCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 20000),
    ); // started/stopped from build() based on isPlaying — see build()

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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Force-stop the breathe glow the instant the app leaves the
    // foreground (minimized, screen locked, app-switcher) regardless of
    // isPlaying — audio keeps playing via the foreground service, but
    // there's zero reason to keep repainting this widget when nobody can
    // see it. This is on top of the isPlaying gate in build().
    _appInForeground = state == AppLifecycleState.resumed;
    if (!_appInForeground) {
      if (_breatheCtrl.isAnimating) _breatheCtrl.stop();
    } else if (mounted) {
      setState(() {}); // let build() re-evaluate and resume if isPlaying
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _breatheCtrl.dispose();
    _swipeCtrl.dispose();
    _slideInCtrl.dispose();
    super.dispose();
  }

  // Generation token — same pattern as mini player's _swipeGen. Prevents
  // stale .whenComplete() callbacks from firing extra/wrong skipNext/
  // skipPrev calls when swipes are spammed rapidly back-to-back.
  int _swipeGen = 0;

  void _onDragStartX(DragStartDetails _) {
    _swipeGen++;
    _swipeCtrl.stop();
    setState(() => _isDraggingX = true);
  }

  void _onDragUpdateX(DragUpdateDetails details) {
    setState(() {
      _dragX = (_dragX + details.delta.dx).clamp(-160.0, 160.0);
    });
  }

  void _onDragEndX(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    setState(() => _isDraggingX = false);

    final commitNext =
        _dragX < -_swipeThreshold || velocity < -_swipeVelocityThreshold;
    final commitPrev =
        _dragX > _swipeThreshold || velocity > _swipeVelocityThreshold;

    if (commitNext) {
      HapticFeedback.mediumImpact();
      _commitSwipe(next: true);
    } else if (commitPrev) {
      HapticFeedback.mediumImpact();
      _commitSwipe(next: false);
    } else {
      _springBackX();
    }
  }

  void _springBackX() {
    _swipeCtrl.stop();
    final gen = ++_swipeGen;
    _swipeAnim = Tween<double>(begin: _dragX, end: 0.0).animate(
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
    _swipeAnim =
        Tween<double>(begin: _dragX, end: next ? -220.0 : 220.0).animate(
      CurvedAnimation(parent: _swipeCtrl, curve: Curves.easeInCubic),
    );
    _swipeDir = next ? -1 : 1;
    _swipeCtrl.forward(from: 0.0).whenComplete(() {
      if (!mounted || gen != _swipeGen) return;
      final player = context.read<PlayerProvider>();
      next ? player.skipNext() : player.skipPrev();
      _swipeCtrl.reset();
      setState(() => _dragX = 0);
    });
  }


  void _openFullPlayer() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => const FullPlayerScreen(),
        transitionsBuilder: (_, anim, __, child) => SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 380),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);
    final isLight = Theme.of(context).brightness == Brightness.light;

    // Battery: the breathe glow only needs to animate while a song is
    // actually playing. Previously it ran on an infinite ..repeat(reverse:
    // true) from initState with no gating, so it kept ticking (and
    // repainting this part of the hero) even when paused or when nothing
    // was loaded — pure wasted GPU/CPU work sitting on the home screen.
    final isPlayingNow =
        context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final shouldBreathe = isPlayingNow && _appInForeground;
    if (shouldBreathe && !_breatheCtrl.isAnimating) {
      _breatheCtrl.repeat(reverse: true);
    } else if (!shouldBreathe && _breatheCtrl.isAnimating) {
      _breatheCtrl.stop();
    }

    // FIX: a persistent hairline seam (page's cream/`bgOf` background
    // peeking through) was showing along the hero's bottom edge in every
    // state, not just mid-transition. Root cause: AnimatedSize recomputes
    // its layout size from its child's intrinsic size every frame, and
    // that computed size can be a sub-pixel off from the child's actual
    // painted bounds due to rounding — normally invisible, but here the
    // full-bleed hero (no margin/card color of its own to plug the gap,
    // unlike the old padded/boxed design) sits directly on the page
    // background, so that fractional gap exposed it as a visible seam.
    //
    // Fix: `clipBehavior: Clip.hardEdge` on AnimatedSize clips content to
    // its own computed bounds rather than letting a rounding mismatch
    // show whatever's behind it. This addresses the actual rendering
    // artifact directly, rather than trying to paint over a gap that
    // shouldn't be visible in the first place.
    return AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: song == null
            ? _buildEmptyPrompt(context)
            : _buildPlayingCard(context, song, isLight),
      ),
    );
  }

  Widget _buildEmptyPrompt(BuildContext context) {
    // Lightweight static prompt — no blur, no animation, theme-safe.
    // Kept a small side margin here (unlike the playing card below) since
    // there's no artwork to bleed edge-to-edge — a floating pill reads
    // better than a full-width empty bar.
    return Padding(
      key: const ValueKey('hero_empty'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 22),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AurumTheme.bgCardOf(context),
        ),
        child: Row(
          children: [
            Icon(Icons.graphic_eq_rounded,
                color: AurumTheme.gold.withOpacity(0.85), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Pick something to play',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Playing card — "now playing stage" ──────────────────────────────────
  // Redesigned as a full-bleed panel (no side margins, no rounded card
  // floating on the page background, no outer border) so it reads as the
  // top of a continuous surface that the rest of the page descends from,
  // rather than a separate boxed widget sitting on top of the scaffold.
  // All gesture/animation logic below (swipe-to-skip, breathing scale,
  // slide-in on song change) is unchanged from before — only the outer
  // shape/spacing changed.
  Widget _buildPlayingCard(BuildContext context, Song song, bool isLight) {
    return Padding(
      key: const ValueKey('hero_playing'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 22),
      child: AurumPressable(
        scaleAmount: 0.99,
        onTap: _openFullPlayer,
        child: Container(
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isLight ? 0.14 : 0.32),
                blurRadius: 22,
                offset: const Offset(0, 10),
                spreadRadius: -4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: ValueListenableBuilder<bool>(
            valueListenable: AudioPrefs.swipeToChangeNotifier,
            builder: (context, swipeEnabled, _) {
              return GestureDetector(
            onHorizontalDragStart: swipeEnabled ? _onDragStartX : null,
            onHorizontalDragUpdate: swipeEnabled ? _onDragUpdateX : null,
            onHorizontalDragEnd: swipeEnabled ? _onDragEndX : null,
            child: AnimatedBuilder(
              animation: Listenable.merge([_swipeCtrl, _slideInCtrl]),
              builder: (_, child) {
                if (song.id != _lastSongId) {
                  final isFirst = _lastSongId == null;
                  _lastSongId = song.id;
                  if (!isFirst) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _slideInCtrl.forward(from: 0.0);
                    });
                  }
                }
                final swipeX =
                    _swipeCtrl.isAnimating ? _swipeAnim.value : _dragX;
                final frac = (swipeX.abs() / 160.0).clamp(0.0, 1.0);
                final swipeOpacity = (1.0 - frac * 0.7).clamp(0.0, 1.0);
                final swipeScale = (1.0 - frac * 0.05).clamp(0.92, 1.0);

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
                    child: Opacity(opacity: totalOpacity, child: child),
                  ),
                );
              },
              child: Stack(fit: StackFit.expand, children: [
            // ── Stage background: blurred artwork, breathing scale ──
            // Perf: the blur (ImageFiltered) is now built ONCE, outside the
            // AnimatedBuilder — only the cheap Transform.scale wrapper
            // rebuilds every animation tick. Before, the blur filter itself
            // sat inside the builder callback, so Skia was re-running the
            // (expensive, full-stage-sized) Gaussian blur on every single
            // frame of the breathe loop for a scale change of at most
            // 1.5% — pure wasted GPU work for an effect nobody can even
            // perceive.
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _breatheCtrl,
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(
                    sigmaX: isLight ? 6 : 5,
                    sigmaY: isLight ? 6 : 5,
                    tileMode: TileMode.clamp,
                  ),
                  child: AurumArtwork(
                    url: song.artworkUrl,
                    size: double.infinity,
                    borderRadius: 0,
                  ),
                ),
                builder: (_, child) {
                  final b = Curves.easeInOut.transform(_breatheCtrl.value);
                  return Transform.scale(
                    scale: 1.0 + (b * 0.015), // 1.00 -> 1.015: alive, not animated
                    child: child,
                  );
                },
              ),
            ),
            // ── Scrim: now fades from fully transparent at the very top
            // (so it visually joins the appbar behind it, reinforcing the
            // "one continuous stage" read) down to a strong dark base
            // where the track info sits, for legibility.
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isLight
                      ? [
                          Colors.white.withOpacity(0.0),
                          Colors.white.withOpacity(0.06),
                          Colors.black.withOpacity(0.46),
                        ]
                      : [
                          Colors.black.withOpacity(0.05),
                          Colors.black.withOpacity(0.35),
                          Colors.black.withOpacity(0.86),
                        ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
            // ── Track info + resume — sits directly on the stage now,
            // no floating glass card/border. Full-width, edge-aligned
            // with the rest of the page's 20px gutter.
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AurumArtwork(
                        url: song.artworkUrl, size: 44, borderRadius: 11),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          song.artist,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.68),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ResumeButton(onTap: _openFullPlayer),
                ]),
              ),
            ),
          ]),
            ),
          );
            },
          ),
          ),
        ),
      ),
    );
  }
}

class _ResumeButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ResumeButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);

    return AurumPressable(
      scaleAmount: 0.92,
      onTap: () => context.read<PlayerProvider>().togglePlay(),
      child: Container(
        width: 40, height: 40,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AurumTheme.gold,
        ),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.black,
          size: 22,
        ),
      ),
    );
  }
}


class _TopAmbientGlow extends StatefulWidget {
  const _TopAmbientGlow();

  @override
  State<_TopAmbientGlow> createState() => _TopAmbientGlowState();
}

class _TopAmbientGlowState extends State<_TopAmbientGlow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  Color _currentColor = Colors.transparent;
  Color _targetColor  = Colors.transparent;
  String _lastUrl     = '';

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastUrl) return;
    _lastUrl = url;

    try {
      final ImageProvider provider = url.startsWith('http')
          ? CachedNetworkImageProvider(url)
          : FileImage(File(url)) as ImageProvider;

      // 80x80 is enough for palette — minimal cost
      final pg = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(48, 48),
      );

      final raw = pg.vibrantColor?.color ??
          pg.dominantColor?.color ??
          pg.lightVibrantColor?.color;

      if (raw == null || !mounted) return;

      // Snapshot current lerped value before transition
      final t = _ctrl.value;
      _currentColor = Color.lerp(_currentColor, _targetColor, t) ?? _currentColor;

      final isDark = mounted && Theme.of(context).brightness == Brightness.dark;
      _targetColor = isDark
          // Dark mode: subtle, low-lightness — artwork stays the focus.
          ? HSLColor.fromColor(raw).withSaturation(0.45).withLightness(0.14).toColor()
          // Light mode: airy, higher lightness so it reads as soft
          // colored light rather than a dark smear behind bright text.
          : HSLColor.fromColor(raw).withSaturation(0.55).withLightness(0.72).toColor();

      // Fade out → update → fade in (crossfade feel)
      await _ctrl.reverse();
      if (!mounted) return;
      setState(() => _currentColor = _targetColor);
      _ctrl.forward();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);

    if (song != null) {
      // Fire async, no setState in build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _extractColor(song.artworkUrl);
      });
    }

    if (song == null) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _opacity,
        builder: (_, __) {
          return Opacity(
            opacity: _opacity.value,
            child: SizedBox(
              height: isDark ? 220 : 300,
              width: double.infinity,
              child: _GlowPainter(color: _currentColor, isDark: isDark),
            ),
          );
        },
      ),
    );
  }
}

// CustomPainter — single radial gradient blob at the top center.
// Cheaper than a Container with BoxDecoration because it skips the
// layout pass entirely.
class _GlowPainter extends StatelessWidget {
  final Color color;
  final bool isDark;
  const _GlowPainter({required this.color, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GlowBlobPainter(color, isDark));
  }
}

class _GlowBlobPainter extends CustomPainter {
  final Color color;
  final bool isDark;
  _GlowBlobPainter(this.color, this.isDark);

  @override
  void paint(Canvas canvas, Size size) {
    if (color == Colors.transparent) return;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topCenter,
        radius: 1.1,
        colors: isDark
            ? [color.withOpacity(0.30), color.withOpacity(0.10), Colors.transparent]
            : [color.withOpacity(0.55), color.withOpacity(0.22), Colors.transparent],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromLTWH(0, -size.height * 0.3, size.width, size.height * 1.3));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_GlowBlobPainter old) => old.color != color || old.isDark != isDark;
}

// ─────────────────────────────────────────────────────────────────────────────
// Online Content
// ─────────────────────────────────────────────────────────────────────────────

class _OnlineContent extends StatelessWidget {
  final List<SongSection> sections;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  const _OnlineContent({
    required this.sections,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _buildShimmer(context);
    if (sections.isEmpty) {
      return _buildError(
        context,
        message: error ?? "Couldn't load songs right now.\nPull down or tap retry.",
      );
    }
    return Column(
      children: [
        for (int i = 0; i < sections.length; i++)
          _StaggeredSection(
            index: i,
            child: _buildSection(context, sections[i]),
          ),
      ],
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (_) => Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title placeholder
                Container(
                  width: 130,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 14),
                // Cards row placeholder
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 4,
                    itemBuilder: (_, __) => Container(
                      width: 140,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context, {String? message}) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_off_rounded, size: 48,
              color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(
            message ?? error ?? 'Failed to load.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AurumTheme.textMutedOf(context)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            child: Text('Retry', style: TextStyle(color: AurumTheme.gold)),
          ),
        ]),
      ),
    );
  }

  Widget _buildSection(BuildContext context, SongSection section) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  section.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              AurumPressable(
                scaleAmount: 0.92,
                onTap: () => _showAllSongs(context, section),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    'See all',
                    style: TextStyle(
                      color: AurumTheme.gold.withOpacity(0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Plain horizontal scroll — no edge fade overlays
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: section.songs.length,
              itemBuilder: (_, i) => _SongCard(
                song: section.songs[i],
                queue: section.songs,
                index: i,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAllSongs(BuildContext context, SongSection section) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.93,
        minChildSize: 0.4,
        expand: false,
        builder: (_, ctrl) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(children: [
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: AurumTheme.dividerOf(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  section.title,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ]),
          ),
          Divider(height: 1, color: AurumTheme.dividerOf(context)),
          Expanded(
            child: ListView.builder(
              controller: ctrl,
              physics: const BouncingScrollPhysics(),
              itemCount: section.songs.length,
              itemBuilder: (ctx, i) => SongTile(
                song: section.songs[i],
                queue: section.songs,
                index: i,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Staggered section — fade + slide up, one by one
// ─────────────────────────────────────────────────────────────────────────────

class _StaggeredSection extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredSection({required this.index, required this.child});

  @override
  State<_StaggeredSection> createState() => _StaggeredSectionState();
}

// Tracks which section indices have already animated — survives rebuilds/back-nav
final _seenSections = <int>{};

class _StaggeredSectionState extends State<_StaggeredSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _fade;
  late Animation<Offset>   _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.10),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );

    // If this section has been seen before (e.g. returning from FullPlayerScreen),
    // skip the animation entirely — jump to end state immediately.
    if (_seenSections.contains(widget.index)) {
      _ctrl.value = 1.0;
    } else {
      _seenSections.add(widget.index);
      Future.delayed(Duration(milliseconds: 50 + widget.index * 70), () {
        if (mounted) _ctrl.forward();
      });
    }
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _slide, child: child),
      ),
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline Content
// ─────────────────────────────────────────────────────────────────────────────

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();

    if (lib.status == LibraryStatus.idle || lib.status == LibraryStatus.loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: const Center(child: AurumMorphLoader()),
      );
    }
    if (lib.status == LibraryStatus.noPermission) {
      return _msg(context, Icons.folder_off_rounded,
          'Storage permission needed', 'Grant Permission', () => lib.load());
    }
    if (lib.allSongs.isEmpty) {
      return _msg(context, Icons.music_off_rounded,
          'No local songs found', 'Scan Again', () => lib.refresh());
    }

    final sections = lib.sections.isNotEmpty
        ? lib.sections
        : [SongSection(title: 'Local Songs', songs: lib.allSongs)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Row(children: [
            Icon(Icons.download_done_rounded, color: AurumTheme.gold, size: 18),
            const SizedBox(width: 8),
            Text(
              '${lib.allSongs.length} songs on device',
              style: TextStyle(
                  color: AurumTheme.textMutedOf(context), fontSize: 13),
            ),
          ]),
        ),
        ...sections.asMap().entries.map((e) => _StaggeredSection(
          index: e.key,
          child: Padding(
            padding: const EdgeInsets.only(top: 20, left: 16, right: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.value.title,
                    style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                // FIX: use asMap() so we have the song's actual position
                // within this section's list. Queue is also scoped to this
                // section so index always matches — previously queue was
                // lib.allSongs but index was from indexOf() on that same
                // list, which returned -1 for songs whose Song.== isn't
                // overridden (different object instances), causing the
                // fallback `index: 0` to always play the first song.
                ...e.value.songs.asMap().entries.map((entry) {
                  final idx  = entry.key;
                  final song = entry.value;
                  return SongTile(
                    song: song,
                    queue: e.value.songs,
                    index: idx,
                  );
                }),
              ],
            ),
          ),
        )),
      ],
    );
  }

  Widget _msg(BuildContext context, IconData icon, String msg,
      String label, VoidCallback onTap) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 48, color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: AurumTheme.textMutedOf(context))),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onTap,
            child: Text(label, style: TextStyle(color: AurumTheme.gold)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile Avatar Button
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileAvatarButton extends StatelessWidget {
  const _ProfileAvatarButton();

  Future<void> _openProfile(BuildContext context) async {
    HapticFeedback.lightImpact();
    final auth = context.read<AuthProvider>();

    if (!auth.isSignedIn) {
      // Not signed in → animated slide to LoginScreen
      await Navigator.push<bool>(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, __, ___) => const LoginScreen(),
          transitionsBuilder: (_, animation, __, child) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                  parent: animation, curve: Curves.easeOutCubic)),
              child: child,
            ),
          ),
        ),
      );
      return;
    }

    // Signed in → go straight to ProfileScreen
    await Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, __, ___) => const ProfileScreen(),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(CurvedAnimation(
                parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = context.watch<AuthProvider>().avatarUrl;

    return Padding(
      padding: const EdgeInsets.only(right: 16, left: 4),
      child: AurumPressable(
        scaleAmount: 0.90,
        onTap: () => _openProfile(context),
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AurumTheme.goldGradient,
          ),
          padding: const EdgeInsets.all(1.5),
          child: ClipOval(
            child: avatarUrl != null
                ? CachedNetworkImage(
                    imageUrl: avatarUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => _defaultIcon(context),
                  )
                : _defaultIcon(context),
          ),
        ),
      ),
    );
  }

  Widget _defaultIcon(BuildContext context) => Container(
        color: AurumTheme.bgOf(context),
        child: Icon(Icons.person_rounded,
            color: AurumTheme.textSecondaryOf(context), size: 20),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Status Pill — premium glass pill, taps open the source sheet
// ─────────────────────────────────────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  final VoidCallback onTap;
  const _StatusPill({required this.onTap});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> {
  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<SourceProvider>().isOnline;
    final dotColor = isOnline ? AurumTheme.gold : AurumTheme.textMutedOf(context);

    return AurumPressable(
      scaleAmount: 0.96,
      onTap: widget.onTap,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: AurumTheme.bgCardOf(context).withOpacity(0.6),
            border: Border.all(
              color: AurumTheme.dividerOf(context),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                  boxShadow: isOnline
                      ? [BoxShadow(color: dotColor.withOpacity(0.55), blurRadius: 5)]
                      : [],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                isOnline ? 'Online' : 'Offline',
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Source Sheet — premium glass bottom sheet for switching source mode
// ─────────────────────────────────────────────────────────────────────────────

class _SourceSheet extends StatelessWidget {
  final SourceProvider src;
  const _SourceSheet({required this.src});

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final bg = AurumTheme.bgCardOf(context);
    final border = AurumTheme.dividerOf(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 16),
          child: child,
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: bg.withOpacity(isLight ? 0.92 : 0.95),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              border: Border(top: BorderSide(color: border, width: 0.5)),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 32, height: 4,
                        margin: const EdgeInsets.only(bottom: 18),
                        decoration: BoxDecoration(
                          color: AurumTheme.textMutedOf(context).withOpacity(0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      'Playback Source',
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Choose where Aurum plays music from',
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _SourceOption(
                      icon: Icons.cloud_outlined,
                      label: 'Online Streaming',
                      subtitle: 'Stream music online',
                      selected: src.isOnline,
                      onTap: () {
                        if (!src.isOnline) src.toggle();
                        Navigator.pop(context);
                      },
                    ),
                    const SizedBox(height: 10),
                    _SourceOption(
                      icon: Icons.phone_iphone_rounded,
                      label: 'Offline Library',
                      subtitle: 'Play downloaded songs only',
                      selected: !src.isOnline,
                      onTap: () {
                        if (src.isOnline) src.toggle();
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceOption extends StatefulWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _SourceOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SourceOption> createState() => _SourceOptionState();
}

class _SourceOptionState extends State<_SourceOption> {
  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.98,
      onTap: widget.onTap,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.selected
                ? AurumTheme.gold.withOpacity(0.12)
                : AurumTheme.bgElevatedOf(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.selected
                  ? AurumTheme.gold.withOpacity(0.5)
                  : AurumTheme.dividerOf(context),
              width: 1,
            ),
          ),
          child: Row(children: [
            Icon(widget.icon,
                size: 20,
                color: widget.selected
                    ? AurumTheme.gold
                    : AurumTheme.textSecondaryOf(context)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.label,
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 2),
                  Text(widget.subtitle,
                      style: TextStyle(
                        color: AurumTheme.textSecondaryOf(context),
                        fontSize: 11.5,
                      )),
                ],
              ),
            ),
            if (widget.selected)
              Icon(Icons.check_circle_rounded, size: 18, color: AurumTheme.gold),
          ]),
        ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song Card — rounded corners + press scale animation
// ─────────────────────────────────────────────────────────────────────────────

class _SongCard extends StatefulWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongCard({required this.song, required this.queue, required this.index});

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard>
    with SingleTickerProviderStateMixin {
  bool _isTapping = false;
  late AnimationController _pressCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _scale = Tween(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() { _pressCtrl.dispose(); super.dispose(); }

  Future<void> _handleTap() async {
    if (_isTapping) return;
    _isTapping = true;
    unawaited(_pressCtrl.forward().then((_) => _pressCtrl.reverse()));
    HapticFeedback.selectionClick();
    context.read<RecentlyPlayedProvider>().addPlay(widget.song);
    context.read<PlayerProvider>()
        .playSong(widget.song, queue: widget.queue, index: widget.index);
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) _isTapping = false;
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isPlaying = context.select<PlayerProvider, bool>(
        (p) => p.currentSong?.id == song.id);

    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Container(
          width: 140,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Artwork ──
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AurumArtwork(
                      url: song.artworkUrl, size: 140, borderRadius: 12),
                ),
                // Playing overlay
                if (isPlaying)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 140, height: 140,
                      color: Colors.black.withOpacity(0.42),
                      child: const Icon(Icons.equalizer_rounded,
                          color: AurumTheme.gold, size: 30),
                    ),
                  ),
                // Gold border ring when playing
                if (isPlaying)
                  Container(
                    width: 140, height: 140,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AurumTheme.gold.withOpacity(0.65),
                        width: 1.5,
                      ),
                    ),
                  ),
              ]),
              // ── Title ──
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                child: Text(
                  song.title,
                  style: TextStyle(
                    color: isPlaying
                        ? AurumTheme.gold
                        : AurumTheme.textPrimaryOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // ── Artist ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  song.artist,
                  style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
// Artist Strip — 5-6 circular artist cards, random each hour
// ─────────────────────────────────────────────────────────────────────────────

class _ArtistStrip extends StatelessWidget {
  final List<ArtistSimple> artists;
  final bool loading;
  const _ArtistStrip({required this.artists, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Popular Artists',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 100,
            child: loading
                ? _buildShimmer(context)
                : artists.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: artists.length,
                        itemBuilder: (_, i) => _ArtistChip(artist: artists[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        itemBuilder: (_, __) => Container(
          width: 70,
          margin: const EdgeInsets.only(right: 16),
          child: Column(children: [
            const CircleAvatar(radius: 32, backgroundColor: Colors.white),
            const SizedBox(height: 6),
            Container(
              width: 50, height: 10,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ArtistChip extends StatelessWidget {
  final ArtistSimple artist;
  const _ArtistChip({required this.artist});

  @override
  Widget build(BuildContext context) {
    return AurumPressable(
      scaleAmount: 0.93,
      onTap: () async {
        final id = artist.id.isNotEmpty
            ? artist.id
            : await ApiService.searchArtistByName(artist.name);
        if (id == null || !context.mounted) return;
        AurumPageRoute.to(
          context,
          ArtistScreen(artistId: id, artistName: artist.name),
        );
      },
      child: Container(
        width: 70,
        margin: const EdgeInsets.only(right: 16),
        child: Column(children: [
          Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AurumTheme.gold.withOpacity(0.4), width: 1.5),
            ),
            child: ClipOval(
              child: CachedNetworkImage(
                imageUrl: artist.imageUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  color: AurumTheme.bgCardOf(context),
                  child: Icon(Icons.person_rounded,
                      color: AurumTheme.textMutedOf(context), size: 28),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: AurumTheme.bgCardOf(context),
                  child: Icon(Icons.person_rounded,
                      color: AurumTheme.textMutedOf(context), size: 28),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            artist.name,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Curated Playlists — Spotify-type big cards with gradient
// ─────────────────────────────────────────────────────────────────────────────

class _CuratedPlaylistsSection extends StatelessWidget {
  final int refreshKey;
  const _CuratedPlaylistsSection({this.refreshKey = 0});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trending Playlists',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 130,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: _kCuratedPlaylists.length,
              itemBuilder: (_, i) => _PlaylistCard(
                // New key per refresh forces a fresh State → fresh fetch,
                // so art + songs genuinely rotate on pull-to-refresh.
                key: ValueKey('${_kCuratedPlaylists[i].name}_$refreshKey'),
                playlist: _kCuratedPlaylists[i],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistCard extends StatefulWidget {
  final _PlaylistMeta playlist;
  const _PlaylistCard({super.key, required this.playlist});

  @override
  State<_PlaylistCard> createState() => _PlaylistCardState();
}

class _PlaylistCardState extends State<_PlaylistCard> {
  bool _pressed = false;
  String? _artUrl;
  bool _artFailed = false;
  List<Song>? _cachedSongs;

  @override
  void initState() {
    super.initState();
    _loadArt();
  }

  Future<void> _loadArt() async {
    try {
      final songs = await ApiService
          .fetchPlaylistSongs(widget.playlist.query, limit: 65)
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      // Cache the fetched songs on the card itself (not globally) so
      // tapping the card doesn't trigger a second, possibly different,
      // network fetch right after the thumbnail's fetch — art and the
      // opened tracklist always match for this card instance.
      _cachedSongs = songs;
      if (songs.isEmpty) {
        setState(() => _artFailed = true);
        return;
      }
      // Thumbnail must be the FIRST song's own artwork — that's what the
      // user will actually hear first when they tap the card, so the cover
      // should represent that exact track, not just any song in the set.
      // Only fall back to the next song's art if the first one is missing.
      final url = songs.first.artworkUrl.isNotEmpty
          ? songs.first.artworkUrl
          : songs.where((s) => s.artworkUrl.isNotEmpty).map((s) => s.artworkUrl).firstOrNull;
      if (url == null) {
        setState(() => _artFailed = true);
      } else {
        setState(() => _artUrl = url);
      }
    } catch (_) {
      // Fetch failed/timed out — stop showing the spinner, fall back to
      // the gradient+emoji card instead of spinning forever.
      if (mounted) setState(() => _artFailed = true);
    }
  }

  Future<void> _openPlaylist() async {
    HapticFeedback.selectionClick();
    // Show loading snackbar then fetch songs
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const SizedBox(
            width: 16, height: 16,
            child: Center(child: AurumM3Loader(width: 16, height: 2)),
          ),
          const SizedBox(width: 10),
          Text('Loading ${widget.playlist.name}...'),
        ]),
        duration: const Duration(seconds: 3),
        backgroundColor: AurumTheme.bgCardOf(context),
      ),
    );

    try {
      // Reuse the songs already fetched for the thumbnail when available —
      // same Saavn-first, variant-filtered set the user is about to see
      // art for. Only re-fetch if that hasn't resolved yet.
      final songs = _cachedSongs ?? await ApiService.fetchPlaylistSongs(widget.playlist.query, limit: 65);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (songs.isEmpty) return;

      // FIX: tapping the card used to immediately start playback of the
      // first song before the sheet even opened — jarring if the user
      // just wanted to browse the playlist first. Now tapping only opens
      // the song list; playback starts only when the user taps an
      // individual song inside it (each SongTile below already handles
      // that itself via its own onTap).
      showModalBottomSheet(
        context: context,
        backgroundColor: AurumTheme.bgCardOf(context),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          initialChildSize: 0.75,
          maxChildSize: 0.93,
          minChildSize: 0.4,
          expand: false,
          builder: (_, ctrl) => Column(children: [
            // Header
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AurumTheme.dividerOf(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: widget.playlist.color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(widget.playlist.emoji,
                        style: const TextStyle(fontSize: 24)),
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.playlist.name,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        )),
                    Text('${songs.length} songs',
                        style: TextStyle(
                            color: AurumTheme.textSecondaryOf(context),
                            fontSize: 12)),
                  ],
                ),
              ]),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: AurumTheme.dividerOf(context)),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                physics: const BouncingScrollPhysics(),
                itemCount: songs.length,
                itemBuilder: (ctx, i) => SongTile(
                  song: songs[i],
                  queue: songs,
                  index: i,
                ),
              ),
            ),
          ]),
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
  }

  Widget _gradientFallback(_PlaylistMeta p) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            p.color.withOpacity(0.9),
            p.color.withOpacity(0.5),
            Colors.black.withOpacity(0.4),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.playlist;
    final loading = _artUrl == null && !_artFailed;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: _openPlaylist,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 200,
          height: 130,
          margin: const EdgeInsets.only(right: 12),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(fit: StackFit.expand, children: [
            // Base layer: real album art once fetched, gradient fallback
            // otherwise. This used to fetch _artUrl and then never
            // actually paint it — the card always showed a flat gradient
            // even after the real artwork was ready, which is why the
            // playlists looked cheap/generic instead of like a real
            // JioSaavn/Spotify playlist cover.
            if (_artUrl != null)
              AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 260),
                child: CachedNetworkImage(
                  imageUrl: _artUrl!,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 260),
                  errorWidget: (_, __, ___) => _gradientFallback(p),
                ),
              )
            else
              _gradientFallback(p),

            // Darken for text legibility over any artwork
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.05),
                    Colors.black.withOpacity(0.55),
                  ],
                  stops: const [0.35, 1.0],
                ),
              ),
            ),

            // Centered loading spinner while the playlist's first track
            // (and therefore its cover art) is still resolving.
            if (loading)
              Center(
                child: AurumMorphLoader(size: 26),
              ),

            // Emoji top-right — small brand touch, stays even over real art
            Positioned(
              top: 12, right: 12,
              child: Text(p.emoji, style: const TextStyle(fontSize: 22,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 6)])),
            ),
            // Title bottom-left
            Positioned(
              left: 14, bottom: 14, right: 50,
              child: Text(
                p.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                ),
                maxLines: 2,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Home Premium Banner — shown to free users between sections
// ─────────────────────────────────────────────────────────────────────────────

class _HomePremiumBanner extends StatefulWidget {
  const _HomePremiumBanner();

  @override
  State<_HomePremiumBanner> createState() => _HomePremiumBannerState();
}

class _HomePremiumBannerState extends State<_HomePremiumBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmer;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat();
    _shimmer =
        CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOutSine);
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPremium = context.watch<PremiumProvider>().isPremium;
    if (isPremium) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: AurumPressable(
        scaleAmount: 0.97,
        onTap: () => AurumPageRoute.to(context, const PremiumScreen()),
        child: AnimatedBuilder(
          animation: _shimmer,
          builder: (_, __) {
            final t = _shimmer.value;
            final sweep = (t * 2.6) - 0.8;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: const [
                    Color(0xFF2A1E00),
                    Color(0xFF1A1200),
                  ],
                ),
                border: Border.all(
                  color: AurumTheme.gold.withOpacity(0.3),
                  width: 0.8,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AurumTheme.gold.withOpacity(0.08),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(children: [
                // Shimmer icon
                ShaderMask(
                  shaderCallback: (bounds) => LinearGradient(
                    colors: const [
                      AurumTheme.goldDark,
                      AurumTheme.goldLight,
                      AurumTheme.gold,
                    ],
                    stops: [
                      (sweep - 0.4).clamp(0.0, 1.0),
                      sweep.clamp(0.0, 1.0),
                      (sweep + 0.4).clamp(0.0, 1.0),
                    ],
                  ).createShader(bounds),
                  child: const Icon(Icons.workspace_premium_rounded,
                      color: Colors.white, size: 32),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ShaderMask(
                        shaderCallback: (b) => LinearGradient(
                          colors: const [
                            AurumTheme.goldDark,
                            AurumTheme.goldLight,
                          ],
                          stops: [
                            (sweep - 0.5).clamp(0.0, 1.0),
                            (sweep + 0.5).clamp(0.0, 1.0),
                          ],
                        ).createShader(b),
                        child: const Text(
                          'Unlock Aurum Plus ✦',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '320kbps • Offline • No ads • More',
                        style: TextStyle(
                          color: AurumTheme.gold.withOpacity(0.55),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    gradient: AurumTheme.goldGradient,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Try',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

// ignore: avoid_void_async
void unawaited(Future<void> f) {}
