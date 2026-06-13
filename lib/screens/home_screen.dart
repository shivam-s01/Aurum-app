import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/source_provider.dart';
import '../providers/library_provider.dart';
import '../providers/recently_played_provider.dart';
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
  List<SongSection> _onlineSections = [];
  bool _onlineLoading = true;
  String? _onlineError;

  @override
  void initState() {
    super.initState();
    _loadOnline();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final lib = context.read<LibraryProvider>();
      if (!lib.hasLoaded) lib.load();
    });
  }

  Future<void> _loadOnline() async {
    setState(() { _onlineLoading = true; _onlineError = null; });
    try {
      final topArtists = context.read<RecentlyPlayedProvider>().topArtists();
      final sections = await ApiService.fetchHome(topArtists: topArtists);
      if (mounted) setState(() { _onlineSections = sections; _onlineLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _onlineError = 'Failed to load. Check connection.'; _onlineLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final src = context.watch<SourceProvider>();
    final isOnline = src.isOnline;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          _buildAppBar(context, src),
          SliverToBoxAdapter(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: isOnline ? const Offset(-0.08, 0) : const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              child: isOnline
                  ? _OnlineContent(
                      key: const ValueKey('online'),
                      sections: _onlineSections,
                      loading: _onlineLoading,
                      error: _onlineError,
                      onRetry: _loadOnline,
                    )
                  : const _OfflineContent(key: ValueKey('offline')),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, SourceProvider src) {
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
              style: TextStyle(color: AurumTheme.gold, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5),
            ),
            TextSpan(
              text: 'Music',
              style: TextStyle(color: AurumTheme.textSecondaryOf(context), fontSize: 26, fontWeight: FontWeight.w300),
            ),
          ],
        ),
      ),
      actions: [
        _SourceToggle(onToggle: () { HapticFeedback.mediumImpact(); src.toggle(); }),
        IconButton(
          icon: Icon(Icons.settings_outlined, color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: AurumTheme.textSecondaryOf(context)),
          onPressed: src.isOnline ? _loadOnline : () => context.read<LibraryProvider>().refresh(),
        ),
      ],
    );
  }
}

class _OnlineContent extends StatelessWidget {
  final List<SongSection> sections;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  const _OnlineContent({super.key, required this.sections, required this.loading, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (loading) return _buildShimmer(context);
    if (error != null && sections.isEmpty) return _buildError(context);
    return Column(children: sections.map((s) => _buildSection(context, s)).toList());
  }

  Widget _buildShimmer(BuildContext context) {
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

  Widget _buildError(BuildContext context) {
    return SizedBox(height: 300, child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.wifi_off_rounded, size: 48, color: AurumTheme.textMutedOf(context)),
      const SizedBox(height: 12),
      Text(error!, style: TextStyle(color: AurumTheme.textMutedOf(context))),
      const SizedBox(height: 16),
      TextButton(onPressed: onRetry, child: Text('Retry', style: TextStyle(color: AurumTheme.gold))),
    ])));
  }

  Widget _buildSection(BuildContext context, SongSection section) {
    return Padding(
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
    );
  }
}

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();

    if (lib.status == LibraryStatus.idle || lib.status == LibraryStatus.loading) {
      return const Padding(padding: EdgeInsets.only(top: 80), child: Center(child: AurumLoader()));
    }
    if (lib.status == LibraryStatus.noPermission) {
      return _msg(context, Icons.folder_off_rounded, 'Storage permission needed', 'Grant Permission', () => lib.load());
    }
    if (lib.allSongs.isEmpty) {
      return _msg(context, Icons.music_off_rounded, 'No local songs found', 'Scan Again', () => lib.refresh());
    }

    final sections = lib.sections.isNotEmpty
        ? lib.sections
        : [SongSection(title: '🎵 Local Songs', songs: lib.allSongs)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Row(children: [
            Icon(Icons.download_done_rounded, color: AurumTheme.gold, size: 18),
            const SizedBox(width: 8),
            Text('${lib.allSongs.length} songs on device', style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
          ]),
        ),
        ...sections.map((s) => Padding(
          padding: const EdgeInsets.only(top: 20, left: 16, right: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.title, style: TextStyle(color: AurumTheme.textPrimaryOf(context), fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...s.songs.map((song) => SongTile(song: song, queue: lib.allSongs, index: lib.allSongs.indexOf(song))),
            ],
          ),
        )),
      ],
    );
  }

  Widget _msg(BuildContext context, IconData icon, String msg, String label, VoidCallback onTap) {
    return SizedBox(height: 300, child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(icon, size: 48, color: AurumTheme.textMutedOf(context)),
      const SizedBox(height: 12),
      Text(msg, style: TextStyle(color: AurumTheme.textMutedOf(context))),
      const SizedBox(height: 16),
      TextButton(onPressed: onTap, child: Text(label, style: TextStyle(color: AurumTheme.gold))),
    ])));
  }
}

class _SourceToggle extends StatelessWidget {
  final VoidCallback onToggle;
  const _SourceToggle({required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<SourceProvider>().isOnline;
    return GestureDetector(
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        width: 72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isOnline ? AurumTheme.gold.withOpacity(0.15) : AurumTheme.bgCardOf(context),
          border: Border.all(color: isOnline ? AurumTheme.gold : AurumTheme.dividerOf(context), width: 1.2),
        ),
        child: Stack(children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: isOnline ? Alignment.centerLeft : Alignment.centerRight,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline ? AurumTheme.gold : AurumTheme.bgElevatedOf(context),
                boxShadow: isOnline ? [BoxShadow(color: AurumTheme.gold.withOpacity(0.4), blurRadius: 8)] : [],
              ),
              child: Icon(isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded, size: 14, color: isOnline ? Colors.black : AurumTheme.textMutedOf(context)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SongCard extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongCard({required this.song, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.currentSong?.id == song.id);
    return GestureDetector(
      onTap: () => context.read<PlayerProvider>().playSong(song, queue: queue, index: index),
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(children: [
              AurumArtwork(url: song.artworkUrl, size: 140, borderRadius: 0),
              if (isPlaying)
                Container(
                  width: 140, height: 140,
                  decoration: BoxDecoration(color: Colors.black.withOpacity(0.4), borderRadius: const BorderRadius.vertical(top: Radius.circular(12))),
                  child: const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 32),
                ),
            ]),
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
