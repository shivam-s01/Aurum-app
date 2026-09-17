// =============================================================================
// FILE: lib/screens/artist_screen.dart
// PROJECT: Astra Music
// DESCRIPTION: Artist page — profile header, Top Songs list, Albums/Singles grid.
// =============================================================================

import 'dart:ui';
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
import '../utils/aurum_immersive_header.dart';
import '../utils/artwork_palette_cache.dart';

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

class _ArtistScreenState extends State<ArtistScreen>
    with SingleTickerProviderStateMixin {
  Artist? _artist;
  bool _loading = true;
  bool _failed = false;
  // FIX ("2-3 sec mai aane wala artwork/glow akward lagta hai — sab jagah
  // instant, ekdam smooth chahiye"): matches mix_screen.dart's /
  // album_screen.dart's identical fix. _peekInitialGlow() below can't
  // seed this field's initializer directly the way those two screens
  // do, because the artist's image URL isn't known yet at construction
  // time here — it only arrives once _loadStreaming's fetch resolves —
  // so this still starts on the plain fallback. _extractGlow() then
  // checks the cache synchronously the MOMENT the image URL becomes
  // known (before ever awaiting the network extraction), so a warm
  // cache still paints instantly rather than waiting on a full
  // extraction round-trip. `_glow` is the animated getter every widget
  // below actually paints with — see _glowAnimation/_setGlowTarget.
  Color _glowTarget = const Color(0xFF1A1630);
  String? _glowExtractedFor;

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

  @override
  void initState() {
    super.initState();
    // Repaints on every animation tick while a glow fade is in flight —
    // see mix_screen.dart's matching listener for the full reasoning.
    _glowController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadStreaming();
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  Future<void> _extractGlow(String imageUrl) async {
    if (imageUrl.isEmpty || _glowExtractedFor == imageUrl) return;
    _glowExtractedFor = imageUrl;
    // Cache check FIRST, synchronously — if this artist's photo was
    // already seen elsewhere (a search result, another screen), this
    // resolves instantly instead of always waiting on the async
    // extraction below, even though the URL itself only became known
    // just now (see this field's own doc comment for why the
    // field-initializer seed mix_screen/album_screen use isn't possible
    // here).
    final cached = ArtworkPaletteCache.peek(imageUrl);
    if (cached != null && mounted) {
      final safeCached = ensureContrastSafe(
        cached.darkMuted,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      if (safeCached.value != _glowTarget.value) {
        setState(() => _setGlowTarget(safeCached));
      }
      return;
    }
    final c = await extractImmersiveColor(imageUrl);
    // Same contrast-safety clamp as mix_screen.dart's matching fix.
    if (c != null && mounted) {
      final safe = ensureContrastSafe(
        c,
        isLight: Theme.of(context).brightness == Brightness.light,
      );
      if (safe.value != _glowTarget.value) {
        setState(() => _setGlowTarget(safe));
      }
    }
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
      await ApiService.fetchArtistStreaming(id, songCount: 1000, onUpdate: (artist) {
        if (!mounted) return;
        gotAny = true;
        setState(() {
          _artist = artist;
          _loading = false;
        });
        if (artist.imageUrl.isNotEmpty) _extractGlow(artist.imageUrl);
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
      backgroundColor: immersiveScaffoldBg(context, _glow),
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

    return Container(
      color: immersiveScaffoldBg(context, _glow),
      child: CustomScrollView(
      physics: const BouncingScrollPhysics(),
      // PERF FIX (album row + 100-song list jank, "makkhan" scrolling):
      // same root cause as home_screen.dart's CustomScrollView — default
      // Sliver cacheExtent is only 250 logical px. With the artist header,
      // an album row, and now a full 100-song list all stacked in one
      // scroll view, a fast fling routinely outran that tiny buffer —
      // every sliver section briefly outside it got torn down and rebuilt
      // from scratch on re-entry, every single fling. Matches the same
      // 1200 used on Home for identical reasoning.
      cacheExtent: 1200,
      slivers: [
        SliverAppBar(
          expandedHeight: 380,
          // FIX ("artwork aur sab ek sath upar scroll ho, status bar
          // tak" — 2026-09-07): see matching comment in mix_screen.dart.
          pinned: false,
          backgroundColor: immersiveScaffoldBg(context, _glow),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          automaticallyImplyLeading: false,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Full-bleed artist photo, edge to edge — no framing card,
                // matching YT Music's artist banner treatment.
                AurumArtwork(url: artist.imageUrl, size: 700, borderRadius: 0),
                // Short scrim washing the artist photo's own extracted
                // color through it — matches mix_screen.dart's/
                // album_screen.dart's identical treatment so all three
                // detail screens share one consistent, alive header
                // instead of this one being the flat black outlier.
                DecoratedBox(decoration: immersiveHeaderScrim(_glow)),

                // REMOVED ("artwork ek sath upar scroll ho" fix,
                // 2026-09-07): see matching comment in mix_screen.dart —
                // pinned:false means no leftover collapsed strip for
                // this to frost anymore.

                // Name + subscriber/listener count, centered — YT Music
                // stacks these as one block under the channel name.
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 18,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artist.name,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 10),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (artist.followerCount > 0) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.asMonthlyListeners(
                              _formatFollowers(artist.followerCount)),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.85),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            shadows: const [
                              Shadow(color: Colors.black45, blurRadius: 6),
                            ],
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
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                // Floating glass back button — same lightweight per-pill
                // BackdropFilter treatment as the playlist header
                // (mix_screen.dart's _GlassPill), so both screens share
                // one consistent, cheap "glass over artwork" chrome
                // instead of a flat AppBar.
                // PERF/BATTERY FIX (zero-tolerance heating/battery
                // request): this screen is pushed via AurumDepthRoute
                // (opaque:false), same as Settings/mini-player/nav-bar —
                // meaning if something is pushed ON TOP of Artist (Full
                // Player, Settings, etc.), this route keeps compositing
                // underneath for the whole transition, and this pill's
                // BackdropFilter blur kept running every frame the whole
                // time even while fully hidden. Same fix as
                // mini_player.dart/main_shell.dart: only actually blur
                // while this route is the top of the Navigator stack.
                Builder(
                  builder: (context) {
                    final isTopRoute =
                        ModalRoute.of(context)?.isCurrent ?? true;
                    return SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(22),
                            child: _backButtonPillContent(context, isTopRoute),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        // Action row — radio/related (outline circle) · shuffle (solid
        // fill, center) · follow (outline circle), centered — matches
        // the reference screenshot's row exactly. Built from theme
        // colors rather than hardcoded white: this row sits in the
        // scrollable body below the artwork header (not over the photo
        // itself), so on light mode a hardcoded white fill/outline
        // would wash out against the pale background — using
        // textPrimaryOf/bgOf here reproduces the same look real YT
        // Music shows in dark mode while staying correctly visible in
        // light mode too.
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ArtistGlassButton(
                  icon: Icons.sensors_rounded,
                  onTap: artist.topSongs.isEmpty
                      ? null
                      : () {
                          AurumHaptics.light();
                          player.playSong(artist.topSongs.first,
                              queue: artist.topSongs,
                              index: 0,
                              curatedQueue: true);
                        },
                ),
                const SizedBox(width: 16),
                AurumPressable(
                  scaleAmount: 0.92,
                  onTap: artist.topSongs.isEmpty
                      ? null
                      : () {
                          AurumHaptics.heavy();
                          final shuffled =
                              List<Song>.from(artist.topSongs)..shuffle();
                          player.playSong(shuffled.first,
                              queue: shuffled, index: 0, curatedQueue: true);
                        },
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: artist.topSongs.isEmpty
                          ? AurumTheme.textPrimaryOf(context).withOpacity(0.3)
                          : AurumTheme.textPrimaryOf(context),
                    ),
                    child: Icon(Icons.shuffle_rounded,
                        color: AurumTheme.bgOf(context), size: 26),
                  ),
                ),
                const SizedBox(width: 16),
                _ArtistGlassButton(
                  icon: isFollowing
                      ? Icons.person_remove_rounded
                      : Icons.person_add_alt_1_rounded,
                  active: isFollowing,
                  // FIX (production-readiness pass): this used to end
                  // every follow/unfollow tap with a raw debug SnackBar —
                  // 'id="..." was=... now=... totalSaved=...' — a leftover
                  // internal-state dump from when there was no adb/logcat
                  // access to verify the save landed. Harmless in dev,
                  // but exactly the kind of thing that reads as broken/
                  // unfinished to a real user on a release build. Same
                  // fix in spirit as mix_screen.dart's/album_screen.dart's
                  // download-toast cleanup: replaced with the same
                  // AurumSnack.show(...) toast every other save/follow
                  // action in the app already uses (Library "Added"/
                  // "Removed", FollowedAlbums save/unsave) — themed,
                  // deduped, and tells the user what actually happened
                  // instead of what got written to a Hive box. Haptic
                  // also downgraded medium→selection to match every other
                  // like/save/follow toggle in the app (favorites,
                  // FollowedAlbumsProvider) — medium is reserved for
                  // heavier actions like shuffle-play here, not a binary
                  // toggle.
                  onTap: () async {
                    AurumHaptics.selection();
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
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
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


  // entirely (not just its output discarded) when this route isn't the
  // top of the Navigator stack — see the isTopRoute Builder above this
  // widget's call site. isTopRoute == false renders a flat translucent
  // circle with identical appearance to the blurred version's base tint,
  // so nothing visually changes; only the continuous per-frame GPU blur
  // sampling stops.
  Widget _backButtonPillContent(BuildContext context, bool isTopRoute) {
    final pill = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.22),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.arrow_back_rounded,
            color: Colors.white, size: 21),
        splashRadius: 20,
        onPressed: () {
          AurumHaptics.selection();
          Navigator.pop(context);
        },
      ),
    );
    if (!isTopRoute) return pill;
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: pill,
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
    return AurumPressable(
      scaleAmount: 0.9,
      onTap: disabled
          ? null
          : () {
              AurumHaptics.selection();
              onTap!();
            },
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.transparent,
          border: Border.all(
            width: 1.4,
            color: active
                ? AurumTheme.accentOf(context)
                : disabled
                    ? AurumTheme.dividerOf(context)
                    : AurumTheme.textPrimaryOf(context).withOpacity(0.7),
          ),
        ),
        child: Icon(
          icon,
          size: 22,
          color: disabled
              ? AurumTheme.textMutedOf(context).withOpacity(0.4)
              : active
                  ? AurumTheme.accentOf(context)
                  : AurumTheme.textPrimaryOf(context),
        ),
      ),
    );
  }
}
