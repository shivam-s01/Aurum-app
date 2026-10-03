// =============================================================================
// FILE: lib/screens/album_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Shows the song list inside an album / single — same
//   YT Music-style layout as the Mix screen: full-bleed sharp artwork that
//   fades into the palette-tinted page, centered title / artists / year,
//   floating glass pills (back, save, search, overflow), shuffle · Play ·
//   download row, track count, compact rows, then the related shelves.
// =============================================================================

import 'dart:async';
import 'dart:ui';
import '../utils/aurum_transitions.dart';
import 'library_screen.dart' show DownloadsScreen;
import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/aurum_song_options_sheet.dart' show showAurumPlaylistOptions;
import 'search_screen.dart';
import '../widgets/aurum_snack.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import 'artist_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
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

class _AlbumScreenState extends State<AlbumScreen>
    with SingleTickerProviderStateMixin {
  List<Song> _songs = [];
  bool _loading = true;
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
  //
  // FIX ("palette kuch sec baad snap/pop hoti hai — ekdam smooth chahiye"):
  // `_glow` is now an animated getter (see below), not a plain field —
  // any change to `_glowTarget` after this first frame plays as a fade
  // via _glowController instead of the old hard color snap.
  late Color _glowTarget = _peekInitialGlow();

  late final AnimationController _glowController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );
  late Animation<Color?> _glowAnimation = AlwaysStoppedAnimation(_glowTarget);

  /// The value every widget in build() actually paints with — see
  /// mix_screen.dart's identical getter for the full reasoning.
  Color get _glow => _glowAnimation.value ?? _glowTarget;

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

  Color _peekInitialGlow() {
    final cached = ArtworkPaletteCache.peek(widget.artworkUrl);
    // FIX ("albums wala bhi problem" — light theme cache-hit color was
    // off for a frame): `context` (needed for the real theme brightness)
    // isn't available yet at field-initializer time, so this used to
    // hardcode isLight: false — correct for dark theme, but wrong for a
    // light-theme user on a cache hit, where the clamp target is
    // different. This now returns the RAW cached tone unclamped instead
    // of guessing a brightness, and didChangeDependencies (below, which
    // does have `context`) applies the real, theme-correct clamp a
    // moment later — same fix mix_screen.dart's _peekInitialGlow already
    // uses, and that ~1-frame gap is invisible on a cache hit either way.
    return cached?.darkMuted ?? const Color(0xFF1A1630);
  }

  bool _contrastSafeApplied = false;

  @override
  void initState() {
    super.initState();
    // Repaints on every animation tick while a glow fade is in flight —
    // see mix_screen.dart's matching listener for the full reasoning.
    _glowController.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
    _extractGlow(widget.artworkUrl);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Applies the real, theme-aware contrast clamp to whatever
    // _peekInitialGlow seeded with the raw (unclamped) cached tone — see
    // that method's doc comment for why this couldn't happen at
    // construction time. Guarded to run once; didChangeDependencies can
    // re-fire on any dependency change (e.g. a theme toggle), not just
    // the first frame.
    if (!_contrastSafeApplied) {
      _contrastSafeApplied = true;
      final safe = ensureContrastSafe(
        _glowTarget,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      // Plain assign, not _setGlowTarget() — this runs before the very
      // first build, so there's no "current" painted color on screen yet
      // to fade FROM. Also re-seeds _glowAnimation itself (built in the
      // field initializer from the pre-clamp _glowTarget, so it could
      // otherwise briefly disagree with the now-clamped value) with an
      // already-settled animation at the correct color.
      _glowTarget = safe;
      _glowAnimation = AlwaysStoppedAnimation(safe);
    }
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _extractGlow(String url) async {
    final c = await extractImmersiveColor(url);
    // Same contrast-safety clamp as mix_screen.dart's matching fix.
    if (c != null && mounted) {
      final safe = ensureContrastSafe(
        c,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      // Cache-hit: _peekInitialGlow + didChangeDependencies above already
      // painted this exact color before the first frame ever showed —
      // this is a genuine no-op, skip the setState entirely instead of a
      // harmless-but-wasted rebuild. Only a real cold-cache resolution
      // actually moves the target, and _setGlowTarget fades `_glow`
      // smoothly to it rather than snapping.
      if (safe.value != _glowTarget.value) {
        setState(() => _setGlowTarget(safe));
      }
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
    final resolvedHeaderArt =
        result.headerArtworkUrl.isNotEmpty ? result.headerArtworkUrl : widget.artworkUrl;
    // FIX ("full player kabhi bina thumbnail ke na rahe"): a per-song
    // thumbnail can legitimately come back empty (many older Saavn album
    // tracks have no individual art, and the Saavn branch of
    // fetchAlbumSongsWithArtwork never stamps one the way the YT branch
    // does). The song list itself is fine showing a plain note icon for
    // those rows — but once tapped, the full player must never show blank
    // art, so every song missing its own artworkUrl here is stamped with
    // the album's cover (its real header art if resolved, else the
    // thumbnail this screen was opened with) as a guaranteed fallback.
    final stampedSongs = resolvedHeaderArt.isEmpty
        ? result.songs
        : result.songs
            .map((s) => s.artworkUrl.isEmpty
                ? s.copyWith(artworkUrl: resolvedHeaderArt)
                : s)
            .toList();
    setState(() {
      _songs = stampedSongs;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = immersiveScaffoldBg(context, _glow);
    final screenW = MediaQuery.of(context).size.width;
    final topInset = MediaQuery.of(context).padding.top;
    final headerH = screenW * 1.04;
    final titleColor = isDark ? Colors.white : AurumTheme.textPrimaryOf(context);
    final subColor = isDark
        ? Colors.white.withOpacity(0.72)
        : AurumTheme.textSecondaryOf(context);

    final scaffold = Scaffold(
      backgroundColor: bg,
      // Persistent mini player — see liked_screen.dart for the reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: Container(
        color: bg,
        child: CustomScrollView(
          cacheExtent: 1200,
          slivers: [
            // ── Header (scrolls away 1:1 with the list) ───────────────────
            SliverToBoxAdapter(
              child: SizedBox(
                height: headerH,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Layer 0 — sharp full-bleed artwork.
                    Positioned.fill(
                      child: Hero(
                        tag: 'album_art_${widget.albumId}',
                        child: _artworkUrl.isNotEmpty
                            ? AurumArtwork(
                                url: AurumArtwork.upgradeForFullPlayer(
                                    _artworkUrl),
                                size: double.infinity,
                                borderRadius: 0,
                              )
                            : Container(
                                color: _glow,
                                child: Center(
                                  child: Icon(
                                    Icons.album_rounded,
                                    size: 64,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                              ),
                      ),
                    ),

                    // Layer 1 — top scrim for status bar + floating pills.
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

                    // Layer 2 — bottom fade into the page background.
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

                    // Title block — album name, credited artists (tap opens
                    // the first artist), "Album • year".
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: 14,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.albumName,
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
                          if (artists.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => AurumDepthRoute.to(
                                context,
                                ArtistScreen(artistName: artists.first),
                              ),
                              child: Text(
                                artists.join(' • '),
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: subColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 2),
                          Text(
                            ['Album', if (year != null) year].join(' • '),
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

                    // Floating glass toolbar.
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
                                    followedAlbums.isFollowing(widget.albumId);
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
                                            albumId: widget.albumId,
                                            name: widget.albumName,
                                            artworkUrl: _artworkUrl,
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

            // ── Action row: shuffle · Play · download ─────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _RoundButton(
                      icon: Icons.shuffle_rounded,
                      onTap: _songs.isEmpty
                          ? null
                          : () {
                              final queue = List<Song>.from(_songs)..shuffle();
                              player.playSong(queue.first,
                                  queue: queue, index: 0, curatedQueue: true);
                            },
                    ),
                    const SizedBox(width: 12),
                    _PlayPill(
                      onTap: _songs.isEmpty
                          ? null
                          : () => player.playSong(_songs.first,
                              queue: _songs, index: 0, curatedQueue: true),
                    ),
                    const SizedBox(width: 12),
                    Consumer<DownloadProvider>(
                      builder: (context, downloads, _) {
                        final allDone = _songs.isNotEmpty &&
                            _songs.every((s) => downloads.isDownloaded(s.id));
                        return _RoundButton(
                          icon: allDone
                              ? Icons.download_done_rounded
                              : Icons.download_for_offline_outlined,
                          iconSize: 26,
                          onTap: _songs.isEmpty
                              ? null
                              : () => _downloadAlbum(context, downloads),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            if (!_loading && _songs.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
                  child: Text(
                    '${_songs.length} ${_songs.length == 1 ? 'track' : 'tracks'}',
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),

            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 56),
                  child: Center(
                    child: AurumMorphLoader(size: 56, contained: true),
                  ),
                ),
              )
            else if (_songs.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 56),
                  child: Center(
                    child: Text(l10n.albumNoSongsFound,
                        style:
                            TextStyle(color: AurumTheme.textMutedOf(context))),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => SongTile(
                    song: _songs[i],
                    queue: _songs,
                    index: i,
                    curatedQueue: true,
                    ytStyle: true,
                  ),
                  childCount: _songs.length,
                ),
              ),

            // "Other versions" / "More by [artist]" shelves — real InnerTube
            // shelves off this album's browse response; omitted when empty.
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

    // Dark mode: header artwork runs under the status bar → light icons.
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

  /// Queues every song in the album for download (skipping ones already
  /// downloaded/in-progress), then opens the real Downloads screen so the
  /// progress is visible.
  Future<void> _downloadAlbum(
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

/// Frosted-glass pill for the floating header toolbar (back button, and the
/// heart / search / overflow group). Light, mostly-white tint so the blurred
/// artwork colors read through; sigma kept modest (12) because BackdropFilter
/// is the one non-free thing here.
class _GlassPill extends StatelessWidget {
  final Widget child;
  const _GlassPill({super.key, required this.child});

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

/// Single tap target inside an [_GlassPill].
class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color iconColor;

  const _GlassIconButton({
    super.key,
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

/// Round control flanking the Play pill (shuffle, download).
class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double iconSize;

  const _RoundButton({
    super.key,
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

/// The wide Play pill between the round buttons.
class _PlayPill extends StatelessWidget {
  final VoidCallback? onTap;
  const _PlayPill({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final disabled = onTap == null;
    final fg = isDark ? Colors.black : Colors.white;
    return AurumPressable(
      scaleAmount: 0.95,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.medium();
              onTap!();
            },
      child: Container(
        height: 46,
        constraints: const BoxConstraints(minWidth: 112),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: (isDark ? Colors.white : const Color(0xFF111111))
              .withOpacity(disabled ? 0.4 : 1.0),
          borderRadius: BorderRadius.circular(23),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_arrow_rounded, color: fg, size: 24),
            const SizedBox(width: 6),
            Text(
              'Play',
              style: TextStyle(
                color: fg,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
