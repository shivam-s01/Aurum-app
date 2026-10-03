// =============================================================================
// FILE: lib/screens/artist_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Artist page — profile header, Top Songs list, Albums/Singles grid.
// =============================================================================

import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/followed_artists_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_glass.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/song_tile.dart';
import '../widgets/mini_player_slot.dart';
import '../widgets/aurum_snack.dart';
import '../utils/aurum_transitions.dart';
import 'album_screen.dart';
import 'artist_all_songs_screen.dart';
import 'artist_all_albums_screen.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

class ArtistScreen extends StatefulWidget {
  /// Either a pre-resolved id — 'yt_<channelId>' or 'saavn_<id>' — or just
  /// an artistName to resolve (tries a real YouTube channel first, Saavn
  /// only as fallback — see ApiService.resolveArtistId).
  final String? artistId;
  final String artistName;

  const ArtistScreen({super.key, this.artistId, required this.artistName});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  Artist? _artist;
  bool _loading = true;
  bool _failed = false;

  // Single scroll controller drives BOTH the top bar fade-in and the
  // pull-down stretch. Each value lives in its own ValueNotifier so a
  // scroll tick rebuilds only the tiny widget that needs it (the top bar /
  // the photo transform) — never the whole page, and nothing at all once
  // the values are clamped (a notifier ignores repeated equal values).
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _barT = ValueNotifier<double>(0);
  final ValueNotifier<double> _stretch = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadStreaming();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _barT.dispose();
    _stretch.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final o = _scroll.offset;
    // Top bar starts appearing after ~40px and is fully in by ~130px.
    final t = ((o - 40) / 90).clamp(0.0, 1.0);
    if (_barT.value != t) _barT.value = t;
    final st = o < 0 ? -o : 0.0;
    if (_stretch.value != st) _stretch.value = st;
  }

  // NOTE: this screen used to call ApiService.fetchArtist() (a single
  // await for the entire 3-stage top-up chain) via a _load() method. See
  // _loadStreaming() below for the progressive replacement — fetchArtist
  // itself is untouched and still used elsewhere in the app.

  // PROGRESSIVE ARTIST LOAD (2026-08-31, "sirf 33 songs aa rahe hai, bahut
  // late" fix): fetchArtist() above waits for the ENTIRE 3-stage top-up
  // chain (browse shelf -> uploads walk, up to 25 sequential paginated
  // calls -> final-floor search) before the screen sees anything. On a
  // slow connection the walk's own 14s deadline cuts it short, so the
  // single result the screen got was already a thin partial count with no
  // sign more could still arrive. This calls the streaming variant
  // instead: browse's shelf paints in a couple seconds (same as before,
  // now just visible immediately instead of hidden behind the slower
  // stages), then the uploads and final-floor top-ups each grow the list
  // live as they land, exactly like the home feed's progressive reveal.
  Future<void> _loadStreaming() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      String? id = widget.artistId;
      id ??= await ApiService.resolveArtistId(widget.artistName);
      if (!mounted) return;
      // FIX ("Couldn't load Hwasa" — a Saavn backend is disabled
      // (`_saavnDisabled = true` in api_service.dart) dead end): a
      // non-empty `id` here isn't necessarily usable. Any id that
      // doesn't start with 'yt_' (a stale/bare 'saavn_'-prefixed id, or
      // any other non-YT id, e.g. from a Saavn-sourced artist card,
      // liked list, or follow made while Saavn was still live) walks
      // straight into fetchArtist's/_fetchArtistStreaming's
      // `_saavnDisabled` branch, which fails fast with null and no
      // fallback — every such artist error out with "Couldn't load
      // <name>" forever, even though we already have the artist's real
      // NAME right here and a perfectly good InnerTube-based resolver
      // (resolveArtistId, the same one used two lines up when `id` was
      // null) that doesn't touch Saavn at all. Re-resolve by name
      // whenever the id we ended up with isn't a 'yt_' id, exactly as if
      // no id had been passed in to begin with.
      if (id != null && !id.startsWith('yt_')) {
        id = await ApiService.resolveArtistId(widget.artistName);
        if (!mounted) return;
      }
      if (id == null || id.isEmpty) {
        setState(() {
          _loading = false;
          _failed = true;
        });
        return;
      }
      var gotAny = false;
      // FIX ("bahut jyda songs aaye" — no artificial cap): default 100
      // was a deliberate ceiling; ask for a much higher target so the
      // walk keeps collecting until the artist's real upload catalog
      // (or the walk's own maxPages/time budget) genuinely runs out,
      // not an arbitrary round number.
      await ApiService.fetchArtistStreaming(id, songCount: 200, onUpdate: (artist) {
        if (!mounted) return;
        gotAny = true;
        setState(() {
          _artist = artist;
          _loading = false;
        });
      });
      if (!mounted) return;
      if (!gotAny) setState(() { _loading = false; _failed = true; });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _artist == null;
      });
    }
  }

  String _formatFollowers(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER — see liked_screen.dart's
      // matching comment for the full reasoning.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: _loading
          ? const Center(child: AurumMorphLoader(size: 56, contained: true))
          : _failed
              ? _buildError(context)
              : _buildContent(context, _artist!),
    );
  }

  Widget _buildError(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 4,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () {
                AurumHaptics.selection();
                Navigator.pop(context);
              },
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_off_rounded,
                  size: 56, color: AurumTheme.textMutedOf(context)),
              const SizedBox(height: 12),
              Text(l10n.asCouldntLoad(widget.artistName),
                  style: TextStyle(color: AurumTheme.textSecondaryOf(context))),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  AurumHaptics.light();
                  _loadStreaming();
                },
                child: Text(l10n.asRetry),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, Artist artist) {
    final l10n = AppLocalizations.of(context)!;
    final player = context.read<PlayerProvider>();
    final followed = context.watch<FollowedArtistsProvider>();
    final isFollowing = followed.isFollowing(artist.id);
    final media = MediaQuery.of(context);
    final topPad = media.padding.top;
    final heroH = (media.size.width * 1.2).clamp(400.0, 560.0).toDouble();

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomScrollView(
          controller: _scroll,
          physics: const BouncingScrollPhysics(),
          // Keeps sections built a screen-and-a-bit ahead so a fast fling
          // never shows a half-built page.
          cacheExtent: 1200,
          slivers: [
            // ONE hero block that scrolls away together with the page — no
            // parallax, no pinned/collapsing app bar. The photo, name and
            // buttons all move at exactly the same speed as the sections
            // below, so nothing "slides ahead" of anything else.
            SliverToBoxAdapter(
              child: _buildHero(
                  context, artist, player, followed, isFollowing, heroH, topPad),
            ),

        // FEATURE: "Latest Release" hero card. Picked from data already in
        // memory (topAlbums + singles) — zero extra network calls, so the
        // page opens exactly as fast as before.
        if (_pickLatestRelease(artist) case final latest?)
          SliverToBoxAdapter(
            child: _ArtistLatestReleaseCard(
              album: latest,
              label: l10n.asLatestRelease,
              typeLabel: latest.type == 'single'
                  ? l10n.asTypeSingle
                  : l10n.asTypeAlbum,
            ),
          ),

        if (artist.topSongs.isNotEmpty) ...[
          // FEATURE ("main page pr bs 10 songs hi show kre aur trick
          // click pr new page khule wala sb songs ho" — top-level
          // parity): the section header itself carries the "open full
          // list" affordance now (a plain forward-arrow icon button —
          // same Echo-Nightly-matched treatment home_screen.dart already
          // uses for every shelf's "see all", so this reads as one
          // consistent app-wide pattern instead of a one-off). No inline
          // expand/collapse and no per-tile 1/2/3 index numbers — just a
          // clean 10-track preview here, with ArtistAllSongsScreen owning
          // the complete, un-numbered list. Nothing is re-fetched: both
          // the preview and the full page read from this same
          // artist.topSongs list ArtistScreen already has in memory.
          _sectionHeader(
            context,
            l10n.asPopular,
            onSeeAll: () {
              AurumHaptics.light();
              AurumDepthRoute.to(
                context,
                ArtistAllSongsScreen(
                  artistName: artist.name,
                  songs: artist.topSongs,
                ),
              );
            },
          ),
          _ArtistTopSongsSection(songs: artist.topSongs),
        ],

        if (artist.topAlbums.isNotEmpty) ...[
          _sectionHeader(
            context,
            l10n.asAlbums,
            onSeeAll: () {
              AurumHaptics.light();
              AurumDepthRoute.to(
                context,
                ArtistAllAlbumsScreen(
                  artistName: artist.name,
                  title: l10n.asAlbums,
                  albums: artist.topAlbums,
                ),
              );
            },
          ),
          _albumGrid(context, artist.topAlbums),
        ],

        if (artist.singles.isNotEmpty) ...[
          _sectionHeader(
            context,
            l10n.asSingles,
            onSeeAll: () {
              AurumHaptics.light();
              AurumDepthRoute.to(
                context,
                ArtistAllAlbumsScreen(
                  artistName: artist.name,
                  title: l10n.asSingles,
                  albums: artist.singles,
                ),
              );
            },
          ),
          _albumGrid(context, artist.singles),
        ],

        // FEATURE ("Fans might also like" row — YT Music parity, "ekdam
        // YouTube se data aaye ki awkward bhi na aaye"): artist.relatedArtists
        // is ONLY ever populated from YT Music browse's own "Fans might
        // also like" carousel (see _fetchArtistFromYtMusicBrowse's
        // pageType-gated extraction) — never derived, searched, or
        // guessed client-side. Empty for the Saavn-fallback path and any
        // artist YT Music itself doesn't show this shelf for, so this row
        // simply doesn't render rather than ever showing an invented or
        // loosely-matched suggestion.
        if (artist.relatedArtists.isNotEmpty) ...[
          _sectionHeader(context, l10n.asFansAlsoLike),
          _relatedArtistsRow(context, artist.relatedArtists),
        ],

        if (artist.bio.isNotEmpty) ...[
          _sectionHeader(context, l10n.asAbout),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              child: Text(
                artist.bio,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
        // Top bar: invisible at the top, fades in (solid, no blur) with the
        // artist's name after a small scroll.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildTopBar(context, artist, topPad),
        ),
      ],
    );
  }

  Widget _buildHero(
    BuildContext context,
    Artist artist,
    PlayerProvider player,
    FollowedArtistsProvider followed,
    bool isFollowing,
    double heroH,
    double topPad,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final bg = AurumTheme.bgOf(context);
    final hasSongs = artist.topSongs.isNotEmpty;
    final primary = AurumTheme.textPrimaryOf(context);

    return RepaintBoundary(
      child: SizedBox(
      height: heroH,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Photo. Pulling past the top stretches it (anchored at the
          // bottom) so there's never an empty gap above it.
          ValueListenableBuilder<double>(
            valueListenable: _stretch,
            builder: (context, st, child) => Transform.scale(
              scale: 1 + (st / heroH) * 0.9,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
            child:
                AurumArtwork(url: artist.imageUrl, size: 700, borderRadius: 0),
          ),
          // Soft dark strip so the back arrow stays readable on bright photos.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topPad + 90,
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
          // Long, smooth fade into the page background (no tint, no blur).
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    bg.withOpacity(0.0),
                    bg.withOpacity(0.0),
                    bg.withOpacity(0.88),
                    bg,
                  ],
                  stops: const [0.0, 0.42, 0.80, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  artist.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primary,
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
                if (artist.followerCount > 0) ...[
                  const SizedBox(height: 10),
                  Text(
                    l10n.asMonthlyListeners(
                        _formatFollowers(artist.followerCount)),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
                if (artist.isVerified) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: AurumTheme.accentOf(context),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_rounded,
                            size: 11, color: Colors.black),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.asVerifiedArtist,
                        style: TextStyle(
                          color: AurumTheme.textSecondaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ArtistGlassButton(
                      icon: Icons.shuffle_rounded,
                      onTap: !hasSongs
                          ? null
                          : () {
                              final shuffled = List<Song>.from(artist.topSongs)
                                ..shuffle();
                              player.playSong(shuffled.first,
                                  queue: shuffled,
                                  index: 0,
                                  curatedQueue: true);
                            },
                    ),
                    const SizedBox(width: 12),
                    AurumPressable(
                      scaleAmount: 0.94,
                      onTap: !hasSongs
                          ? null
                          : () {
                              AurumHaptics.medium();
                              player.playSong(artist.topSongs.first,
                                  queue: artist.topSongs,
                                  index: 0,
                                  curatedQueue: true);
                            },
                      child: Container(
                        height: 52,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(26),
                          color: hasSongs ? primary : primary.withOpacity(0.3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.play_arrow_rounded, color: bg, size: 26),
                            const SizedBox(width: 6),
                            Text(
                              l10n.commonPlay,
                              style: TextStyle(
                                color: bg,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    _ArtistGlassButton(
                      icon: isFollowing
                          ? Icons.check_rounded
                          : Icons.person_add_alt_1_rounded,
                      active: isFollowing,
                      onTap: () async {
                        final wasFollowing = followed.isFollowing(artist.id);
                        await followed.toggleFollow(
                          artistId: artist.id,
                          name: artist.name,
                          imageUrl: artist.imageUrl,
                        );
                        if (!context.mounted) return;
                        AurumSnack.show(
                          context,
                          wasFollowing
                              ? 'Unfollowed ${artist.name}'
                              : 'Following ${artist.name}',
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, Artist artist, double topPad) {
    final bg = AurumTheme.bgOf(context);
    final primary = AurumTheme.textPrimaryOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: _barT,
      builder: (context, t, _) {
        final iconColor = Color.lerp(Colors.white, primary, t)!;
        return SizedBox(
          height: topPad + 56,
          child: Stack(
            children: [
              // IgnorePointer: the (invisible) bar must never swallow drags
              // that start near the top of the screen.
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: t,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: bg,
                        border: Border(
                          bottom: BorderSide(
                              color: AurumTheme.dividerOf(context), width: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.only(top: topPad),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: t < 0.6
                          ? AurumGlass(
                              sigma: 6,
                              borderRadius: BorderRadius.circular(20),
                              isDark: true,
                              interactive: false,
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  splashRadius: 20,
                                  icon: Icon(Icons.arrow_back_rounded,
                                      color: iconColor, size: 22),
                                  onPressed: () {
                                    AurumHaptics.selection();
                                    Navigator.pop(context);
                                  },
                                ),
                              ),
                            )
                          : IconButton(
                              padding: EdgeInsets.zero,
                              splashRadius: 20,
                              icon: Icon(Icons.arrow_back_rounded,
                                  color: iconColor, size: 22),
                              onPressed: () {
                                AurumHaptics.selection();
                                Navigator.pop(context);
                              },
                            ),
                    ),
                    Expanded(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: t,
                          child: Transform.translate(
                            offset: Offset(0, (1 - t) * 6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                artist.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: primary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 52),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(BuildContext context, String title,
      {VoidCallback? onSeeAll}) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // ECHO-NIGHTLY MATCH ("trick jaisa mark" — a plain icon, no
            // text): identical treatment to home_screen.dart's shelf
            // "see all" — a bare circular icon button with a
            // forward-arrow glyph, no fill, no outline, no extra text
            // label. Only rendered when the caller actually has a full
            // list to open.
            if (onSeeAll != null)
              Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onSeeAll,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 20,
                      color: AurumTheme.textPrimaryOf(context),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _albumGrid(BuildContext context, List<ArtistAlbum> albums) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 190,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          // PERF (low-end device smoothness): this row decodes album
          // artwork over the network — without a cacheExtent, a fast
          // swipe only builds/decodes images as they cross into the
          // viewport, showing a blank frame for a beat on a slow device
          // before the image pops in. Pre-building ~500 logical px of
          // off-screen album covers on each side means they're already
          // decoded by the time they scroll into view, matching the
          // cacheExtent used on every other horizontal artwork list in
          // the app (song carousels, the artist strip on Home).
          cacheExtent: 500,
          itemCount: albums.length,
          itemBuilder: (context, i) {
            final a = albums[i];
            // PERF: isolate each album card into its own compositor
            // layer — same reasoning as _SongGridCard on Home. Without
            // this, every card in the row repaints/relayouts alongside
            // its siblings on every scroll frame instead of being
            // cached as its own independent layer.
            return RepaintBoundary(
              child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GestureDetector(
                onTap: () {
                  AurumHaptics.light();
                  AurumDepthRoute.to(
                    context,
                    AlbumScreen(
                      albumId: a.id,
                      albumName: a.name,
                      artworkUrl: a.artworkUrl,
                    ),
                  );
                },
                child: SizedBox(
                  width: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AurumArtwork(url: a.artworkUrl, size: 130, borderRadius: 10),
                      const SizedBox(height: 8),
                      Text(
                        a.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (a.year != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          a.year!,
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
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _relatedArtistsRow(BuildContext context, List<RelatedArtist> artists) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 168,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          // Same off-screen decode headroom as _albumGrid's cacheExtent —
          // identical reasoning (smooth swipe on a low-end device).
          cacheExtent: 500,
          itemCount: artists.length,
          itemBuilder: (context, i) {
            final a = artists[i];
            return RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () {
                    AurumHaptics.light();
                    // 'yt_' prefix matches Artist.id's own convention
                    // (see _fetchArtistFromYtMusicBrowse's `'yt_$resolvedChannelId'`)
                    // — RelatedArtist.id is the raw browse channelId, so
                    // it needs the same prefix ArtistScreen/fetchArtist
                    // expect everywhere else in the app.
                    AurumDepthRoute.to(
                      context,
                      ArtistScreen(artistId: 'yt_${a.id}', artistName: a.name),
                    );
                  },
                  child: SizedBox(
                    width: 120,
                    child: Column(
                      children: [
                        ClipOval(
                          child: AurumArtwork(url: a.imageUrl, size: 120, borderRadius: 60),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          a.name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AurumTheme.textPrimaryOf(context),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// FEATURE ("Top Songs ko Show all ke saath collapse karo" — YT Music
/// parity): shows only the first 5 songs by default (YT Music's own
/// "Popular" preview length), with a "Show all" row that expands to the
/// full `songs` list in place. Purely a local UI toggle — `songs` is the
/// same complete list ArtistScreen already fetched via fetchArtist(), so
/// expanding never re-fetches or truncates data, it only changes how much
/// of the already-fetched list is rendered.
// FEATURE ("main page pr bs 10 songs hi show kre" / "1 2 3 number hata
// do" — top-level parity): plain stateless preview now — no per-tile
// index numbering (no showIndex/displayIndex), no inline expand/collapse
// state to own. Just the first 10 tracks; the section header's arrow
// icon (see _sectionHeader's onSeeAll) is what opens the complete,
// still-un-numbered list on ArtistAllSongsScreen.
class _ArtistTopSongsSection extends StatelessWidget {
  static const int _previewCount = 10;
  final List<Song> songs;
  const _ArtistTopSongsSection({required this.songs});

  @override
  Widget build(BuildContext context) {
    final visibleCount =
        songs.length > _previewCount ? _previewCount : songs.length;

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => SongTile(
          song: songs[i],
          queue: songs,
          index: i,
          curatedQueue: true,
        ),
        childCount: visibleCount,
      ),
    );
  }
}

/// Circular outline action button flanking the artist header's central
/// shuffle button (radio/related on the left, follow on the right) —
/// matches the reference screenshot's row exactly: transparent fill,
/// visible border, same 56px size as the center shuffle button. Local +
/// stateless: no per-instance AnimationController beyond what
/// AurumPressable already provides, keeping this cheap to build.
class _ArtistGlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool active;

  const _ArtistGlassButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final primary = AurumTheme.textPrimaryOf(context);
    return AurumPressable(
      scaleAmount: 0.9,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: SizedBox(
        width: 48,
        height: 48,
        child: AurumGlass(
          sigma: 6,
          borderRadius: BorderRadius.circular(24),
          isDark: Theme.of(context).brightness == Brightness.dark,
          interactive: false,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              icon,
              size: 22,
              color: disabled
                  ? AurumTheme.textMutedOf(context).withOpacity(0.4)
                  : active
                      ? AurumTheme.accentOf(context)
                      : primary,
            ),
          ),
        ),
      ),
    );
  }
}


/// Newest release across albums + singles. The data only carries a release
/// YEAR, so: highest year wins; on a tie, the first entry of its own shelf
/// (YT Music lists shelves newest-first) is used, singles before albums.
ArtistAlbum? _pickLatestRelease(Artist artist) {
  ArtistAlbum? best;
  int bestYear = -1;
  void scan(List<ArtistAlbum> list) {
    for (final a in list) {
      final y = int.tryParse(a.year ?? '') ?? -1;
      if (y > bestYear) {
        best = a;
        bestYear = y;
      }
    }
  }

  scan(artist.singles);
  scan(artist.topAlbums);
  return bestYear < 0 ? null : best;
}

/// "Latest release" card: flat surface card, cover on the left, small
/// letter-spaced label + title + "Album \u2022 2026" on the right. No blur,
/// no gradient — cheap to paint, and it matches the page's calm look.
class _ArtistLatestReleaseCard extends StatelessWidget {
  final ArtistAlbum album;
  final String label;
  final String typeLabel;
  const _ArtistLatestReleaseCard({
    required this.album,
    required this.label,
    required this.typeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final meta =
        album.year == null ? typeLabel : '$typeLabel \u2022 ${album.year}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: RepaintBoundary(
        child: AurumPressable(
          scaleAmount: 0.98,
          onTap: () {
            AurumHaptics.light();
            AurumDepthRoute.to(
              context,
              AlbumScreen(
                albumId: album.id,
                albumName: album.name,
                artworkUrl: album.artworkUrl,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AurumTheme.bgCardOf(context),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                AurumArtwork(
                  url: album.artworkUrl,
                  size: 96,
                  borderRadius: 12,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        album.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textPrimaryOf(context),
                          fontSize: 17,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AurumTheme.textMutedOf(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
