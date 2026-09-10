// =============================================================================
// FILE: lib/screens/album_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Shows the song list inside an album / single — premium,
//   streaming-app-grade layout: centered artwork card with soft shadow,
//   artist avatar chips, meta row, and a floating play FAB over an
//   icon action row (download / save / overflow / shuffle).
// =============================================================================

import 'dart:async';
import '../utils/aurum_transitions.dart';
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/artist.dart';
import '../providers/player_provider.dart';
import '../providers/followed_albums_provider.dart';
import '../providers/download_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_save_button.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import 'artist_screen.dart';
import 'full_player_screen.dart' show shareSong;
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_sheet.dart';
import '../utils/aurum_immersive_header.dart';
import '../utils/artwork_palette_cache.dart';

class AlbumScreen extends StatefulWidget {
  final String albumId;
  final String albumName;
  final String artworkUrl;

  const AlbumScreen({
    super.key,
    required this.albumId,
    required this.albumName,
    required this.artworkUrl,
  });

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
  List<Song> _songs = [];
  bool _loading = true;
  bool _shuffle = false;
  late String _artworkUrl = widget.artworkUrl;
  // "Other versions" / "More by [artist]" — real InnerTube shelves parsed
  // straight off the same album browse response _load() already fetches
  // (see ApiService._parseAlbumRelatedShelves), never a separate call.
  List<AlbumRelatedShelf> _relatedShelves = const [];
  // FIX ("2-3 sec mai aane wala artwork/glow akward lagta hai"): if this
  // artwork was already seen anywhere else in the app (the search/album
  // card the user just tapped, an artist page, etc — the overwhelmingly
  // common case, since you always arrive here FROM some card already
  // showing this same art), ArtworkPaletteCache.peek() resolves it
  // synchronously, so the very first frame already paints the real glow
  // — no flat placeholder flash while _extractGlow's async lookup catches
  // up. Only a genuinely first-ever-seen album (fresh deep link, cold
  // cache) still falls through to the dark neutral default below.
  late Color _glow = _peekInitialGlow();

  Color _peekInitialGlow() {
    final cached = ArtworkPaletteCache.peek(widget.artworkUrl);
    if (cached != null) {
      return ensureContrastSafe(cached.darkMuted, isLight: false);
    }
    return const Color(0xFF1A1630);
  }

  @override
  void initState() {
    super.initState();
    _load();
    _extractGlow(widget.artworkUrl);
  }

  Future<void> _extractGlow(String url) async {
    final c = await extractImmersiveColor(url);
    // Same contrast-safety clamp as mix_screen.dart's matching fix.
    if (c != null && mounted) {
      final safe = ensureContrastSafe(
        c,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      setState(() => _glow = safe);
    }
  }

  Future<void> _load() async {
    // FIX ("YT se complete albums aaye ekdam top grade"): use the
    // artwork+songs variant so a YT album can upgrade its header banner
    // from the small search-card thumbnail (passed in via widget.artworkUrl)
    // to the album's own dedicated high-res header image, same source the
    // official YT Music album page uses. Saavn albums and any failure case
    // both come back with an empty headerArtworkUrl, so the widget-provided
    // artwork keeps working exactly as before for them.
    final result = await ApiService.fetchAlbumSongsWithArtwork(widget.albumId);
    if (!mounted) return;
    setState(() {
      _songs = result.songs;
      if (result.headerArtworkUrl.isNotEmpty) _artworkUrl = result.headerArtworkUrl;
      _relatedShelves = result.relatedShelves;
      _loading = false;
    });
    if (result.headerArtworkUrl.isNotEmpty) _extractGlow(result.headerArtworkUrl);
  }

  /// Derives up to 3 distinct artist names across the album's songs —
  /// call sites don't pass artist/year separately, so we build the
  /// "Artist A • Artist B • Artist C" credit line from the loaded songs,
  /// same source SongTile already trusts for per-track artist text.
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

  String? get _year {
    for (final s in _songs) {
      if (s.year != null && s.year!.trim().isNotEmpty) return s.year;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();
    final artists = _creditedArtists;
    final year = _year;

    return Scaffold(
      backgroundColor: immersiveScaffoldBg(context, _glow),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: Container(
        color: immersiveScaffoldBg(context, _glow),
        child: CustomScrollView(
        slivers: [
          SliverAppBar(
            // FIX ("artwork aur sab ek sath upar scroll ho, status bar
            // tak" — 2026-09-07): see matching comment in mix_screen.dart.
            // pinned:true was leaving a leftover kToolbarHeight strip the
            // banner got stuck behind instead of scrolling fully away.
            pinned: false,
            backgroundColor: immersiveScaffoldBg(context, _glow),
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            expandedHeight: 460,
            flexibleSpace: FlexibleSpaceBar(
              // BANNER HEADER ("ekdam banner-style header chahiye jaisa
              // screenshot mein hai, full-width artwork + overlay text" —
              // reference screenshot): the artwork used to sit in a small
              // centered 220x220 shadowed card with the title/artist/meta
              // as a separate plain-text sliver below it. This replaces
              // that with a full-bleed banner — the artwork fills the
              // entire header width/height, and the title/artist/meta
              // sit directly on top of it near the bottom, readable via
              // the same immersiveHeaderScrim gradient (now doubling as
              // both the color wash AND the text-legibility fade, same
              // as the reference's dark-to-light overlay on the photo).
              background: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    child: Hero(
                      tag: 'album_art_${widget.albumId}',
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
                      child: SizedBox.expand(
                        child: AurumArtwork(
                          url: _artworkUrl,
                          size: 460,
                          borderRadius: 0,
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
                    // Same short muted-glow scrim mix_screen.dart and
                    // artist_screen.dart use — now also carrying the
                    // text-legibility job the old separate title sliver
                    // didn't need, since the title now sits on the photo.
                    decoration: immersiveHeaderScrim(_glow),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              widget.albumName,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                height: 1.15,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 10),
                            if (artists.isNotEmpty) ...[
                              Text(
                                artists.join(' • '),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            Text(
                              [
                                'Album',
                                if (year != null) year,
                              ].join(' • '),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // REMOVED ("artwork ek sath upar scroll ho" fix,
                  // 2026-09-07): see matching comment in mix_screen.dart —
                  // pinned:false means no leftover collapsed strip for
                  // this to frost anymore.
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Row(
                // ACTION ROW REBUILD ("buttons bhi ekdam screenshot jaisa" —
                // reference screenshot): the reference shows exactly 5 items
                // spread evenly across the row — Download, Shuffle, a wide
                // "Play" pill with a text label (not a bare circular play
                // icon), a Save/Add icon, and a trailing options/queue
                // icon — every icon sitting in its own soft round grey
                // circle. This replaces the old 6-item layout (Download +
                // Save + More grouped left, Shuffle + a plain circular
                // play icon grouped right) with that same 5-across shape.
                // The old "More options" sheet (_showAlbumOptions) isn't
                // dropped — it now lives on the trailing icon instead of
                // its own separate button, so nothing behind it is lost.
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Consumer<DownloadProvider>(
                    builder: (context, downloads, _) {
                      return _ActionIcon(
                        icon: Icons.download_outlined,
                        onTap: _songs.isEmpty
                            ? null
                            : () => _downloadAlbum(context, downloads),
                      );
                    },
                  ),
                  _ActionIcon(
                    icon: Icons.shuffle_rounded,
                    active: _shuffle,
                    onTap: () => setState(() => _shuffle = !_shuffle),
                  ),
                  AurumPressable(
                    scaleAmount: 0.96,
                    onTap: _songs.isEmpty
                        ? null
                        : () {
                            final queue = _shuffle
                                ? (List<Song>.from(_songs)..shuffle())
                                : _songs;
                            player.playSong(queue.first,
                                queue: queue, index: 0, curatedQueue: true);
                          },
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      decoration: BoxDecoration(
                        color: _songs.isEmpty
                            ? AurumTheme.accentOf(context).withOpacity(0.4)
                            : AurumTheme.accentOf(context),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: _songs.isEmpty
                            ? null
                            : [
                                BoxShadow(
                                  color: AurumTheme.accentOf(context).withOpacity(0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.black,
                            size: 22,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l10n.commonPlay,
                            style: const TextStyle(
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
                      final saved = followedAlbums.isFollowing(widget.albumId);
                      return _ActionIcon(
                        // ICON MATCH ("+ click pr playlist save ho jaye" —
                        // reference screenshot shows a plain "+" here, not
                        // a bookmark-style save icon): same toggleFollow
                        // action as before (save/add this album), just a
                        // plain add icon instead of AurumSaveButton's own
                        // bookmark shape, matching the reference row.
                        icon: Icons.add_rounded,
                        active: saved,
                        onTap: () => followedAlbums.toggleFollow(
                          albumId: widget.albumId,
                          name: widget.albumName,
                          artworkUrl: _artworkUrl,
                        ),
                      );
                    },
                  ),
                  _ActionIcon(
                    icon: Icons.list_rounded,
                    onTap: () => _showAlbumOptions(context),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: AurumMorphLoader(size: 56)),
            )
          else if (_songs.isEmpty)
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
                  song: _songs[i],
                  queue: _songs,
                  index: i,
                  showIndex: true,
                  displayIndex: i + 1,
                  curatedQueue: true,
                ),
                childCount: _songs.length,
              ),
            ),
          // "Other versions" / "More by [artist]" — real InnerTube shelves
          // straight off this same album's browse response, YT Music
          // style. Each shelf gets its own horizontal-scroll row of album
          // cards, matching the reference layout shown below the
          // tracklist. Omitted entirely when the album genuinely has no
          // such shelves (nothing invented) or while still loading.
          if (!_loading)
            for (final shelf in _relatedShelves)
              SliverToBoxAdapter(
                child: _AlbumRelatedShelfSection(shelf: shelf),
              ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
        ),
      ),
    );
  }

  // Shared, deduped toast handler — see aurum_snack.dart.
  void _snack(BuildContext context, String msg) {
    if (!mounted) return;
    AurumSnack.show(context, msg);
  }

  /// Queues every song in the album for download via DownloadProvider,
  /// skipping ones already downloaded/in-progress. Mirrors the per-song
  /// download flow used elsewhere in the app, just looped across the album.
  Future<void> _downloadAlbum(
      BuildContext context, DownloadProvider downloads) async {
    final toQueue = _songs
        .where((s) => !downloads.isDownloaded(s.id) && !downloads.isDownloading(s.id))
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

  void _showAlbumOptions(BuildContext context) {
    final rootContext = context;
    showAurumModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (_) => _AlbumOptionsSheet(
        albumId: widget.albumId,
        albumName: widget.albumName,
        artworkUrl: _artworkUrl,
        songs: _songs,
        artists: _creditedArtists,
        rootContext: rootContext,
      ),
    );
  }
}

/// Premium album-level options sheet — mirrors SongTile's _SongOptionsSheet
/// styling (icon grid + "GO TO" artist chips) so the app feels consistent
/// whether you're opening options from a song row or from an album header.
class _AlbumOptionsSheet extends StatefulWidget {
  final String albumId;
  final String albumName;
  final String artworkUrl;
  final List<Song> songs;
  final List<String> artists;
  final BuildContext rootContext;

  const _AlbumOptionsSheet({
    required this.albumId,
    required this.albumName,
    required this.artworkUrl,
    required this.songs,
    required this.artists,
    required this.rootContext,
  });

  @override
  State<_AlbumOptionsSheet> createState() => _AlbumOptionsSheetState();
}

class _AlbumOptionsSheetState extends State<_AlbumOptionsSheet> {
  // Shared, deduped toast handler — see aurum_snack.dart.
  void _snack(String msg) {
    AurumSnack.show(widget.rootContext, msg);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final downloads = context.watch<DownloadProvider>();
    final followedAlbums = context.watch<FollowedAlbumsProvider>();
    final saved = followedAlbums.isFollowing(widget.albumId);
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

          // Album header
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
                        widget.albumName,
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
                            : 'Album',
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
                        ? AurumTheme.accentOf(context).withOpacity(0.12)
                        : AurumTheme.bgSurfaceOf(context),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AurumSaveButton(
                      saved: saved,
                      size: 20,
                      onTap: () => followedAlbums.toggleFollow(
                        albumId: widget.albumId,
                        name: widget.albumName,
                        artworkUrl: widget.artworkUrl,
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
                      albumId: widget.albumId,
                      name: widget.albumName,
                      artworkUrl: widget.artworkUrl,
                    );
                    _snack(saved ? 'Removed from Library' : 'Added to Library');
                  },
                ),
                _GridOption(
                  icon: Icons.download_outlined,
                  label: 'Download Album',
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

          // Artist chips — every distinct artist credited across the
          // album's songs, Spotify-style "GO TO" row. Each chip resolves
          // its own artistId by name when tapped (ArtistScreen handles
          // the not-found case with its own empty state), so an artist
          // that isn't in the catalog just shows a friendly message
          // instead of a broken navigation.
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

/// One "Other versions" / "More by [artist]" shelf — a section title
/// (whatever YT Music itself labeled it) followed by a horizontal-scroll
/// row of album cards. Mirrors artist_all_albums_screen.dart's grid tile
/// visually (same rounded artwork + title + year), just laid out as a
/// horizontal strip instead of a grid, matching the reference screenshot.
class _AlbumRelatedShelfSection extends StatelessWidget {
  final AlbumRelatedShelf shelf;
  const _AlbumRelatedShelfSection({required this.shelf});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              shelf.title,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shelf.albums.length,
              itemBuilder: (context, i) =>
                  _RelatedAlbumCard(album: shelf.albums[i]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single card inside a related-shelf row — tapping opens that album's
/// own AlbumScreen (real navigation, same as every other album card in
/// the app), never a preview/inline expansion.
class _RelatedAlbumCard extends StatelessWidget {
  final ArtistAlbum album;
  const _RelatedAlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: AurumPressable(
        onTap: () {
          AurumDepthRoute.to(
            context,
            AlbumScreen(
              albumId: album.id,
              albumName: album.name,
              artworkUrl: album.artworkUrl,
            ),
          );
        },
        child: SizedBox(
          width: 132,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AurumArtwork(url: album.artworkUrl, size: 132, borderRadius: 10),
              const SizedBox(height: 8),
              Text(
                album.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (album.year != null) ...[
                const SizedBox(height: 2),
                Text(
                  album.year!,
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small circular icon button used in the action row (download / overflow /
/// shuffle). Kept separate from AurumSaveButton since these are plain
/// stateless taps, not a persisted toggle with its own animation identity —
/// except shuffle, which gets a tinted "active" state.
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
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (AurumTheme.textPrimaryOf(context)).withOpacity(0.08),
        ),
        child: Icon(
          icon,
          size: 20,
          color: disabled
              ? AurumTheme.textMutedOf(context).withOpacity(0.4)
              : active
                  ? AurumTheme.accentOf(context)
                  : AurumTheme.textSecondaryOf(context),
        ),
      ),
    );
  }
}

/// Local copy of the icon-grid option tile used in the album options sheet.
/// (song_tile.dart's _GridOption is private to that file, so this screen
/// keeps its own equivalent rather than trying to reuse it.)
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
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AurumTheme.dividerOf(context), width: 0.8),
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

/// Local copy of the "GO TO" artist chip used in the album options sheet.
/// (song_tile.dart's _ArtistChip is private to that file.)
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
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AurumTheme.dividerOf(context)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: AurumTheme.accentOf(context)),
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
