// =============================================================================
// FILE: lib/screens/mix_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Full-screen "album-style" page for the Home screen's curated
//   playlists (Trending Now, Party Anthems, 90s Bollywood, etc), Spotify-
//   style — big header art, Play + Save row, then the song list.
//
//   Premium header: full-bleed, sharp artwork with a one-shot
//   palette-derived glow (same visual language as the Full Player screen —
//   see full_player_screen.dart's _extractColor — but static, no animation
//   controllers, since this screen doesn't need to live-update per frame).
//
//   Takes an already-fetched `songs` list instead of an albumId to fetch
//   by — these are client-side curated queries (see _kCuratedPlaylists /
//   _PlaylistCard in home_screen.dart), not real JioSaavn album IDs, so
//   there's nothing to re-fetch from here.
// =============================================================================

import 'dart:async';
import '../utils/aurum_transitions.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
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
import '../widgets/aurum_save_button.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import '../widgets/cast_button.dart';
import 'artist_screen.dart';
import 'search_screen.dart';
import 'full_player_screen.dart' show shareSong;
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';
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

class _MixScreenState extends State<MixScreen> {
  // Falls back to a dark neutral glow until (if) the palette resolves, so
  // the header never looks broken while the network image decodes.
  Color _glow = const Color(0xFF1A1630);
  bool _shuffle = false;

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
    // Warms BOTH header layers at once — the small sharp centered cover
    // (matches AurumArtwork's own maxWidth for size:500, see aurum_
    // artwork.dart's _cacheSize) and the blurred full-bleed ambient
    // backdrop (matches its capped low-res decode width for
    // isBlurredBackground/non-finite size). FIX ("ambient wash aur sharp
    // cover ek saath aane chahiye, ek pehle ek baad mein nahi"): without
    // this, only the sharp cover's request used to get kicked off early,
    // so on a cold cache the blurred backdrop still only started its
    // fetch once the header widget itself built — same "pop in late"
    // problem this whole precache exists to avoid, just on the other
    // layer now. Firing both here means both are already in flight
    // (often finished) before either widget asks for its image.
    precacheImage(
      CachedNetworkImageProvider(
        url,
        maxWidth: 1400,
        cacheManager: AurumImageCache(),
      ),
      context,
    ).catchError((_) {});
    precacheImage(
      // Matches AurumArtwork's own _cacheSize for isBlurredBackground:true
      // with size:double.infinity (220 — see aurum_artwork.dart), so this
      // hits the exact same cache key the header's ambient layer will ask
      // for, instead of warming a differently-sized decode that misses.
      CachedNetworkImageProvider(
        url,
        maxWidth: 220,
        cacheManager: AurumImageCache(),
      ),
      context,
    ).catchError((_) {
      // Same as every other precache in this app — a failed warm-up just
      // means AurumArtwork's own build-time fetch handles it normally
      // (including its own error/placeholder path), never a crash.
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
      setState(() => _glow = safe);
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

  /// Derives up to 3 distinct artist names across the mix's songs — same
  /// logic AlbumScreen uses to build its "GO TO" artist chips. Reads
  /// _songs (not widget.songs) so artists from refresh-appended songs
  /// are represented too, not just the original batch.
  List<String> get _creditedArtists {
    final seen = <String>{};
    final out = <String>[];
    for (final s in _songs) {
      final name = s.artist.trim();
      if (name.isEmpty) continue;
      for (final part in name.split(RegExp(r',|&|/'))) {
        final p = part.trim();
        if (p.isEmpty) continue;
        if (seen.add(p)) out.add(p);
        if (out.length >= 3) return out;
      }
    }
    return out;
  }

  /// "24 songs • 1 hr 32 min" style summary line, skipping songs with
  /// unknown duration rather than guessing — matches how AlbumScreen
  /// already treats missing durations elsewhere.
  String _summaryLine(List<Song> songs) {
    final count = songs.length;
    final totalSeconds = songs.fold<int>(
        0, (sum, s) => sum + (s.duration ?? 0));
    final songLabel = count == 1 ? 'song' : 'songs';
    if (totalSeconds <= 0) return '$count $songLabel';
    final hrs = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    final timeLabel = hrs > 0 ? '$hrs hr $mins min' : '$mins min';
    return '$count $songLabel • $timeLabel';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();
    // Reads _songs (not widget.songs directly) so a pull-to-refresh
    // append (see _onRefresh) shows up immediately — for every caller
    // that doesn't set enableRefresh, _songs is simply widget.songs
    // unchanged for the lifetime of this screen, so behavior is
    // identical to before.
    final songs = _songs;

    Widget body = Container(
      color: immersiveScaffoldBg(context, _glow),
      child: CustomScrollView(
        // PERF FIX (same class as home_screen.dart / artist_screen.dart /
        // library_screen.dart's matching fix): default Sliver cacheExtent
        // (250px) is too small once a full mix song list is loaded below
        // the header — fast flings tear down and rebuild sections just
        // outside that tiny buffer. Matching the same 1200 used elsewhere.
        cacheExtent: 1200,
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: immersiveScaffoldBg(context, _glow),
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            // No leading/actions here — those are drawn as a floating
            // glass overlay below (YT Music-style: back / heart / search
            // / overflow float over the artwork and never collapse into
            // a flat pinned bar), so the SliverAppBar itself stays
            // chrome-free the whole time it's expanded.
            automaticallyImplyLeading: false,
            expandedHeight: 340,
            flexibleSpace: FlexibleSpaceBar(
              // PERF: collapseMode.pin (default) already avoids the parallax
              // recompute pin does on every scroll tick — kept implicit here,
              // no per-frame Transform beyond what FlexibleSpaceBar itself
              // does, since this header has no animation controllers of its
              // own (matches the file's original low-overhead intent).
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Layer 0 — ambient ombré backdrop: the SAME artwork,
                  // heavily blurred and dimmed, filling the entire header
                  // edge to edge (Bloomee/YT-Music-style "glow wash"
                  // rather than a flat color). This is what makes the
                  // header feel alive at rest instead of a dead flat
                  // glow while the sharp cover above it loads — the two
                  // layers arrive together (see _precacheHeaderArtwork,
                  // which now warms both), so there's no more "3 sec
                  // later a big sharp square pops in over nothing."
                  if (widget.artworkUrl.isNotEmpty)
                    Opacity(
                      opacity: 0.55,
                      child: AurumArtwork(
                        url: widget.artworkUrl,
                        size: double.infinity,
                        borderRadius: 0,
                        isBlurredBackground: true,
                        fadeIn: false,
                      ),
                    )
                  else
                    Container(color: _glow),

                  // Layer 1 — small, centered, sharp cover with its own
                  // rounded corners + soft colored glow shadow — reads as
                  // a deliberate premium album card floating over the
                  // ambient wash, not a full-bleed photo. Hero'd so the
                  // shared-element transition from the home screen's
                  // card still feels continuous.
                  Align(
                    alignment: const Alignment(0, -0.08),
                    child: Hero(
                      tag: 'mix_art_${widget.mixId}',
                      flightShuttleBuilder:
                          (context, animation, direction, from, to) {
                        return Material(
                          color: Colors.transparent,
                          child: ScaleTransition(scale: animation, child: to.widget),
                        );
                      },
                      child: Container(
                        width: 168,
                        height: 168,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: _glow.withOpacity(0.55),
                              blurRadius: 40,
                              offset: const Offset(0, 16),
                            ),
                            BoxShadow(
                              color: Colors.black.withOpacity(0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: widget.artworkUrl.isNotEmpty
                              ? AurumArtwork(
                                  url: widget.artworkUrl,
                                  size: 500,
                                  borderRadius: 18,
                                )
                              : Container(
                                  color: _glow,
                                  child: Center(
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      size: 48,
                                      color: Colors.white.withOpacity(0.7),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),

                  // Layer 2 — short scrim washing the artwork's own
                  // extracted color through the photo. Kept short (not a
                  // long fade trying to carry the color alone) because
                  // the page background below (see immersiveScaffoldBg)
                  // already carries the same tone the rest of the way
                  // down — same split SimpMusic uses between its header
                  // scrim and its whole-page palette background.
                  DecoratedBox(decoration: immersiveHeaderScrim(_glow)),

                  // Layer 2b — SimpMusic-style frosted glass strip that
                  // fades in behind the collapsed bar as the header
                  // shrinks (see AurumGlassCollapseBar). Reads
                  // FlexibleSpaceBarSettings from this same
                  // FlexibleSpaceBar, so it needs zero extra scroll
                  // listening of its own. Sits above the scrim but below
                  // the title block below it, so the title is never the
                  // thing getting blurred.
                  Builder(builder: (context) {
                    final settings = context
                        .dependOnInheritedWidgetOfExactType<
                            FlexibleSpaceBarSettings>();
                    return AurumGlassCollapseBar(
                      glow: _glow,
                      expandRatio: settings != null
                          ? ((settings.currentExtent -
                                      settings.minExtent) /
                                  (settings.maxExtent - settings.minExtent))
                              .clamp(0.0, 1.0)
                          : 1.0,
                    );
                  }),

                  // Title + source + type line, centered under the small
                  // floating cover — Bloomee/Apple-Music-style stacked
                  // block sitting on the ambient wash rather than
                  // crammed onto the photo itself.
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
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 10),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Astra Music',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.92),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            shadows: const [
                              Shadow(color: Colors.black45, blurRadius: 6),
                            ],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Playlist • ${DateTime.now().year}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            shadows: const [
                              Shadow(color: Colors.black45, blurRadius: 6),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Floating glass toolbar — back button (left) and
                  // heart / search / overflow (right), each a frosted
                  // glass pill sitting directly over the artwork. Kept
                  // as one cheap BackdropFilter per pill (small blur
                  // radius) rather than one big blurred bar, so nothing
                  // extra gets blurred/repainted as the sliver collapses.
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
                                          ? AurumTheme.gold
                                          : Colors.white,
                                      onTap: () => followedAlbums.toggleFollow(
                                        albumId: widget.mixId,
                                        name: widget.mixName,
                                        artworkUrl: widget.artworkUrl,
                                        isMix: true,
                                        songs: songs,
                                      ),
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
                                      onTap: () => _showMixOptions(context),
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

          // Action row — YT-Music-style 5-control row matching the
          // reference exactly: queue(list) · shuffle · Play (dominant
          // filled pill, center) · save/add-to-library · cast. Every
          // icon here is a real, already-wired action elsewhere in the
          // app (queue via player.addSongsToQueue — same call
          // _GridOption's "Add to Queue" uses below; save via
          // FollowedAlbumsProvider.toggleFollow — same call the header's
          // save button and _GridOption's "Add to Library" use; cast via
          // the shared CastIconButton used on the full player) — nothing
          // new or fake, just surfaced here too so the row reads exactly
          // like the reference screenshot's control strip.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 22),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _RoundGlassButton(
                    icon: Icons.queue_music_rounded,
                    onTap: songs.isEmpty
                        ? null
                        : () async {
                            AurumHaptics.light();
                            final added = await player.addSongsToQueue(songs);
                            _snack(context, added > 0
                                ? 'Added $added song${added == 1 ? '' : 's'} to queue'
                                : 'Already in queue');
                          },
                  ),
                  _RoundGlassButton(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    onTap: () => setState(() => _shuffle = !_shuffle),
                  ),
                  AurumPressable(
                    scaleAmount: 0.95,
                    onTap: songs.isEmpty
                        ? null
                        : () {
                            AurumHaptics.medium();
                            final queue = _shuffle
                                ? (List<Song>.from(songs)..shuffle())
                                : songs;
                            player.playSong(queue.first,
                                queue: queue, index: 0, curatedQueue: true);
                          },
                    child: Container(
                      // SPACING FIX — bumped 44→50 to match reference's
                      // bigger, more dominant center Play pill.
                      height: 50,
                      constraints: const BoxConstraints(minWidth: 110),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      decoration: BoxDecoration(
                        color: songs.isEmpty
                            ? Colors.white.withOpacity(0.4)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(27),
                        // LIGHT-MODE FIX: a flat white pill sits with
                        // barely any edge definition against light
                        // mode's warm off-white body background (the
                        // header photo is always dark here, but this
                        // row lives in the scrollable body below it) —
                        // a soft shadow keeps the pill reading as a
                        // raised, tappable control in both themes
                        // instead of visually melting into the page.
                        boxShadow: songs.isEmpty
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.18),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow_rounded,
                              color: Colors.black, size: 22),
                          SizedBox(width: 6),
                          Text(
                            'Play',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Consumer<FollowedAlbumsProvider>(
                    builder: (context, followedAlbums, _) {
                      final saved = followedAlbums.isFollowing(widget.mixId);
                      return _RoundGlassButton(
                        icon: saved
                            ? Icons.bookmark_rounded
                            : Icons.add_rounded,
                        active: saved,
                        onTap: () {
                          followedAlbums.toggleFollow(
                            albumId: widget.mixId,
                            name: widget.mixName,
                            artworkUrl: widget.artworkUrl,
                            isMix: true,
                            songs: songs,
                          );
                          _snack(context, saved
                              ? 'Removed from Library'
                              : 'Added to Library');
                        },
                      );
                    },
                  ),
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AurumTheme.bgSurfaceOf(context),
                    ),
                    child: const Center(
                      child: CastIconButton(size: 21),
                    ),
                  ),
                ],
              ),
            ),
          ),

          if ((widget.description ?? '').trim().isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Text(
                  widget.description!.trim(),
                  style: TextStyle(
                    color: AurumTheme.textSecondaryOf(context),
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              // SPACING FIX (see control row comment below) — top bumped
              // 16→22 so this line doesn't sit crammed right under the
              // header/description above it.
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 4),
              child: Text(
                _summaryLine(songs),
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: _awaitingFirstLoad
                    // Genuinely still waiting on the first real fetch
                    // (see _awaitingFirstLoad's doc comment) — a spinner
                    // here, not the "nothing found" message, since we
                    // don't yet know whether this mix has songs or not.
                    ? const CircularProgressIndicator()
                    : Text(l10n.albumNoSongsFound,
                        style: TextStyle(
                            color: AurumTheme.textMutedOf(context))),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                // FEATURE ("1 2 3 4 count number hata do" — same
                // no-numbering convention already used on the artist
                // page's song lists): plain tiles, no index column.
                (context, i) => SongTile(
                  song: songs[i],
                  queue: songs,
                  index: i,
                  curatedQueue: true,
                ),
                childCount: songs.length,
              ),
            ),
          // Subtle end-of-list marker only when refresh is enabled and
          // there's something to end — mirrors Spotify's quiet "Pull to
          // refresh for more" style hint instead of just trailing off
          // into blank space, without implying auto-loading is happening.
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

    // enableRefresh wraps the exact same scroll view in a
    // RefreshIndicator — CustomScrollView's physics already support the
    // pull gesture, so this is purely additive and never runs for the
    // other 3 existing MixScreen callers (default enableRefresh: false
    // leaves `body` untouched above).
    if (widget.enableRefresh) {
      body = RefreshIndicator(
        onRefresh: _onRefresh,
        color: AurumTheme.gold,
        backgroundColor: AurumTheme.bgElevatedOf(context),
        child: body,
      );
    }

    return Scaffold(
      backgroundColor: immersiveScaffoldBg(context, _glow),
      bottomNavigationBar: const MiniPlayerSlot(),
      body: body,
    );
  }

  // Shared, deduped toast handler — see aurum_snack.dart.
  void _snack(BuildContext context, String msg) {
    if (!mounted) return;
    AurumSnack.show(context, msg);
  }

  /// Queues every song in the mix for download via DownloadProvider,
  /// skipping ones already downloaded/in-progress. Mirrors AlbumScreen's
  /// bulk-download flow. Reads _songs so refresh-appended songs are
  /// included in "download all" too, not just the original batch.
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
    _snack(context, 'Downloading ${toQueue.length} song(s)…');
    for (final song in toQueue) {
      unawaited(downloads.download(song));
    }
  }

  void _showMixOptions(BuildContext context) {
    final rootContext = context;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _MixOptionsSheet(
        mixId: widget.mixId,
        mixName: widget.mixName,
        artworkUrl: widget.artworkUrl,
        songs: _songs,
        artists: _creditedArtists,
        rootContext: rootContext,
        // PREMIUM TINT ("options bhi dead lag rahe hai" — reference:
        // full_player_screen.dart's _PremiumOptionsSheet, which already
        // tints its own sheet background from the now-playing song's
        // extracted color instead of a flat theme surface). This screen
        // already extracted _glow from the SAME artwork for the header —
        // passing it through here means the sheet visually continues the
        // header's color instead of hard-cutting to a flat neutral panel
        // the instant it opens.
        glow: _glow,
      ),
    );
  }
}

/// Premium mix-level options sheet — identical pattern to AlbumScreen's
/// _AlbumOptionsSheet, adapted for a mix (isMix: true save + no fetch-by-id).
class _MixOptionsSheet extends StatefulWidget {
  final String mixId;
  final String mixName;
  final String artworkUrl;
  final List<Song> songs;
  final List<String> artists;
  final BuildContext rootContext;
  final Color glow;

  const _MixOptionsSheet({
    required this.mixId,
    required this.mixName,
    required this.artworkUrl,
    required this.songs,
    required this.artists,
    required this.rootContext,
    required this.glow,
  });

  @override
  State<_MixOptionsSheet> createState() => _MixOptionsSheetState();
}

class _MixOptionsSheetState extends State<_MixOptionsSheet> {
  // Shared, deduped toast handler — see aurum_snack.dart.
  void _snack(String msg) {
    AurumSnack.show(widget.rootContext, msg);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final downloads = context.watch<DownloadProvider>();
    final followedAlbums = context.watch<FollowedAlbumsProvider>();
    final saved = followedAlbums.isFollowing(widget.mixId);
    final songs = widget.songs;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Same lerp-toward-dark tint full_player_screen.dart's premium sheet
    // uses — keeps the color readable/muted at sheet size instead of the
    // loud raw glow, while still clearly carrying the playlist's own hue
    // rather than a generic elevated-surface gray.
    final bgColor = isDark
        ? Color.lerp(widget.glow, const Color(0xFF0C0C18), 0.55)!
        : Color.lerp(widget.glow, Colors.white, 0.88)!;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withOpacity(0.08)
                : Colors.black.withOpacity(0.06),
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
              color: AurumTheme.dividerOf(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Mix header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: Row(
              children: [
                AurumArtwork(
                    url: widget.artworkUrl, size: 56, borderRadius: 10),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.mixName,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.artists.isNotEmpty
                            ? widget.artists.join(' • ')
                            : 'Playlist',
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: saved
                        ? AurumTheme.gold.withOpacity(0.12)
                        : AurumTheme.bgSurfaceOf(context),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AurumSaveButton(
                      saved: saved,
                      size: 20,
                      onTap: () => followedAlbums.toggleFollow(
                        albumId: widget.mixId,
                        name: widget.mixName,
                        artworkUrl: widget.artworkUrl,
                        isMix: true,
                        songs: songs,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          Divider(color: AurumTheme.dividerOf(context), height: 1),

          // Options grid
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.8,
              children: [
                _GridOption(
                  icon: Icons.play_arrow_rounded,
                  label: 'Play',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    if (songs.isEmpty) return;
                    Navigator.pop(context);
                    unawaited(
                        player.playSong(songs.first, queue: songs, index: 0, curatedQueue: true));
                  },
                ),
                _GridOption(
                  icon: Icons.shuffle_rounded,
                  label: 'Shuffle Play',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    if (songs.isEmpty) return;
                    Navigator.pop(context);
                    final shuffled = List<Song>.from(songs)..shuffle();
                    unawaited(player.playSong(shuffled.first,
                        queue: shuffled, index: 0, curatedQueue: true));
                  },
                ),
                _GridOption(
                  icon: Icons.queue_music_rounded,
                  label: 'Add to Queue',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    if (songs.isEmpty) return;
                    Navigator.pop(context);
                    unawaited(player.addSongsToQueue(songs).then((added) {
                      _snack(added > 0
                          ? 'Added $added song${added == 1 ? '' : 's'} to queue'
                          : 'Already in queue');
                    }));
                  },
                ),
                _GridOption(
                  icon: saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  label: saved ? 'Saved to Library' : 'Add to Library',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    followedAlbums.toggleFollow(
                      albumId: widget.mixId,
                      name: widget.mixName,
                      artworkUrl: widget.artworkUrl,
                      isMix: true,
                      songs: songs,
                    );
                    _snack(saved ? 'Removed from Library' : 'Added to Library');
                  },
                ),
                _GridOption(
                  icon: Icons.download_outlined,
                  label: 'Download All',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    if (songs.isEmpty) return;
                    final toQueue = songs
                        .where((s) =>
                            !downloads.isDownloaded(s.id) &&
                            !downloads.isDownloading(s.id))
                        .toList();
                    if (toQueue.isEmpty) {
                      _snack('Already downloaded');
                      return;
                    }
                    for (final s in toQueue) {
                      unawaited(downloads.download(s));
                    }
                    _snack('Downloading ${toQueue.length} song(s)…');
                  },
                ),
                _GridOption(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  color: AurumTheme.textPrimaryOf(context),
                  onTap: () {
                    Navigator.pop(context);
                    if (songs.isNotEmpty) {
                      shareSong(context, songs.first);
                    }
                  },
                ),
              ],
            ),
          ),

          if (widget.artists.isNotEmpty) ...[
            Divider(color: AurumTheme.dividerOf(context), height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('GO TO',
                    style: TextStyle(
                        color: AurumTheme.textMutedOf(context),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4)),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  for (final name in widget.artists)
                    _ArtistChip(
                      name: name,
                      onTap: () {
                        Navigator.pop(context);
                        AurumDepthRoute.to(
                          widget.rootContext,
                          ArtistScreen(artistName: name),
                        );
                      },
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
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

/// Circular action button flanking the header's filled Play pill
/// (shuffle, download) — YT Music's row of round buttons either side of
/// the solid play control. Uses the theme's surface color rather than a
/// hardcoded white glass tint: this row sits in the scrollable body
/// below the artwork header (not over the photo itself), so on light
/// mode a translucent-white fill would nearly vanish against the pale
/// background — a plain theme-aware surface circle reads correctly in
/// both dark and light mode.
class _RoundGlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  const _RoundGlassButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return AurumPressable(
      scaleAmount: 0.9,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? AurumTheme.gold.withOpacity(0.16)
              : AurumTheme.bgSurfaceOf(context),
        ),
        child: Icon(
          icon,
          size: 21,
          color: disabled
              ? AurumTheme.textMutedOf(context).withOpacity(0.4)
              : active
                  ? AurumTheme.gold
                  : AurumTheme.textPrimaryOf(context),
        ),
      ),
    );
  }
}

/// Local copy of the icon-grid option tile used in the mix options sheet.
class _GridOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _GridOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () {
        AurumHaptics.selection();
        onTap();
      },
      child: Container(
        // PREMIUM DEPTH ("options ekdum flat/dead lag rahe hai" — every
        // button used to be one flat surface color with a hairline
        // border and no shadow at all, so on a dark sheet the whole grid
        // read as a single undifferentiated slab rather than distinct
        // tappable buttons. A soft top-highlight-to-transparent gradient
        // (glass-catching-light look) plus a real drop shadow gives each
        // tile its own raised presence — cheap to paint (flat gradient +
        // one shadow, no blur/image) so this costs nothing at sheet-open
        // time even with 6+ tiles in the grid.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [Colors.white.withOpacity(0.09), Colors.white.withOpacity(0.03)]
                : [Colors.white.withOpacity(0.9), Colors.white.withOpacity(0.55)],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.12)
                : Colors.black.withOpacity(0.06),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.22 : 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 19),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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

/// Local copy of the "GO TO" artist chip used in the mix options sheet.
class _ArtistChip extends StatelessWidget {
  final String name;
  final IconData icon;
  final VoidCallback? onTap;

  const _ArtistChip({
    required this.name,
    this.onTap,
    this.icon = Icons.person_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: AurumTheme.gold),
          const SizedBox(width: 6),
          Text(
            name,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ]),
      ),
    );
  }
}

