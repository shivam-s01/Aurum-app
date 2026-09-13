import 'package:aurum_music/widgets/aurum_loader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/song_tile.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/mini_player_slot.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
import '../utils/aurum_sheet.dart';

class LikedScreen extends StatefulWidget {
  const LikedScreen({super.key});

  @override
  State<LikedScreen> createState() => _LikedScreenState();
}

class _LikedScreenState extends State<LikedScreen> {
  // MULTI-SELECT ("select krne pr 3 dot aa jaye ... select all, unlike ka
  // option"): selecting a song doesn't touch SongTile itself (shared by
  // every other screen in the app) — instead, while _selectMode is true,
  // a transparent GestureDetector is overlaid on top of each SongTile that
  // intercepts the tap for selection instead of letting it reach the tile
  // underneath and start playback. A normal long-press on any tile (while
  // not already selecting) enters select mode with that song pre-selected,
  // same gesture pattern as the Artists tab's multi-select above.
  bool _selectMode = false;
  final Set<String> _selectedIds = {};

  void _enterSelectMode(String firstId) {
    AurumHaptics.medium();
    setState(() {
      _selectMode = true;
      _selectedIds
        ..clear()
        ..add(firstId);
    });
  }

  void _toggleSelected(String id) {
    AurumHaptics.selection();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectMode = false;
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _confirmUnlikeSelected() async {
    final count = _selectedIds.length;
    final confirmed = await showAurumModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AurumTheme.bgCardOf(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count == 1 ? 'Unlike this song?' : 'Unlike $count songs?',
              style: TextStyle(
                color: AurumTheme.textPrimaryOf(context),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(sheetContext, false),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: () => Navigator.pop(sheetContext, true),
                    child: const Text('Unlike'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    AurumHaptics.medium();
    final ids = List<String>.from(_selectedIds);
    _exitSelectMode();
    await context.read<FavoritesProvider>().removeMany(ids);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bgOf(context),
      // SPOTIFY-STYLE PERSISTENT MINI PLAYER: this screen is pushed via
      // Navigator.push from Library, so it builds its own Scaffold on top
      // of MainShell's — MainShell's own mini player (in its
      // bottomNavigationBar) is no longer part of the visible layout once
      // this screen is on top. MiniPlayerSlot reproduces the exact same
      // visibility/transparency behavior here, so playback controls never
      // disappear just because the user browsed into Liked Songs — same
      // as Spotify/YT Music, where the mini player follows you into every
      // browsing screen and only hides behind the full Now Playing view.
      bottomNavigationBar: const MiniPlayerSlot(),
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        // PERF FIX (same class as home_screen.dart / artist_screen.dart /
        // library_screen.dart / mix_screen.dart's matching fix): default
        // Sliver cacheExtent (250px) is too small for a large liked-songs
        // list — fast flings tear down and rebuild tiles just outside
        // that tiny buffer. Matching the same 1200 used elsewhere.
        cacheExtent: 1200,
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            floating: true,
            snap: true,
            backgroundColor: AurumTheme.bgOf(context),
            leading: IconButton(
              icon: Icon(
                _selectMode ? Icons.close_rounded : Icons.arrow_back_ios_rounded,
                color: AurumTheme.textSecondaryOf(context),
                size: 20,
              ),
              onPressed: () {
                AurumHaptics.light();
                if (_selectMode) {
                  _exitSelectMode();
                } else {
                  Navigator.pop(context);
                }
              },
            ),
            // SELECTION APP BAR ("select krne pr 3 dot aa jaye"): while
            // selecting, the title/heart row is swapped for a live count
            // and a 3-dot menu (Select all / Deselect all / Unlike
            // selected) — same pattern as the Artists tab above, so the
            // two multi-select flows feel identical across the app.
            actions: _selectMode
                ? [
                    Consumer<FavoritesProvider>(
                      builder: (context, fav, _) => PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert_rounded,
                            color: AurumTheme.textPrimaryOf(context)),
                        onSelected: (value) {
                          if (value == 'select_all') {
                            AurumHaptics.selection();
                            setState(() {
                              _selectedIds
                                ..clear()
                                ..addAll(fav.favorites.map((s) => s.id));
                            });
                          } else if (value == 'deselect_all') {
                            AurumHaptics.selection();
                            setState(() => _selectedIds.clear());
                          } else if (value == 'unlike') {
                            _confirmUnlikeSelected();
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'select_all', child: Text('Select all')),
                          PopupMenuItem(value: 'deselect_all', child: Text('Deselect all')),
                          PopupMenuItem(value: 'unlike', child: Text('Unlike selected')),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                  ]
                : null,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.fromLTRB(52, 0, 16, 16),
              title: _selectMode
                  ? Text(
                      '${_selectedIds.length} selected',
                      style: TextStyle(
                        color: AurumTheme.textPrimaryOf(context),
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : Row(
                      children: [
                        const Icon(Icons.favorite_rounded, color: Color(0xFFE1306C), size: 22),
                        const SizedBox(width: 8),
                        ShaderMask(
                          shaderCallback: (b) => AurumTheme.accentGradient.createShader(b),
                          child: Text(l10n.libraryLikedSongs, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                        ),
                      ],
                    ),
            ),
          ),
          Consumer<FavoritesProvider>(
            builder: (context, fav, _) {
              if (fav.isLoading) {
                return SliverFillRemaining(
                  child: Center(child: AurumMorphLoader(size: 56, contained: true)),
                );
              }

              if (fav.favorites.isEmpty) {
                return SliverFillRemaining(
                  child: Center(
                    child: AurumEmptyState(
                      icon: Icons.favorite_border_rounded,
                      title: l10n.likedNoSongsYet,
                      subtitle: l10n.likedTapToSave,
                    ),
                  ),
                );
              }

              final songs = fav.favorites;
              // PERF FIX (nav-in jank on Liked Songs — "jatka" on open):
              // this used to build every SongTile eagerly via
              // SliverChildListDelegate + songs.map(...).toList() — the
              // ENTIRE liked list was constructed, laid out, and painted
              // on the very first frame after the push transition
              // started, competing directly with the 350ms page-slide
              // animation for frame budget. On a sizeable liked list that
              // showed up as a visible stutter right as the screen
              // entered, unlike every other library sub-screen (History,
              // Downloads, Albums, Artists), which already used a lazy
              // SliverChildBuilderDelegate. Switched to the same lazy
              // pattern: only the tiles actually on/near screen build on
              // that first frame, the rest build cheaply as the user
              // scrolls — matching Spotify/YT Music's own lazy list
              // behavior and giving this screen the same light, instant
              // open feel as its siblings.
              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == 0) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                        child: Row(
                          children: [
                            Text(l10n.librarySongsCount(songs.length), style: TextStyle(color: AurumTheme.textMutedOf(context), fontSize: 13)),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                AurumHaptics.medium();
                                final player = context.read<PlayerProvider>();
                                player.playSong(songs[0], queue: songs, index: 0, curatedQueue: true);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                decoration: BoxDecoration(
                                  gradient: AurumTheme.accentGradient,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Icon(Icons.play_arrow_rounded, color: AurumTheme.bgOf(context), size: 18),
                                  const SizedBox(width: 4),
                                  Text(l10n.commonPlayAll, style: TextStyle(color: AurumTheme.bgOf(context), fontSize: 13, fontWeight: FontWeight.w700)),
                                ]),
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    if (index == songs.length + 1) {
                      return const SizedBox(height: 100);
                    }
                    final songIndex = index - 1;
                    final song = songs[songIndex];
                    final isSelected = _selectedIds.contains(song.id);
                    final tile = SongTile(
                      song: song,
                      queue: songs,
                      index: songIndex,
                      curatedQueue: true,
                    );
                    if (!_selectMode) {
                      // Long-press still needs to enter select mode even
                      // though SongTile's own onLongPress already opens
                      // its options sheet — wrapping with a Listener that
                      // only watches for a long-press-and-hold BEFORE
                      // SongTile's own gesture arena resolves would be
                      // fragile, so instead the entry point into select
                      // mode is the row's leading area only (a small,
                      // reliable long-press target that doesn't fight
                      // SongTile's own long-press-for-options behavior on
                      // the rest of the row).
                      return GestureDetector(
                        onLongPress: () => _enterSelectMode(song.id),
                        behavior: HitTestBehavior.translucent,
                        child: tile,
                      );
                    }
                    return Stack(
                      children: [
                        IgnorePointer(child: tile),
                        Positioned.fill(
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _toggleSelected(song.id),
                              child: Row(
                                children: [
                                  const SizedBox(width: 8),
                                  Icon(
                                    isSelected
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_off_rounded,
                                    color: isSelected
                                        ? AurumTheme.accentOf(context)
                                        : AurumTheme.textMutedOf(context),
                                    size: 22,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                  childCount: songs.length + 2,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
