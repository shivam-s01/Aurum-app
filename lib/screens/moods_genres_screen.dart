// =============================================================================
// FILE: lib/screens/moods_genres_screen.dart
// PROJECT: Aurum Music
// DESCRIPTION: Real "Moods & Genres" experience — ekdam YouTube Music jaisa.
//   Two screens:
//     - MoodsGenresScreen: the full colorful category grid, straight from
//       InnerTube's own FEmusic_moods_and_genres browse (real titles, real
//       tile colors, real browseIds — see ApiService.fetchMoodsAndGenres).
//     - MoodGenreDetailScreen: opened on tile tap, shows that category's
//       real curated playlist/album shelves (ApiService.fetchMoodGenreCategory)
//       and reuses the exact same playlist->MixScreen / album->AlbumScreen
//       tap handling home_screen.dart's real shelves already use, so tapping
//       a card here opens a genuinely real, fully-populated playlist.
// =============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_transitions.dart';
import '../widgets/faded_horizontal_list.dart';
import 'album_screen.dart';
import 'mix_screen.dart';

// Neutral fallback tile colors, cycled only when InnerTube genuinely sends
// no `solid` color for a tile (see MoodGenreCategory.color's doc comment) —
// never overrides a real InnerTube color when one is present.
const List<Color> _kFallbackTileColors = [
  Color(0xFF4A3B6B),
  Color(0xFF6B3B4A),
  Color(0xFF3B5A6B),
  Color(0xFF5A6B3B),
  Color(0xFF6B5A3B),
  Color(0xFF3B6B5A),
];

class MoodsGenresScreen extends StatefulWidget {
  const MoodsGenresScreen({super.key});

  @override
  State<MoodsGenresScreen> createState() => _MoodsGenresScreenState();
}

class _MoodsGenresScreenState extends State<MoodsGenresScreen> {
  List<MoodGenreSection>? _sections;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Cache-first: show a previous successful fetch instantly (no
    // spinner) so the grid never feels like it's waiting on network,
    // matching how the rest of this app's real shelves already behave.
    final cached = await MoodGenreCacheStore.load();
    if (cached != null && cached.isNotEmpty && mounted) {
      setState(() {
        _sections = cached;
        _failed = false;
      });
    }

    // Only hit the network again if there's nothing cached yet, or the
    // cache has aged past its fresh window — an already-fresh cache
    // means the grid the user is looking at right now IS the current
    // data, so skip the redundant fetch entirely.
    final fresh = await MoodGenreCacheStore.isFresh();
    if (cached != null && cached.isNotEmpty && fresh) return;

    final sections = await ApiService.fetchMoodsAndGenres();
    if (!mounted) return;
    if (sections.isEmpty) {
      // A failed/empty refresh shouldn't wipe an already-showing cached
      // grid — only surface the "couldn't load" state if there was
      // nothing cached to fall back on in the first place.
      if (cached == null || cached.isEmpty) {
        setState(() => _failed = true);
      }
      return;
    }
    setState(() {
      _sections = sections;
      _failed = false;
    });
    unawaited(MoodGenreCacheStore.save(sections));
  }

  void _openCategory(MoodGenreCategory tile, Color tileColor) {
    AurumHaptics.selection();
    AurumDepthRoute.to(
      context,
      MoodGenreDetailScreen(category: tile, tileColor: tileColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: AurumTheme.bgOf(context),
        elevation: 0,
        title: Text(
          'Moods & Genres',
          style: TextStyle(
            color: AurumTheme.textPrimaryOf(context),
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final sections = _sections;

    if (sections == null && !_failed) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sections == null || sections.isEmpty) {
      return Center(
        child: Text(
          "Couldn't load moods & genres right now",
          style: TextStyle(color: AurumTheme.textSecondaryOf(context)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: sections.length,
      itemBuilder: (context, sIndex) {
        final section = sections[sIndex];
        return Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                section.title,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: section.items.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.1,
                ),
                itemBuilder: (context, i) {
                  final tile = section.items[i];
                  final color = tile.color != null
                      ? Color(tile.color!).withAlpha(255)
                      : _kFallbackTileColors[
                          (sIndex * 7 + i) % _kFallbackTileColors.length];
                  return _MoodGenreTileCard(
                    title: tile.title,
                    color: color,
                    artworkUrl: tile.artworkUrl,
                    onTap: () => _openCategory(tile, color),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MoodGenreTileCard extends StatelessWidget {
  final String title;
  final Color color;
  final String? artworkUrl;
  final VoidCallback onTap;

  const _MoodGenreTileCard({
    required this.title,
    required this.color,
    required this.onTap,
    this.artworkUrl,
  });

  @override
  Widget build(BuildContext context) {
    final art = artworkUrl;
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              if (art != null && art.isNotEmpty) ...[
                const SizedBox(width: 10),
                Transform.rotate(
                  angle: 0.25,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedNetworkImage(
                      imageUrl: art,
                      width: 46,
                      height: 46,
                      fit: BoxFit.cover,
                      memCacheWidth: 92,
                      memCacheHeight: 92,
                      fadeInDuration: const Duration(milliseconds: 150),
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
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

// ─────────────────────────────────────────────────────────────────────────
// Category detail — real curated playlist/album shelves for one tapped
// mood/genre tile.
// ─────────────────────────────────────────────────────────────────────────

class MoodGenreDetailScreen extends StatefulWidget {
  final MoodGenreCategory category;
  final Color tileColor;

  const MoodGenreDetailScreen({
    super.key,
    required this.category,
    required this.tileColor,
  });

  @override
  State<MoodGenreDetailScreen> createState() => _MoodGenreDetailScreenState();
}

class _MoodGenreDetailScreenState extends State<MoodGenreDetailScreen> {
  List<HomeShelf>? _shelves;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final shelves = await ApiService.fetchMoodGenreCategory(
      widget.category.browseId,
      widget.category.params,
    );
    if (!mounted) return;
    setState(() {
      _shelves = shelves;
      _failed = shelves.isEmpty;
    });
  }

  Future<void> _openItem(HomeShelfItem item) async {
    AurumHaptics.selection();
    if (item.isAlbum) {
      AurumDepthRoute.to(
        context,
        AlbumScreen(
          albumId: item.browseId,
          albumName: item.title,
          artworkUrl: item.artworkUrl,
        ),
      );
      return;
    }
    AurumDepthRoute.to(
      context,
      MixScreen(
        mixId: item.browseId,
        mixName: item.title,
        artworkUrl: item.artworkUrl,
        emoji: '',
        songs: const [],
        autoLoadMore: () async {
          final firstPage = await ApiService.resolveHomeShelfPlaylist(item);
          if (firstPage.isEmpty) return firstPage;
          final more = await ApiService.fetchHomeShelfPlaylistMore(
            item,
            existingVideoIds: firstPage.map((s) => s.id).toList(),
          );
          return [...firstPage, ...more];
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      appBar: AppBar(
        backgroundColor: widget.tileColor,
        elevation: 0,
        title: Text(
          widget.category.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final shelves = _shelves;

    if (shelves == null && !_failed) {
      return const Center(child: CircularProgressIndicator());
    }

    if (shelves == null || shelves.isEmpty) {
      return Center(
        child: Text(
          "Couldn't load ${widget.category.title} right now",
          style: TextStyle(color: AurumTheme.textSecondaryOf(context)),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      itemCount: shelves.length,
      itemBuilder: (context, i) => _CategoryShelfRow(
        shelf: shelves[i],
        onTapItem: _openItem,
      ),
    );
  }
}

class _CategoryShelfRow extends StatelessWidget {
  final HomeShelf shelf;
  final void Function(HomeShelfItem) onTapItem;

  const _CategoryShelfRow({required this.shelf, required this.onTapItem});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            shelf.title,
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          FadedHorizontalList(
            height: 170,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: shelf.items.length,
              itemBuilder: (context, i) {
                final item = shelf.items[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _CategoryItemCard(
                    item: item,
                    onTap: () => onTapItem(item),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryItemCard extends StatelessWidget {
  final HomeShelfItem item;
  final VoidCallback onTap;

  const _CategoryItemCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: item.artworkUrl,
                width: 130,
                height: 130,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  width: 130,
                  height: 130,
                  color: AurumTheme.bgCardOf(context),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: 130,
                  height: 130,
                  color: AurumTheme.bgCardOf(context),
                  child: const Icon(Icons.music_note, color: Colors.white24),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (item.subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AurumTheme.textSecondaryOf(context),
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
