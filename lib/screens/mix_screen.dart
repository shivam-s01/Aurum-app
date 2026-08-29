// =============================================================================
// FILE: lib/screens/mix_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Full-screen "album-style" page for the Home screen's curated
//   playlists (Trending Now, Party Anthems, 90s Bollywood, etc), Spotify-
//   style — big header art, Play + Save row, then the song list.
//
//   Premium header: blurred/zoomed artwork background with a one-shot
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
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../providers/player_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/download_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_save_button.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import 'artist_screen.dart';
import 'search_screen.dart';
import 'full_player_screen.dart' show shareSong;
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

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

  @override
  void initState() {
    super.initState();
    _extractGlow();
  }

  Future<void> _extractGlow() async {
    final url = widget.artworkUrl;
    if (url.isEmpty || !url.startsWith('http')) return;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(url),
        size: const Size(100, 100),
      );
      final c = pg.vibrantColor?.color ??
          pg.lightVibrantColor?.color ??
          pg.dominantColor?.color;
      if (c != null && mounted) setState(() => _glow = c);
    } catch (_) {
      // Palette extraction is a cosmetic nicety — network hiccups or a
      // decode failure just keep the neutral fallback glow above.
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

    Widget body = CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: AurumTheme.bgOf(context),
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            // No leading/actions here — those are drawn as a floating
            // glass overlay below (YT Music-style: back / heart / search
            // / overflow float over the artwork and never collapse into
            // a flat pinned bar), so the SliverAppBar itself stays
            // chrome-free the whole time it's expanded.
            automaticallyImplyLeading: false,
            expandedHeight: 300,
            flexibleSpace: FlexibleSpaceBar(
              // PERF: collapseMode.pin (default) already avoids the parallax
              // recompute pin does on every scroll tick — kept implicit here,
              // no per-frame Transform beyond what FlexibleSpaceBar itself
              // does, since this header has no animation controllers of its
              // own (matches the file's original low-overhead intent).
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Layer 1 — full-bleed artwork fills the entire header,
                  // edge to edge, no card/frame — matches YT Music's
                  // playlist header treatment exactly.
                  if (widget.artworkUrl.isNotEmpty)
                    Hero(
                      tag: 'mix_art_${widget.mixId}',
                      flightShuttleBuilder:
                          (context, animation, direction, from, to) {
                        return Material(
                          color: Colors.transparent,
                          child: ScaleTransition(scale: animation, child: to.widget),
                        );
                      },
                      child: AurumArtwork(
                          url: widget.artworkUrl, size: 700, borderRadius: 0),
                    )
                  else
                    Container(
                      color: AurumTheme.bgCardOf(context),
                      child: Center(
                        // No-emoji requirement: uses Flutter's icon font
                        // (a vector glyph, not a Unicode emoji character)
                        // instead of rendering widget.emoji as text — this
                        // fallback can never show an emoji regardless of
                        // what any caller passes in.
                        child: Icon(
                          Icons.music_note_rounded,
                          size: 64,
                          color: AurumTheme.textMutedOf(context),
                        ),
                      ),
                    ),

                  // Layer 2 — bottom gradient scrim so the title stays
                  // readable over any artwork, then a palette-tinted wash
                  // for a bit of premium color instead of flat black.
                  //
                  // LIGHT-MODE FIX: this used to hand off straight from a
                  // 60%-black scrim to AurumTheme.bgOf(context) — fine in
                  // dark mode (that's already near-black) but in light
                  // mode bgOf() is a warm off-white, so the header ended
                  // in a jarring dark→cream seam right where the white
                  // title/glass-pill chrome above still needs a dark
                  // backdrop to read. Adding a near-opaque black stop
                  // just before the handoff keeps the whole photo area
                  // dark regardless of theme — the seam to the real
                  // (light or dark) body color happens in one final
                  // sliver-thin step instead of a visible jump.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.10),
                          _glow.withOpacity(0.18),
                          Colors.black.withOpacity(0.60),
                          Colors.black.withOpacity(0.92),
                          AurumTheme.bgOf(context),
                        ],
                        stops: const [0.0, 0.35, 0.72, 0.92, 1.0],
                      ),
                    ),
                  ),

                  // Title + source + type line, centered over the
                  // artwork's lower half — YT Music-style stacked block.
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 18,
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

          // Action row — shuffle (glass circle) · play/pause (filled
          // pill, YT-Music-style) · download (glass circle), centered.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _RoundGlassButton(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    onTap: () => setState(() => _shuffle = !_shuffle),
                  ),
                  const SizedBox(width: 14),
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
                      height: 44,
                      constraints: const BoxConstraints(minWidth: 118),
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      decoration: BoxDecoration(
                        color: songs.isEmpty
                            ? Colors.white.withOpacity(0.4)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(24),
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
                  const SizedBox(width: 14),
                  Consumer<DownloadProvider>(
                    builder: (context, downloads, _) {
                      return _RoundGlassButton(
                        icon: Icons.download_outlined,
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
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                _summaryLine(songs),
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (songs.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Text(l10n.albumNoSongsFound,
                    style:
                        TextStyle(color: AurumTheme.textMutedOf(context))),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => SongTile(
                  song: songs[i],
                  queue: songs,
                  index: i,
                  showIndex: true,
                  displayIndex: i + 1,
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
      backgroundColor: AurumTheme.bgOf(context),
      bottomNavigationBar: const MiniPlayerSlot(),
      body: body,
    );
  }

  void _snack(BuildContext context, String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(context),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
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

  const _MixOptionsSheet({
    required this.mixId,
    required this.mixName,
    required this.artworkUrl,
    required this.songs,
    required this.artists,
    required this.rootContext,
  });

  @override
  State<_MixOptionsSheet> createState() => _MixOptionsSheetState();
}

class _MixOptionsSheetState extends State<_MixOptionsSheet> {
  void _snack(String msg) {
    ScaffoldMessenger.of(widget.rootContext).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: AurumTheme.bgElevatedOf(widget.rootContext),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final downloads = context.watch<DownloadProvider>();
    final followedAlbums = context.watch<FollowedAlbumsProvider>();
    final saved = followedAlbums.isFollowing(widget.mixId);
    final songs = widget.songs;

    return Container(
      decoration: BoxDecoration(
        color: AurumTheme.bgElevatedOf(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
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
                  color: AurumTheme.gold,
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
                  color: AurumTheme.gold,
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
                  color: Colors.purpleAccent,
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
                  color: const Color(0xFFE1306C),
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
                  color: Colors.blueAccent,
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
                  color: Colors.greenAccent,
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
    return GestureDetector(
      onTap: () {
        AurumHaptics.selection();
        onTap();
      },
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.18), width: 0.8),
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
