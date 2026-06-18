import 'dart:io';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:palette_generator/palette_generator.dart';
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
import 'profile_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// HomeScreen
// ─────────────────────────────────────────────────────────────────────────────

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
      final topArtists = context.read<RecentlyPlayedProvider>().topArtists(count: 3);
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
      body: Stack(
        children: [
          // ── Top ambient glow layer (behind everything) ──
          const _TopAmbientGlow(),

          // ── Main scroll content ──
          RefreshIndicator(
            color: AurumTheme.gold,
            backgroundColor: AurumTheme.bgCardOf(context),
            displacement: 60,
            onRefresh: () => isOnline
                ? _loadOnline()
                : context.read<LibraryProvider>().refresh(),
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              slivers: [
                _buildAppBar(context, src),
                SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: isOnline
                              ? const Offset(-0.06, 0)
                              : const Offset(0.06, 0),
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
                const SliverToBoxAdapter(child: SizedBox(height: 110)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, SourceProvider src) {
    return SliverAppBar(
      backgroundColor: Colors.transparent,
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
        _SourceToggle(onToggle: () {
          HapticFeedback.mediumImpact();
          src.toggle();
        }),
        IconButton(
          icon: Icon(Icons.settings_outlined,
              color: AurumTheme.textSecondaryOf(context)),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        const _ProfileAvatarButton(),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Top Ambient Glow — Echo Nightly style, palette from currently playing song
// Completely self-contained: watches PlayerProvider, extracts color, animates.
// Uses RepaintBoundary so it NEVER causes the scroll list to repaint.
// ─────────────────────────────────────────────────────────────────────────────

class _TopAmbientGlow extends StatefulWidget {
  const _TopAmbientGlow();

  @override
  State<_TopAmbientGlow> createState() => _TopAmbientGlowState();
}

class _TopAmbientGlowState extends State<_TopAmbientGlow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _opacity;

  Color _currentColor = Colors.transparent;
  Color _targetColor  = Colors.transparent;
  String _lastUrl     = '';

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _extractColor(String url) async {
    if (url.isEmpty || url == _lastUrl) return;
    _lastUrl = url;

    try {
      final ImageProvider provider = url.startsWith('http')
          ? CachedNetworkImageProvider(url)
          : FileImage(File(url)) as ImageProvider;

      // 80x80 is enough for palette — minimal cost
      final pg = await PaletteGenerator.fromImageProvider(
        provider,
        size: const Size(80, 80),
      );

      final raw = pg.vibrantColor?.color ??
          pg.dominantColor?.color ??
          pg.lightVibrantColor?.color;

      if (raw == null || !mounted) return;

      // Snapshot current lerped value before transition
      final t = _ctrl.value;
      _currentColor = Color.lerp(_currentColor, _targetColor, t) ?? _currentColor;

      // Dark + desaturated so it's ambient, not harsh
      _targetColor = HSLColor.fromColor(raw)
          .withSaturation(0.55)
          .withLightness(0.18)
          .toColor();

      // Fade out → update → fade in (crossfade feel)
      await _ctrl.reverse();
      if (!mounted) return;
      setState(() => _currentColor = _targetColor);
      _ctrl.forward();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final song = context.select<PlayerProvider, Song?>((p) => p.currentSong);

    if (song != null) {
      // Fire async, no setState in build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _extractColor(song.artworkUrl);
      });
    }

    if (song == null) return const SizedBox.shrink();

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _opacity,
        builder: (_, __) {
          return Opacity(
            opacity: _opacity.value,
            child: SizedBox(
              height: 260,
              width: double.infinity,
              child: _GlowPainter(color: _currentColor),
            ),
          );
        },
      ),
    );
  }
}

// CustomPainter — single radial gradient blob at the top center.
// Cheaper than a Container with BoxDecoration because it skips the
// layout pass entirely.
class _GlowPainter extends StatelessWidget {
  final Color color;
  const _GlowPainter({required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _GlowBlobPainter(color));
  }
}

class _GlowBlobPainter extends CustomPainter {
  final Color color;
  _GlowBlobPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (color == Colors.transparent) return;

    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topCenter,
        radius: 1.1,
        colors: [
          color.withOpacity(0.38),
          color.withOpacity(0.12),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromLTWH(0, -size.height * 0.3, size.width, size.height * 1.3));

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(_GlowBlobPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Online Content
// ─────────────────────────────────────────────────────────────────────────────

class _OnlineContent extends StatelessWidget {
  final List<SongSection> sections;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  const _OnlineContent({
    super.key,
    required this.sections,
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) return _buildShimmer(context);
    if (sections.isEmpty) {
      return _buildError(
        context,
        message: error ?? "Couldn't load songs right now.\nPull down or tap retry.",
      );
    }
    return Column(
      children: [
        for (int i = 0; i < sections.length; i++)
          _StaggeredSection(
            index: i,
            child: _buildSection(context, sections[i]),
          ),
      ],
    );
  }

  Widget _buildShimmer(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AurumTheme.bgCardOf(context),
      highlightColor: AurumTheme.bgElevatedOf(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(3, (_) => Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title placeholder
                Container(
                  width: 130,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 14),
                // Cards row placeholder
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 4,
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
              ],
            ),
          )),
        ),
      ),
    );
  }

  Widget _buildError(BuildContext context, {String? message}) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_off_rounded, size: 48,
              color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(
            message ?? error ?? 'Failed to load.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AurumTheme.textMutedOf(context)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onRetry,
            child: Text('Retry', style: TextStyle(color: AurumTheme.gold)),
          ),
        ]),
      ),
    );
  }

  Widget _buildSection(BuildContext context, SongSection section) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, left: 16, right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                section.title,
                style: TextStyle(
                  color: AurumTheme.textPrimaryOf(context),
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  _showAllSongs(context, section);
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    'See all',
                    style: TextStyle(
                      color: AurumTheme.gold.withOpacity(0.85),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Faded horizontal scroll
          _FadedHorizontalList(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: section.songs.length,
              itemBuilder: (_, i) => _SongCard(
                song: section.songs[i],
                queue: section.songs,
                index: i,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAllSongs(BuildContext context, SongSection section) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AurumTheme.bgCardOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.93,
        minChildSize: 0.4,
        expand: false,
        builder: (_, ctrl) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(children: [
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: AurumTheme.dividerOf(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  section.title,
                  style: TextStyle(
                    color: AurumTheme.textPrimaryOf(context),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ]),
          ),
          Divider(height: 1, color: AurumTheme.dividerOf(context)),
          Expanded(
            child: ListView.builder(
              controller: ctrl,
              physics: const BouncingScrollPhysics(),
              itemCount: section.songs.length,
              itemBuilder: (ctx, i) => SongTile(
                song: section.songs[i],
                queue: section.songs,
                index: i,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Staggered section — fade + slide up, one by one
// ─────────────────────────────────────────────────────────────────────────────

class _StaggeredSection extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredSection({required this.index, required this.child});

  @override
  State<_StaggeredSection> createState() => _StaggeredSectionState();
}

class _StaggeredSectionState extends State<_StaggeredSection>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double>   _fade;
  late Animation<Offset>   _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.10),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );

    Future.delayed(Duration(milliseconds: 50 + widget.index * 70), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => FadeTransition(
        opacity: _fade,
        child: SlideTransition(position: _slide, child: child),
      ),
      child: widget.child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Faded horizontal list edges
// ─────────────────────────────────────────────────────────────────────────────

class _FadedHorizontalList extends StatelessWidget {
  final Widget child;
  final double height;
  const _FadedHorizontalList({required this.child, required this.height});

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return SizedBox(
      height: height,
      child: ShaderMask(
        shaderCallback: (bounds) => LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            bg.withOpacity(0.0),
            bg,
            bg,
            bg.withOpacity(0.0),
          ],
          stops: const [0.0, 0.04, 0.96, 1.0],
        ).createShader(bounds),
        blendMode: BlendMode.srcOver,
        child: child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Offline Content
// ─────────────────────────────────────────────────────────────────────────────

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();

    if (lib.status == LibraryStatus.idle || lib.status == LibraryStatus.loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: AurumLoader()),
      );
    }
    if (lib.status == LibraryStatus.noPermission) {
      return _msg(context, Icons.folder_off_rounded,
          'Storage permission needed', 'Grant Permission', () => lib.load());
    }
    if (lib.allSongs.isEmpty) {
      return _msg(context, Icons.music_off_rounded,
          'No local songs found', 'Scan Again', () => lib.refresh());
    }

    final sections = lib.sections.isNotEmpty
        ? lib.sections
        : [SongSection(title: 'Local Songs', songs: lib.allSongs)];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Row(children: [
            Icon(Icons.download_done_rounded, color: AurumTheme.gold, size: 18),
            const SizedBox(width: 8),
            Text(
              '${lib.allSongs.length} songs on device',
              style: TextStyle(
                  color: AurumTheme.textMutedOf(context), fontSize: 13),
            ),
          ]),
        ),
        ...sections.asMap().entries.map((e) => _StaggeredSection(
          index: e.key,
          child: Padding(
            padding: const EdgeInsets.only(top: 20, left: 16, right: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.value.title,
                    style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...e.value.songs.map((song) => SongTile(
                  song: song,
                  queue: lib.allSongs,
                  index: lib.allSongs.indexOf(song),
                )),
              ],
            ),
          ),
        )),
      ],
    );
  }

  Widget _msg(BuildContext context, IconData icon, String msg,
      String label, VoidCallback onTap) {
    return SizedBox(
      height: 300,
      child: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 48, color: AurumTheme.textMutedOf(context)),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: AurumTheme.textMutedOf(context))),
          const SizedBox(height: 16),
          TextButton(
            onPressed: onTap,
            child: Text(label, style: TextStyle(color: AurumTheme.gold)),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profile Avatar Button
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileAvatarButton extends StatefulWidget {
  const _ProfileAvatarButton();
  @override
  State<_ProfileAvatarButton> createState() => _ProfileAvatarButtonState();
}

class _ProfileAvatarButtonState extends State<_ProfileAvatarButton> {
  String? _avatarPath;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final path = await UserProfile.getAvatarPath();
    if (mounted) setState(() => _avatarPath = path);
  }

  Future<void> _openProfile() async {
    HapticFeedback.lightImpact();
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16, left: 4),
      child: GestureDetector(
        onTap: _openProfile,
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: AurumTheme.goldGradient,
          ),
          padding: const EdgeInsets.all(1.5),
          child: ClipOval(
            child: Container(
              color: AurumTheme.bgOf(context),
              child: _avatarPath != null
                  ? Image.file(File(_avatarPath!), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.person_rounded,
                          color: AurumTheme.textSecondaryOf(context), size: 20))
                  : Icon(Icons.person_rounded,
                      color: AurumTheme.textSecondaryOf(context), size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Source Toggle
// ─────────────────────────────────────────────────────────────────────────────

class _SourceToggle extends StatelessWidget {
  final VoidCallback onToggle;
  const _SourceToggle({required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final isOnline = context.watch<SourceProvider>().isOnline;
    return GestureDetector(
      onTap: onToggle,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
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
        child: Stack(children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOut,
            alignment: isOnline ? Alignment.centerLeft : Alignment.centerRight,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? AurumTheme.gold
                    : AurumTheme.bgElevatedOf(context),
                boxShadow: isOnline
                    ? [BoxShadow(
                        color: AurumTheme.gold.withOpacity(0.4),
                        blurRadius: 8)]
                    : [],
              ),
              child: Icon(
                isOnline ? Icons.wifi_rounded : Icons.wifi_off_rounded,
                size: 14,
                color: isOnline ? Colors.black : AurumTheme.textMutedOf(context),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Song Card — rounded corners + press scale animation
// ─────────────────────────────────────────────────────────────────────────────

class _SongCard extends StatefulWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const _SongCard({required this.song, required this.queue, required this.index});

  @override
  State<_SongCard> createState() => _SongCardState();
}

class _SongCardState extends State<_SongCard>
    with SingleTickerProviderStateMixin {
  bool _isTapping = false;
  late AnimationController _pressCtrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _pressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _scale = Tween(begin: 1.0, end: 0.94).animate(
      CurvedAnimation(parent: _pressCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() { _pressCtrl.dispose(); super.dispose(); }

  Future<void> _handleTap() async {
    if (_isTapping) return;
    _isTapping = true;
    unawaited(_pressCtrl.forward().then((_) => _pressCtrl.reverse()));
    HapticFeedback.selectionClick();
    context.read<RecentlyPlayedProvider>().addPlay(widget.song);
    context.read<PlayerProvider>()
        .playSong(widget.song, queue: widget.queue, index: widget.index);
    await Future.delayed(const Duration(milliseconds: 300));
    if (mounted) _isTapping = false;
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isPlaying = context.select<PlayerProvider, bool>(
        (p) => p.currentSong?.id == song.id);

    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Container(
          width: 140,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Artwork ──
              Stack(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AurumArtwork(
                      url: song.artworkUrl, size: 140, borderRadius: 12),
                ),
                // Playing overlay
                if (isPlaying)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 140, height: 140,
                      color: Colors.black.withOpacity(0.42),
                      child: const Icon(Icons.equalizer_rounded,
                          color: AurumTheme.gold, size: 30),
                    ),
                  ),
                // Gold border ring when playing
                if (isPlaying)
                  Container(
                    width: 140, height: 140,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AurumTheme.gold.withOpacity(0.65),
                        width: 1.5,
                      ),
                    ),
                  ),
              ]),
              // ── Title ──
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
                child: Text(
                  song.title,
                  style: TextStyle(
                    color: isPlaying
                        ? AurumTheme.gold
                        : AurumTheme.textPrimaryOf(context),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // ── Artist ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  song.artist,
                  style: TextStyle(
                      color: AurumTheme.textSecondaryOf(context),
                      fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ignore: avoid_void_async
void unawaited(Future<void> f) {}
