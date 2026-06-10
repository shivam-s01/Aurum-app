import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/source_provider.dart';
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
      backgroundColor: AurumTheme.bgOf(context),
      floating: true,
      snap: true,
      elevation: 0,
      titleSpacing: 20,
      title: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: 'Aurum ',
              style: TextStyle(
                color: AurumTheme.gold,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            TextSpan(
              text: 'Music',
              style: TextStyle(
                color: AurumTheme.textSecondaryOf(context),
                fontSize: 26,
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
      ),
      actions: [
        const _SourceToggle(),
        IconButton(
          icon: Icon(Icons.settings_outlined, color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: AurumTheme.textSecondaryOf(context)),
          onPressed: _load,
        ),
      ],
    );
  }

  Widget _buildShimmer() {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (_) => Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 140, height: 18, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6))),
                const SizedBox(height: 12),
                SizedBox(
                  height: 160,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: 4,
                    itemBuilder: (_, __) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Container(width: 120, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AurumTheme.textMutedOf(context))),
          const SizedBox(height: 16),
          TextButton(onPressed: _load, child: Text('Retry', style: TextStyle(color: AurumTheme.gold))),
        ],
      ),
    );
  }

  SliverToBoxAdapter _buildSection(SongSection section) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 24, left: 16, right: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(section.title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            SizedBox(
              height: 190,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: section.songs.length,
                itemBuilder: (_, i) => _SongCard(song: section.songs[i], queue: section.songs, index: i),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Premium Online/Offline Toggle ──────────────────────────────────────────
class _SourceToggle extends StatelessWidget {
  const _SourceToggle();

  @override
  Widget build(BuildContext context) {
    final src = context.watch<SourceProvider>();
    final isOnline = src.isOnline;

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        src.toggle();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        width: 72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isOnline
              ? AurumTheme.gold.withOpacity(0.15)
              : AurumTheme.bgCardOf(context),
          border: Border.all(
            color: isOnline ? AurumTheme.gold : AurumTheme.dividerOf(context),
            width: 1.2,
          ),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              alignment: isOnline ? Alignment.centerLeft : Alignment.centerRight,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isOnline ? AurumTheme.gold : AurumTheme.bgElevatedOf(context),
                  boxShadow: isOnline ? [BoxShadow(color: AurumTheme.gold.withOpacity(0.4), blurRadius: 8)] : [],
                ),
                child: Icon(
                  isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                  size: 14,
                  color: isOnline ? Colors.black : AurumTheme.textMutedOf(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Song Card ──────────────────────────────────────────────────────────────
class _SongCard extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongCard({required this.song, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final isPlaying = player.currentSong?.id == song.id;
    return GestureDetector(
      onTap: () => player.playSong(song, queue: queue, index: index),
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(right: 12),
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
  }
}

class _SongList extends StatelessWidget {
  final List<Song> songs;
  const _SongList({required this.songs});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: songs.asMap().entries
          .map((e) => SongTile(song: e.value, queue: songs, index: e.key, displayIndex: e.key + 1))
          .toList(),
    );
  }
}
