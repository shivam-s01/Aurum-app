// =============================================================================
// FILE: lib/screens/mix_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Full-screen "album-style" page for the Home screen's curated
//   playlists (Trending Now, Party Anthems, 90s Bollywood, etc), Spotify-
//   style — big header art, Play + Save row, then the song list.
//
//   YT Music-style layout (2026-10-03 redesign): full-bleed sharp artwork
//   that fades into the palette-tinted page background, centered title
//   block, shuffle · Play · download row, description, track count, then
//   compact rows (wide thumbnail + title/artist + 3-dot). The whole header
//   scrolls away 1:1 with the list — no pinned bar, no parallax.
//
//   Takes an already-fetched `songs` list instead of an albumId to fetch
//   by — these are client-side curated queries (see _kCuratedPlaylists /
//   _PlaylistCard in home_screen.dart), not real JioSaavn album IDs, so
//   there's nothing to re-fetch from here.
// =============================================================================

import 'dart:async';
import '../utils/aurum_transitions.dart';
import 'library_screen.dart' show DownloadsScreen;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/aurum_image_cache.dart';
import '../providers/player_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/download_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_song_options_sheet.dart' show showAurumPlaylistOptions;
import '../widgets/mini_player_slot.dart';
import 'search_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_immersive_header.dart';
import '../utils/artwork_palette_cache.dart';

class MixScreen extends StatefulWidget {
  final String mixId;
  final String mixName;
  final String artworkUrl;
  final String emoji;
  final List<Song> songs;

  // OPT-IN pull-to-refresh (2026-08-14): off by default so the other 3
  // existing callers of this screen (home_screen.dart's other two
  // MixScreen pushes, library_screen.dart) are completely unaffected —
  // only the "Playlists For You" row's card tap sets these. When on,
  // pulling down at the top of the song list fetches more songs
  // related to `refreshSeed` (falls back to mixName if unset) via
  // ApiService.fetchMixRefreshSongs() and APPENDS them below the
  // existing list — Spotify/YT Music style, never replaces what's
  // already there so scroll position and whatever's currently playing/
  // visible never jumps.
  final bool enableRefresh;
  final String? refreshSeed;

  // Optional playlist description shown under the action row, YT
  // Music-style (e.g. "Experience the sound of 2026 with this playlist
  // featuring the biggest hits..."). Purely additive — every existing
  // caller that doesn't pass one simply skips that block (see build()).
  final String? description;

  // OPT-IN background top-up (2026-09-06, "ekdam youtube music jaisa
  // fast" perf fix): only set by _RealShelfPlaylistCard._open() in
  // home_screen.dart, which now opens this screen off a fast ~25-song
  // first page (see ApiService.resolveHomeShelfPlaylist's doc comment)
  // instead of blocking navigation on a full ~100-song fetch. When set,
  // this is called once right after the screen mounts and its result is
  // appended the same append-only way _onRefresh already appends
  // pull-to-refresh results — never replaces what's already showing, so
  // scroll position and whatever's currently playing/visible don't jump.
  // Every other existing caller leaves this null and behaves exactly as
  // before.
  final Future<List<Song>> Function()? autoLoadMore;

  const MixScreen({
    super.key,
    required this.mixId,
    required this.mixName,
    required this.artworkUrl,
    required this.emoji,
    required this.songs,
    this.enableRefresh = false,
    this.refreshSeed,
    this.description,
    this.autoLoadMore,
  });

  @override
  State<MixScreen> createState() => _MixScreenState();
}

class _MixScreenState extends State<MixScreen>
    with SingleTickerProviderStateMixin {
  // FIX ("artwork palette kuch sec delay ke baad snap hoti hai — sab
  // jagah instant, ekdam smooth chahiye"): this used to always start on
  // the hardcoded fallback and wait for _extractGlow()'s await to land
  // before ever painting the real color — even on a warm cache (this
  // exact artwork already extracted elsewhere: Full Player, a playlist
  // card, another detail screen just visited), which is the overwhelming
  // common case since the user almost always arrives here from a tile
  // that was already showing this same artwork. Seeding synchronously
  // from ArtworkPaletteCache.peek() — a plain map lookup, no async gap —
  // means the FIRST FRAME already paints the real color on a cache hit,
  // with zero pop-in. Only a genuine cold cache (first-ever look at this
  // artwork) still starts on the fallback and animates in once
  // _extractGlow's extraction resolves — see _glow (the ANIMATED value
  // every widget below actually paints with) vs this raw target.
  late Color _glowTarget = _peekInitialGlow();

  // Drives the smooth fade from whatever `_glow` currently reads to a
  // new `_glowTarget` (see _setGlowTarget below), instead of every
  // Container/BoxDecoration reading `_glow` directly snapping to the new
  // color the instant setState runs. A cache-hit never actually animates
  // anything (begin == end == the same seeded color from the very first
  // frame — see _peekInitialGlow), so this only ever visibly plays on a
  // genuine cold-cache resolution, which is exactly the one case that
  // needs a fade instead of a pop.
  late final AnimationController _glowController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late Animation<Color?> _glowAnimation = AlwaysStoppedAnimation(_glowTarget);

  /// The value every widget in build() actually paints with. Reads the
  /// live animated color while a fade is in flight, and the settled
  /// target once it's finished — callers never need to know the
  /// difference between "still fading" and "already arrived".
  Color get _glow => _glowAnimation.value ?? _glowTarget;

  /// Moves `_glowTarget` to [next] and smoothly animates `_glow` from
  /// its current value to it, instead of the old plain `_glowTarget =
  /// next` snap. Safe to call with `next == _glowTarget` (a cache-hit's
  /// no-op path in _extractGlow) — AnimationController.forward() on an
  /// already-1.0 controller is a harmless no-op, so this never needs its
  /// own "did it actually change" guard beyond what call sites already
  /// do.
  void _setGlowTarget(Color next) {
    final tween = ColorTween(begin: _glow, end: next);
    _glowTarget = next;
    _glowAnimation = tween.animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeOutCubic),
    );
    _glowController
      ..reset()
      ..forward();
  }

  /// Synchronous cache-hit seed for `_glowTarget`'s initializer — see its
  /// own doc comment above. `ensureContrastSafe` needs `context` (theme
  /// brightness), which isn't available yet at field-initializer time,
  /// so this intentionally returns the RAW cached tone unclamped; the
  /// safe/clamped version is applied moments later in
  /// didChangeDependencies, which the ~1-frame gap before that point
  /// already fully hides for a cache hit.
  Color _peekInitialGlow() {
    final url = widget.artworkUrl;
    if (url.isEmpty) return const Color(0xFF1A1630);
    final cached = ArtworkPaletteCache.peek(url);
    return cached?.darkMuted ?? const Color(0xFF1A1630);
  }

  bool _contrastSafeApplied = false;

  // Mutable working copy of widget.songs — only ever grows (append-only
  // on refresh, see _onRefresh), and only actually diverges from
  // widget.songs when enableRefresh is true. Every other caller
  // (enableRefresh: false) reads widget.songs directly everywhere below
  // exactly as before, so this has zero effect on them.
  late List<Song> _songs = widget.songs;

  // FIX ("playlist pe click karne pe pehle loading leta hai" — 2026-09-06):
  // _RealShelfPlaylistCard in home_screen.dart now navigates here
  // instantly with an empty `songs: []` and resolves the real tracklist
  // via autoLoadMore instead of blocking the tap on that network call.
  // Without this flag, the empty-state branch below ("No songs found")
  // would flash for however long that first resolve takes — wrong
  // message for "still loading," not "genuinely nothing here." True only
  // while genuinely waiting on that specific autoLoadMore-as-first-load
  // case; every other existing caller passes a real, already-populated
  // `songs` list and autoLoadMore null or "top-up only," so this stays
  // false for all of them exactly as before this fix.
  late bool _awaitingFirstLoad = widget.songs.isEmpty && widget.autoLoadMore != null;

  @override
  void initState() {
    super.initState();
    // Repaints on every animation tick while a glow fade is in flight
    // (see _setGlowTarget) — AnimationController itself doesn't trigger
    // Flutter rebuilds on its own; something has to translate its
    // ticks into setState calls so `_glow`'s getter (which reads
    // `_glowAnimation.value`) actually produces a new frame each tick
    // instead of only updating once the fade finishes.
    _glowController.addListener(() {
      if (mounted) setState(() {});
    });
    _extractGlow();
    // Fire-and-forget: see autoLoadMore's doc comment above. Deliberately
    // not awaited here — the screen must render immediately with
    // widget.songs already in hand; this only ever silently appends once
    // it resolves, same "no error surfaced, list just stays as-is on
    // failure" rule _onRefresh follows for the same reason (a background
    // top-up failing isn't something worth interrupting the user for).
    final autoLoadMore = widget.autoLoadMore;
    if (autoLoadMore != null) {
      autoLoadMore().then((more) {
        if (!mounted) return;
        setState(() {
          _songs = [..._songs, ...more];
          _awaitingFirstLoad = false;
        });
      }).catchError((_) {
        if (mounted) setState(() => _awaitingFirstLoad = false);
      });
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  bool _precachedHeaderArtwork = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // FIX ("artwork kuch sec baad aa raha hai, instant chahiye" —
    // 2026-09-07): the header's full-bleed AurumArtwork(size: 700) only
    // starts its network fetch once it actually builds — i.e. after the
    // route's push transition has already started sliding this screen
    // into view, so on a cold cache (first time seeing this particular
    // song's artwork) the header visibly sat on its placeholder for a
    // beat after arriving. Kicking off the exact same cached, same-size
    // image request here — didChangeDependencies is the correct, safe
    // lifecycle point for context-dependent work like precacheImage
    // (unlike initState, where MediaQuery/dependencies aren't fully
    // established yet), and it still runs before the header's own first
    // build call — means the fetch is already in flight (often finished)
    // by the time the header widget asks for it. _precachedHeaderArtwork
    // guards against re-firing on every dependency change (e.g. a theme
    // toggle) — this only needs to happen once per screen instance.
    if (!_precachedHeaderArtwork) {
      _precachedHeaderArtwork = true;
      _precacheHeaderArtwork();
    }
    // Applies ensureContrastSafe's clamp to whatever `_glowTarget`
    // currently holds — the synchronous cache-hit seed from
    // _peekInitialGlow() above, or (on a cold cache) still the plain
    // fallback until _extractGlow's await lands. Only needs `context`
    // (theme brightness) once, since didChangeDependencies can re-fire
    // on any dependency change (e.g. a theme toggle), not just the
    // first frame.
    if (!_contrastSafeApplied) {
      _contrastSafeApplied = true;
      final safe = ensureContrastSafe(
        _glowTarget,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      // Plain assign, not _setGlowTarget() — this runs before the very
      // first build, so there's no "current" painted color on screen yet
      // to fade FROM. Also re-seeds _glowAnimation itself (built in the
      // field initializer from the pre-contrast-clamp _glowTarget, so it
      // could otherwise briefly disagree with the now-clamped value)
      // with an already-settled animation at the correct color, so the
      // very first frame is a clean paint, never a flash of the
      // unclamped tone.
      _glowTarget = safe;
      _glowAnimation = AlwaysStoppedAnimation(safe);
    }
  }

  // FIX ("artwork kuch sec baad aa raha hai, instant chahiye" —
  // 2026-09-07): kicks off the exact same request AurumArtwork's network
  // branch will make for the header (same CachedNetworkImageProvider,
  // same AurumImageCache manager, same maxWidth as AurumArtwork's own
  // _cacheSize for size:700 — see aurum_artwork.dart) as early as
  // possible, so the fetch is already in flight (often finished) before
  // the header widget itself builds and asks for it. Guards mirror
  // AurumArtwork.build()'s own URL branching — content:// and local file
  // paths are never routed through a network image provider, so this
  // silently no-ops for those instead of throwing.
  void _precacheHeaderArtwork() {
    final url = widget.artworkUrl;
    if (url.isEmpty ||
        url.startsWith('content://') ||
        url.startsWith('/') ||
        url.startsWith('file://')) {
      return;
    }
    // Warms the exact request the full-bleed header artwork makes (same
    // upgraded URL, same decode width AurumArtwork uses for a sharp
    // size:double.infinity image, same cache manager) so it is already in
    // flight — often finished — before the header widget builds.
    precacheImage(
      CachedNetworkImageProvider(
        AurumArtwork.upgradeForFullPlayer(url),
        maxWidth: 1200,
        cacheManager: AurumImageCache(),
      ),
      context,
    ).catchError((_) {
      // A failed warm-up just means AurumArtwork's own build-time fetch
      // handles it normally (including its placeholder path).
    });
  }

  Future<void> _extractGlow() async {
    final c = await extractImmersiveColor(widget.artworkUrl);
    // CHANGE ("aankhon pe effect na kare ekdam beautiful rahe"): clamps
    // an occasional too-bright/oversaturated extracted swatch (rare for
    // a muted swatch specifically, but a neon/pastel cover can still
    // produce one) into the same safe luminance range Full Player's
    // background already enforces, so text/icons drawn over this glow
    // stay readable and the wash never reads as harsh regardless of
    // which theme mode is active.
    if (c != null && mounted) {
      final safe = ensureContrastSafe(
        c,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      // FIX ("palette kuch sec baad snap/pop hoti hai"): on a cache hit,
      // _peekInitialGlow() (see _glowTarget's field initializer) + the
      // didChangeDependencies contrast-safe pass above already applied
      // this exact same color before the first frame ever painted — so
      // by the time this await lands, `safe` is identical to what's
      // already showing, and moving the target again is a genuine
      // no-op. Only a real cold-cache resolution — where `safe` differs
      // from the fallback/seed already in `_glowTarget` — actually moves
      // it, and _setGlowTarget animates `_glow` (what every widget
      // below actually paints with) smoothly from its current value to
      // the new one instead of a hard snap.
      if (safe.value != _glowTarget.value) {
        setState(() => _setGlowTarget(safe));
      }
    }
  }

  /// Pull-to-refresh handler — only wired up when widget.enableRefresh
  /// is true (see build()'s RefreshIndicator). Fetches songs related to
  /// the mix's seed and appends whatever's genuinely new to the bottom
  /// of the list. A refresh that turns up nothing new (seed exhausted,
  /// transient failure) is silent — no error snackbar — since "no new
  /// songs right now" isn't something a user pulling to refresh needs
  /// interrupted for; the list just stays exactly as it was.
  Future<void> _onRefresh() async {
    final seed = (widget.refreshSeed?.trim().isNotEmpty ?? false)
        ? widget.refreshSeed!.trim()
        : widget.mixName;
    final existingIds = _songs.map((s) => s.id).toList();
    final more = await ApiService.fetchMixRefreshSongs(
      seed: seed,
      existingVideoIds: existingIds,
    );
    if (!mounted || more.isEmpty) return;
    setState(() {
      _songs = [..._songs, ...more];
    });
  }

  /// "100 tracks" — matches the reference's plain count line.
  String _summaryLine(List<Song> songs) {
    final count = songs.length;
    return '$count ${count == 1 ? 'track' : 'tracks'}';
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();
    // Reads _songs (not widget.songs directly) so refresh/top-up appends
    // show up immediately.
    final songs = _songs;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = immersiveScaffoldBg(context, _glow);
    final screenW = MediaQuery.of(context).size.width;
    final topInset = MediaQuery.of(context).padding.top;
    // Reference proportions: sharp artwork ~1.04x screen width tall, title
    // block sitting on its faded bottom edge.
    final headerH = screenW * 1.04;
    final titleColor = isDark ? Colors.white : AurumTheme.textPrimaryOf(context);
    final subColor = isDark
        ? Colors.white.withOpacity(0.72)
        : AurumTheme.textSecondaryOf(context);
    final description = (widget.description ?? '').trim();

    Widget body = Container(
      color: bg,
      child: CustomScrollView(
        // PERF: bigger cache so fast flings through a 100-song list don't
        // tear down and rebuild rows just outside the default buffer.
        cacheExtent: 1200,
        slivers: [
          // ── Header (scrolls away 1:1 with the list) ─────────────────────
          SliverToBoxAdapter(
            child: SizedBox(
              height: headerH,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Layer 0 — sharp full-bleed artwork.
                  Positioned.fill(
                    child: Hero(
                      tag: 'mix_art_${widget.mixId}',
                      child: widget.artworkUrl.isNotEmpty
                          ? AurumArtwork(
                              url: AurumArtwork.upgradeForFullPlayer(
                                  widget.artworkUrl),
                              size: double.infinity,
                              borderRadius: 0,
                            )
                          : Container(
                              color: _glow,
                              child: Center(
                                child: Icon(
                                  Icons.music_note_rounded,
                                  size: 64,
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              ),
                            ),
                    ),
                  ),

                  // Layer 1 — top scrim so status bar + floating pills
                  // stay readable on bright covers.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: topInset + 90,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.40),
                            Colors.black.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Layer 2 — bottom fade into the page background (same
                  // color the Scaffold paints, so there is no seam).
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            bg.withOpacity(0.0),
                            bg.withOpacity(0.0),
                            bg.withOpacity(0.55),
                            bg.withOpacity(0.92),
                            bg,
                          ],
                          stops: const [0.0, 0.40, 0.62, 0.82, 1.0],
                        ),
                      ),
                    ),
                  ),

                  // Title block — centered, on the faded bottom edge.
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 14,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.mixName,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Astra Music',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: subColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Playlist • ${DateTime.now().year}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: subColor.withOpacity(0.8),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Floating glass toolbar — back (left) and
                  // heart / search / overflow (right).
                  SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _GlassPill(
                            child: _GlassIconButton(
                              icon: Icons.arrow_back_rounded,
                              onTap: () {
                                AurumHaptics.selection();
                                Navigator.pop(context);
                              },
                            ),
                          ),
                          Consumer<FollowedAlbumsProvider>(
                            builder: (context, followedAlbums, _) {
                              final saved =
                                  followedAlbums.isFollowing(widget.mixId);
                              return _GlassPill(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _GlassIconButton(
                                      icon: saved
                                          ? Icons.favorite_rounded
                                          : Icons.favorite_border_rounded,
                                      iconColor: saved
                                          ? AurumTheme.accentOf(context)
                                          : Colors.white,
                                      onTap: () {
                                        AurumHaptics.selection();
                                        followedAlbums.toggleFollow(
                                          albumId: widget.mixId,
                                          name: widget.mixName,
                                          artworkUrl: widget.artworkUrl,
                                          isMix: true,
                                          songs: songs,
                                        );
                                        _snack(
                                            context,
                                            saved
                                                ? 'Removed from Library'
                                                : 'Added to Library');
                                      },
                                    ),
                                    _GlassIconButton(
                                      icon: Icons.search_rounded,
                                      onTap: () {
                                        AurumHaptics.selection();
                                        AurumDepthRoute.to(
                                            context, const SearchScreen());
                                      },
                                    ),
                                    _GlassIconButton(
                                      icon: Icons.more_vert_rounded,
                                      onTap: () => showAurumPlaylistOptions(
                                          context,
                                          songs: _songs),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Action row: shuffle · Play · download ───────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundButton(
                    icon: Icons.shuffle_rounded,
                    onTap: songs.isEmpty
                        ? null
                        : () {
                            AurumHaptics.medium();
                            final queue = List<Song>.from(songs)..shuffle();
                            player.playSong(queue.first,
                                queue: queue, index: 0, curatedQueue: true);
                          },
                  ),
                  const SizedBox(width: 12),
                  AurumPressable(
                    scaleAmount: 0.95,
                    onTap: songs.isEmpty
                        ? null
                        : () {
                            AurumHaptics.medium();
                            player.playSong(songs.first,
                                queue: songs, index: 0, curatedQueue: true);
                          },
                    child: Container(
                      height: 46,
                      constraints: const BoxConstraints(minWidth: 112),
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      decoration: BoxDecoration(
                        color: (isDark ? Colors.white : const Color(0xFF111111))
                            .withOpacity(songs.isEmpty ? 0.4 : 1.0),
                        borderRadius: BorderRadius.circular(23),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_arrow_rounded,
                              color:
                                  isDark ? Colors.black : Colors.white,
                              size: 24),
                          const SizedBox(width: 6),
                          Text(
                            'Play',
                            style: TextStyle(
                              color: isDark ? Colors.black : Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Consumer<DownloadProvider>(
                    builder: (context, downloads, _) {
                      final allDone = songs.isNotEmpty &&
                          songs.every((s) => downloads.isDownloaded(s.id));
                      return _RoundButton(
                        icon: allDone
                            ? Icons.download_done_rounded
                            : Icons.download_for_offline_outlined,
                        iconSize: 26,
                        onTap: songs.isEmpty
                            ? null
                            : () => _downloadMix(context, downloads),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          if (description.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                child: Text(
                  description,
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 14.5,
                    height: 1.4,
                  ),
                ),
              ),
            ),

          if (songs.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
                child: Text(
                  _summaryLine(songs),
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),

          if (songs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 56),
                child: Center(
                  child: _awaitingFirstLoad
                      // Still waiting on the first real fetch — spinner, not
                      // the "nothing found" message.
                      ? const CircularProgressIndicator()
                      : Text(l10n.albumNoSongsFound,
                          style: TextStyle(
                              color: AurumTheme.textMutedOf(context))),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => SongTile(
                  song: songs[i],
                  queue: songs,
                  index: i,
                  curatedQueue: true,
                  ytStyle: true,
                ),
                childCount: songs.length,
              ),
            ),

          // Quiet end-of-list hint only when pull-to-refresh is enabled.
          if (widget.enableRefresh && songs.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    l10n.mixPullForMore,
                    style: TextStyle(
                      color: AurumTheme.textMutedOf(context).withOpacity(0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );

    // Opt-in pull-to-refresh (append-only, see _onRefresh).
    if (widget.enableRefresh) {
      body = RefreshIndicator(
        onRefresh: _onRefresh,
        edgeOffset: topInset + 8,
        color: AurumTheme.accentOf(context),
        backgroundColor: AurumTheme.bgElevatedOf(context),
        child: body,
      );
    }

    final scaffold = Scaffold(
      backgroundColor: bg,
      bottomNavigationBar: const MiniPlayerSlot(),
      body: body,
    );

    // Dark mode: the header artwork runs under the status bar, so keep the
    // system icons light. Light mode keeps the app's global style (the
    // icons must stay readable once the header has scrolled away).
    if (!isDark) return scaffold;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: scaffold,
    );
  }

  // Shared, deduped toast handler — see aurum_snack.dart.
  void _snack(BuildContext context, String msg) {
    if (!mounted) return;
    AurumSnack.show(context, msg);
  }

  /// Queues every song in the mix for download via DownloadProvider,
  /// skipping ones already downloaded/in-progress, then opens the real
  /// Downloads screen so progress is visible. Reads _songs so appended
  /// songs are included too.
  Future<void> _downloadMix(
      BuildContext context, DownloadProvider downloads) async {
    final toQueue = _songs
        .where((s) =>
            !downloads.isDownloaded(s.id) && !downloads.isDownloading(s.id))
        .toList();
    if (toQueue.isEmpty) {
      _snack(context, 'Already downloaded');
      return;
    }
    for (final song in toQueue) {
      unawaited(downloads.download(song));
    }
    if (!context.mounted) return;
    AurumDepthRoute.to(context, const DownloadsScreen());
  }
}

/// Frosted-glass pill container for the floating header toolbar (back
/// button, and the heart/search/overflow group) — YT Music-style chrome
/// that floats directly over the artwork instead of a flat AppBar. Uses
/// a light, mostly-white tint (not black) so the blurred artwork colors
/// underneath actually read through — a true "frosted" look rather than
/// a dark chip sitting on top of the image.
///
/// PERF: BackdropFilter is the one genuinely non-free thing here (GPU
/// samples the layer behind it every frame it's on screen), so this is
/// used sparingly — two small pills, not one blur spanning the header —
/// and the sigma is kept modest (12) rather than the header background's
/// heavier blur, since a small pill doesn't need a strong blur to read
/// as "glass" and a lighter sigma is cheaper to composite on low-end GPUs.
class _GlassPill extends StatelessWidget {
  final Widget child;
  const _GlassPill({required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.22),
            borderRadius: BorderRadius.circular(24),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Single tap target inside a _GlassPill — plain IconButton-sized hit
/// area, no per-instance AnimationController (unlike AurumPressable) to
/// keep the header, which can hold up to 4 of these, cheap to build.
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;

  const _GlassIconButton({
    required this.icon,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        icon: Icon(icon, size: 21, color: iconColor),
        splashRadius: 20,
        onPressed: onTap,
      ),
    );
  }
}

/// Round control flanking the Play pill (shuffle, download). Soft
/// translucent circle that reads on both the dark and light page tints.
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double iconSize;

  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final disabled = onTap == null;
    final fg = AurumTheme.textPrimaryOf(context);
    return AurumPressable(
      scaleAmount: 0.9,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (isDark ? Colors.white : Colors.black)
              .withOpacity(isDark ? 0.12 : 0.07),
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: disabled ? fg.withOpacity(0.35) : fg,
        ),
      ),
    );
  }
}
