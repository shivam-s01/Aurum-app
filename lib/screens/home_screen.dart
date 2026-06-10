import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/api_service.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_loader.dart';
import 'package:shimmer/shimmer.dart';
import 'settings_screen.dart';

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
    setState(() { _loading = true; _error = null; });
    try {
      final sections = await ApiService.fetchHome();
      if (mounted) setState(() { _sections = sections; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Failed to load. Check your connection.'; _loading = false; });
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
            SliverToBoxAdapter(child: _buildShimmer())
          else if (_error != null)
            SliverFillRemaining(child: _buildError())
          else
            ..._sections.map(_buildSection),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 100,
      floating: true,
      snap: true,
      pinned: false,
      backgroundColor: AurumTheme.bgOf(context),
      automaticallyImplyLeading: false,
      actions: [
        IconButton(
          icon: Icon(Icons.settings_outlined, color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: AurumTheme.textSecondaryOf(context)),
          onPressed: _load,
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Row(
          children: [
            ShaderMask(
              shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
              child: const Text('Aurum', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.5)),
            ),
            const Text(' Music', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w300, color: AurumTheme.textSecondary, letterSpacing: -0.5)),
          ],
        ),
      ),
    );
  }

  SliverToBoxAdapter _buildSection(SongSection section) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Text(section.title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          if (_sections.indexOf(section) == 0)
            _HorizontalCards(songs: section.songs)
          else
            _SongList(songs: section.songs),
        ],
      ),
    );
  }

  Widget _buildShimmer() {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgSurfaceOf(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(height: 20, width: 160, color: AurumTheme.darkBgCard),
          ),
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: 5,
              itemBuilder: (_, __) => Container(
                width: 140,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(color: AurumTheme.darkBgCard, borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 20),
          ...List.generate(6, (_) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Container(width: 50, height: 50, color: AurumTheme.darkBgCard),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(height: 14, color: AurumTheme.darkBgCard),
                const SizedBox(height: 6),
                Container(height: 12, width: 100, color: AurumTheme.darkBgCard),
              ])),
            ]),
          )),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, color: AurumTheme.gold.withOpacity(0.4), size: 48),
          const SizedBox(height: 16),
          Text(_error!, style: TextStyle(color: AurumTheme.textSecondaryOf(context))),
          const SizedBox(height: 16),
          TextButton(onPressed: _load, child: const Text('Retry', style: TextStyle(color: AurumTheme.gold))),
        ],
      ),
    );
  }
}

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
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final song = songs[i];
          final isPlaying = player.currentSong?.id == song.id && player.isPlaying;
          return GestureDetector(
            onTap: () => player.playSong(song, queue: songs, index: i),
            child: Container(
              width: 140,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: AurumTheme.bgCardOf(context),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isPlaying ? AurumTheme.gold.withOpacity(0.5) : AurumTheme.dividerOf(context), width: 0.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      AurumArtwork(url: song.artworkUrl, size: 140, borderRadius: 0),
                      if (isPlaying)
                        Container(
                          width: 140, height: 140,
                          decoration: BoxDecoration(color: Colors.black.withOpacity(0.4), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
                          child: const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 32),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: Text(song.title, style: TextStyle(color: isPlaying ? AurumTheme.gold : AurumTheme.textPrimaryOf(context), fontSize: 12, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(song.artist, style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
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

class _SongList extends StatelessWidget {
  final List<Song> songs;
  const _SongList({required this.songs});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: songs.take(8).toList().asMap().entries
          .map((e) => SongTile(song: e.value, queue: songs, index: e.key, showIndex: true, displayIndex: e.key + 1))
          .toList(),
    );
  }
}
