// =============================================================================
// FILE: lib/screens/mix_screen.dart
// PROJECT: Aurum Music
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
import 'package:flutter/services.dart';
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
import 'artist_screen.dart';
import 'full_player_screen.dart' show shareSong;
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

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

  const MixScreen({
    super.key,
    required this.mixId,
    required this.mixName,
    required this.artworkUrl,
    required this.emoji,
    required this.songs,
    this.enableRefresh = false,
    this.refreshSeed,
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
            expandedHeight: 320,
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  // Layer 1 — zoomed, heavily blurred artwork fills the
                  // whole header so there's never a flat/empty backdrop.
                  if (widget.artworkUrl.isNotEmpty)
                    Transform.scale(
                      scale: 1.4,
                      child: AurumArtwork(
                          url: widget.artworkUrl, size: 600, borderRadius: 0),
                    )
                  else
                    Container(color: AurumTheme.bgCardOf(context)),
                  BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(color: Colors.black.withOpacity(0.1)),
                  ),

                  // Layer 2 — palette-derived glow wash + dark anchor so
                  // text at the bottom always stays readable.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          _glow.withOpacity(0.38),
                          _glow.withOpacity(0.12),
                          Colors.black.withOpacity(0.55),
                          AurumTheme.bgOf(context),
                        ],
                        stops: const [0.0, 0.35, 0.75, 1.0],
                      ),
                    ),
                  ),

                  // Layer 3 — soft ambient glow orb behind the artwork
                  // card, echoing the Full Player's ambient-glow treatment
                  // without needing an AnimationController for a static
                  // header.
                  Positioned(
                    top: -40,
                    left: -40,
                    right: -40,
                    child: Container(
                      height: 220,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _glow.withOpacity(0.45),
                            _glow.withOpacity(0.0),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Foreground artwork card, centered, matching AlbumScreen.
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 44, 0, 0),
                      child: Center(
                        child: Container(
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.5),
                                blurRadius: 28,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: Hero(
                            tag: 'mix_art_${widget.mixId}',
                            // FIX: see matching comment in library_screen.dart's
                            // grid tile Hero — same page-slide + default-shuttle
                            // conflict causes a visible snap/glitch as the
                            // flight hands off to this (still page-sliding)
                            // destination. Simple scale-only shuttle avoids it.
                            flightShuttleBuilder: (context, animation, direction, from, to) {
                              return Material(
                                color: Colors.transparent,
                                child: ScaleTransition(scale: animation, child: to.widget),
                              );
                            },
                            child: Material(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              clipBehavior: Clip.antiAlias,
                              child: widget.artworkUrl.isNotEmpty
                                  ? AurumArtwork(
                                      url: widget.artworkUrl,
                                      size: 180,
                                      borderRadius: 14,
                                    )
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: AurumTheme.bgCardOf(context),
                                        borderRadius:
                                            BorderRadius.circular(14),
                                      ),
                                      child: Center(
                                        child: Text(widget.emoji,
                                            style: const TextStyle(
                                                fontSize: 48)),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 20,
                    child: Text(
                      widget.mixName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 8),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Center(
                child: Text(
                  _summaryLine(songs),
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                children: [
                  Consumer<DownloadProvider>(
                    builder: (context, downloads, _) {
                      return _ActionIcon(
                        icon: Icons.download_outlined,
                        onTap: songs.isEmpty
                            ? null
                            : () => _downloadMix(context, downloads),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  Consumer<FollowedAlbumsProvider>(
                    builder: (context, followedAlbums, _) {
                      final saved = followedAlbums.isFollowing(widget.mixId);
                      return AurumSaveButton(
                        saved: saved,
                        size: 40,
                        onTap: () => followedAlbums.toggleFollow(
                          albumId: widget.mixId,
                          name: widget.mixName,
                          artworkUrl: widget.artworkUrl,
                          isMix: true,
                          songs: songs,
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 4),
                  _ActionIcon(
                    icon: Icons.more_vert_rounded,
                    onTap: () => _showMixOptions(context),
                  ),
                  const Spacer(),
                  _ActionIcon(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    onTap: () => setState(() => _shuffle = !_shuffle),
                  ),
                  const SizedBox(width: 12),
                  AurumPressable(
                    scaleAmount: 0.92,
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
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: songs.isEmpty
                            ? AurumTheme.gold.withOpacity(0.4)
                            : AurumTheme.gold,
                        boxShadow: songs.isEmpty
                            ? null
                            : [
                                BoxShadow(
                                  color: AurumTheme.gold.withOpacity(0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.black,
                        size: 32,
                      ),
                    ),
                  ),
                ],
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
    showModalBottomSheet(
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                    for (final s in songs) {
                      unawaited(player.addToQueue(s));
                    }
                    _snack('Added ${songs.length} songs to queue');
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
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
                        Navigator.push(
                          widget.rootContext,
                          AurumPageRoute(
                            builder: (_) => ArtistScreen(artistName: name),
                          ),
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

/// Small circular icon button used in the action row (download / save /
/// overflow / shuffle). Local copy — same as AlbumScreen's _ActionIcon.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  const _ActionIcon({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return AurumPressable(
      scaleAmount: 0.88,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(
          icon,
          size: 22,
          color: disabled
              ? AurumTheme.textMutedOf(context).withOpacity(0.4)
              : active
                  ? AurumTheme.gold
                  : AurumTheme.textSecondaryOf(context),
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
