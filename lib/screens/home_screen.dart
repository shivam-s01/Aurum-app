import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/library_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/song_tile.dart';
import 'package:shimmer/shimmer.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SongSection> _sections = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sections = await ApiService.fetchHome();
      if (mounted) {
        setState(() {
          _sections = sections;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load. Check your connection.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          _buildAppBar(context),
          if (_loading)
            SliverToBoxAdapter(child: _buildShimmer(context))
          else if (_error != null)
            SliverFillRemaining(child: _buildError())
          else ...[
            // Recently played row (from LibraryProvider)
            SliverToBoxAdapter(
                child: _RecentlyPlayedRow()),
            // Online sections
            ..._sections.asMap().entries.map(
                (e) => _buildSection(e.value, e.key)),
          ],
          const SliverToBoxAdapter(
              child: SizedBox(height: 120)),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good Morning'
        : hour < 17
            ? 'Good Afternoon'
            : 'Good Evening';

    return SliverAppBar(
      expandedHeight: 100,
      floating: true,
      snap: true,
      pinned: false,
      backgroundColor: AurumTheme.bgOf(context),
      scrolledUnderElevation: 0,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding:
            const EdgeInsets.fromLTRB(20, 0, 16, 14),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: TextStyle(
                    color: AurumTheme.textMutedOf(context),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    ShaderMask(
                      shaderCallback: (b) =>
                          AurumTheme.goldGradient
                              .createShader(b),
                      child: const Text(
                        'Aurum',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    Text(
                      ' Music',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w300,
                        color: AurumTheme.textSecondaryOf(
                            context),
                        letterSpacing: -0.5,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Spacer(),
            GestureDetector(
              onTap: _load,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AurumTheme.bgElevatedOf(context),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.refresh_rounded,
                  color: AurumTheme.textMutedOf(context),
                  size: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  SliverToBoxAdapter _buildSection(
      SongSection section, int index) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(20, 24, 16, 12),
            child: Row(
              children: [
                Text(
                  section.title,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  'See all',
                  style: TextStyle(
                    color: AurumTheme.gold.withValues(
                        alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (index == 0)
            _HorizontalCards(songs: section.songs)
          else
            _SongList(songs: section.songs),
        ],
      ),
    );
  }

  Widget _buildShimmer(BuildContext context) {
    final isDark =
        Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? AurumTheme.darkBgCard
          : AurumTheme.lightBgElevated,
      highlightColor: isDark
          ? AurumTheme.darkBgSurface
          : AurumTheme.lightBgSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Container(
              height: 18,
              width: 140,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          SizedBox(
            height: 185,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20),
              itemCount: 5,
              itemBuilder: (_, __) => Container(
                width: 140,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ...List.generate(
            6,
            (_) => Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 13,
                          color: Colors.white,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 11,
                          width: 100,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded,
              color:
                  AurumTheme.gold.withValues(alpha: 0.3),
              size: 52),
          const SizedBox(height: 16),
          Text(
            _error!,
            style: const TextStyle(
                color: AurumTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _load,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 28, vertical: 12),
              decoration: BoxDecoration(
                gradient: AurumTheme.goldGradient,
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Recently Played Row ───────────────────────────────────────────────────────

class _RecentlyPlayedRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final songs = lib.recentlyPlayed;
    if (songs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
          child: Text(
            '▶ Recently Played',
            style: TextStyle(
              color: AurumTheme.textPrimaryOf(context),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding:
                const EdgeInsets.symmetric(horizontal: 20),
            itemCount: songs.take(10).length,
            itemBuilder: (context, i) {
              final song = songs[i];
              final player = context.read<PlayerProvider>();
              return GestureDetector(
                onTap: () => player.playSong(song,
                    queue: songs, index: i),
                child: Container(
                  width: 220,
                  margin:
                      const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color:
                        AurumTheme.bgCardOf(context),
                    borderRadius:
                        BorderRadius.circular(14),
                    border: Border.all(
                      color:
                          AurumTheme.dividerOf(context),
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius:
                            const BorderRadius.horizontal(
                                left: Radius.circular(14)),
                        child: AurumArtwork(
                          url: song.artworkUrl,
                          size: 80,
                          borderRadius: 0,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Text(
                              song.title,
                              style: TextStyle(
                                color: AurumTheme
                                    .textPrimaryOf(
                                        context),
                                fontSize: 12,
                                fontWeight:
                                    FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              song.artist,
                              style: TextStyle(
                                color: AurumTheme
                                    .textMutedOf(context),
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Horizontal Cards ──────────────────────────────────────────────────────────

class _HorizontalCards extends StatelessWidget {
  final List<Song> songs;
  const _HorizontalCards({required this.songs});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    return SizedBox(
      height: 185,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding:
            const EdgeInsets.symmetric(horizontal: 20),
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final song = songs[i];
          final isPlaying =
              player.currentSong?.id == song.id &&
                  player.isPlaying;
          return GestureDetector(
            onTap: () => player.playSong(song,
                queue: songs, index: i),
            child: AnimatedContainer(
              duration:
                  const Duration(milliseconds: 200),
              width: 140,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: AurumTheme.bgCardOf(context),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isPlaying
                      ? AurumTheme.gold
                          .withValues(alpha: 0.5)
                      : AurumTheme.dividerOf(context),
                  width: 0.5,
                ),
                boxShadow: isPlaying
                    ? [
                        BoxShadow(
                          color: AurumTheme.gold
                              .withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        )
                      ]
                    : [],
              ),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius:
                            const BorderRadius.vertical(
                                top: Radius.circular(14)),
                        child: AurumArtwork(
                          url: song.artworkUrl,
                          size: 140,
                          borderRadius: 0,
                        ),
                      ),
                      if (isPlaying)
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            color: Colors.black
                                .withValues(alpha: 0.35),
                            borderRadius:
                                const BorderRadius
                                    .vertical(
                                    top: Radius.circular(
                                        14)),
                          ),
                          child: const Icon(
                            Icons.equalizer_rounded,
                            color: AurumTheme.gold,
                            size: 32,
                          ),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        8, 8, 8, 2),
                    child: Text(
                      song.title,
                      style: TextStyle(
                        color: isPlaying
                            ? AurumTheme.gold
                            : AurumTheme.textPrimaryOf(
                                context),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: 8),
                    child: Text(
                      song.artist,
                      style: TextStyle(
                        color: AurumTheme.textMutedOf(
                            context),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Song List ─────────────────────────────────────────────────────────────────

class _SongList extends StatelessWidget {
  final List<Song> songs;
  const _SongList({required this.songs});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: songs
          .take(8)
          .toList()
          .asMap()
          .entries
          .map((e) => SongTile(
                song: e.value,
                queue: songs,
                index: e.key,
                showIndex: true,
                displayIndex: e.key + 1,
              ))
          .toList(),
    );
  }
}
