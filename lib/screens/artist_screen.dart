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
import '../utils/aurum_transitions.dart';
import 'album_screen.dart';
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

  @override
  void initState() {
    super.initState();
    _loadStreaming();
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
          ? const Center(child: AurumMorphLoader(size: 56))
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

    return CustomScrollView(
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
          pinned: true,
          backgroundColor: AurumTheme.bgOf(context),
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
                // LIGHT-MODE FIX: same reasoning as mix_screen.dart's
                // header gradient — an extra near-opaque black stop
                // right before the handoff to AurumTheme.bgOf(context)
                // keeps the whole photo dark under the white name/text
                // regardless of theme, instead of jumping straight into
                // light mode's warm off-white background.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.08),
                        Colors.black.withOpacity(0.30),
                        Colors.black.withOpacity(0.78),
                        Colors.black.withOpacity(0.92),
                        AurumTheme.bgOf(context),
                      ],
                      stops: const [0.0, 0.40, 0.72, 0.92, 1.0],
                    ),
                  ),
                ),

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
                              decoration: const BoxDecoration(
                                color: AurumTheme.gold,
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
                  onTap: () {
                    AurumHaptics.medium();
                    followed.toggleFollow(
                      artistId: artist.id,
                      name: artist.name,
                      imageUrl: artist.imageUrl,
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        if (artist.topSongs.isNotEmpty) ...[
          _sectionHeader(context, l10n.asPopular),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => SongTile(
                song: artist.topSongs[i],
                queue: artist.topSongs,
                index: i,
                showIndex: true,
                displayIndex: i + 1,
                curatedQueue: true,
              ),
              childCount: artist.topSongs.length,
            ),
          ),
        ],

        if (artist.topAlbums.isNotEmpty) ...[
          _sectionHeader(context, l10n.asAlbums),
          _albumGrid(context, artist.topAlbums),
        ],

        if (artist.singles.isNotEmpty) ...[
          _sectionHeader(context, l10n.asSingles),
          _albumGrid(context, artist.singles),
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
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          title,
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
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

  // PERF/BATTERY: extracted so the BackdropFilter can be skipped
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
                ? AurumTheme.gold
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
                  ? AurumTheme.gold
                  : AurumTheme.textPrimaryOf(context),
        ),
      ),
    );
  }
}
