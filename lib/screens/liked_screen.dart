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
            // SELECTION APP BAR (FIX — "select all wala awkward hai"):
            // Select all/Deselect all used to be buried two taps deep
            // inside a 3-dot menu, which is exactly the kind of hidden
            // control that makes bulk-selection screens feel clunky
            // (Gmail/Photos/Spotify all put it directly in the app bar
            // as a single tap). Replaced with a direct toggling action
            // button — reads "Select all" while anything is unselected,
            // flips to "Deselect all" once every song is selected — plus
            // a dedicated unlike (delete) icon so the whole flow is two
            // visible taps (select all → unlike) instead of three
            // (menu → select all → menu → unlike).
            actions: _selectMode
                ? [
                    Consumer<FavoritesProvider>(
                      builder: (context, fav, _) {
                        final allSelected = fav.favorites.isNotEmpty &&
                            _selectedIds.length == fav.favorites.length;
                        return TextButton(
                          onPressed: () {
                            AurumHaptics.selection();
                            setState(() {
                              if (allSelected) {
                                _selectedIds.clear();
                              } else {
                                _selectedIds
                                  ..clear()
                                  ..addAll(fav.favorites.map((s) => s.id));
                              }
                            });
                          },
                          child: Text(
                            allSelected ? 'Deselect all' : 'Select all',
                            style: TextStyle(
                              color: AurumTheme.accentOf(context),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.delete_outline_rounded,
                        color: _selectedIds.isEmpty
                            ? AurumTheme.textMutedOf(context)
                            : Colors.redAccent,
                      ),
                      onPressed: _selectedIds.isEmpty ? null : _confirmUnlikeSelected,
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
                    // LONG-PRESS FIX ("long press krne pe kuch hota hi
                    // nahi"): this used to wrap SongTile in an outer
                    // GestureDetector(onLongPress: _enterSelectMode) and
                    // rely on the wrapper "winning" the gesture arena
                    // against SongTile's own internal InkWell long-press —
                    // it never did, so long-press only ever opened the
                    // options sheet and select mode could never be
                    // entered. Passing onLongPressOverride makes SongTile
                    // itself fire _enterSelectMode instead of its options
                    // sheet — a single recognizer, no arena conflict.
                    final tile = SongTile(
                      song: song,
                      queue: songs,
                      index: songIndex,
                      curatedQueue: true,
                      onLongPressOverride:
                          _selectMode ? null : () => _enterSelectMode(song.id),
                    );
                    if (!_selectMode) {
                      return tile;
                    }
                    // CHECKBOX PLACEMENT FIX ("select wala option
                    // thumbnail pr aa raha hai, awkward lagta hai"): the
                    // previous version squeezed an extra circle in
                    // between the screen edge and the artwork, visually
                    // colliding with/crowding the thumbnail. Spotify and
                    // Google Photos instead replace the thumbnail itself
                    // with the selection indicator — a dimming scrim
                    // directly over the artwork with a checkmark
                    // centered on top when selected — so nothing new is
                    // squeezed into the row layout at all; the check
                    // simply takes over the exact space the artwork
                    // already occupies. Precisely sized/positioned to
                    // match SongTile's own artwork geometry (58px,
                    // 10px radius, 16px left padding) so it sits exactly
                    // on top of the real thumbnail beneath, pixel for
                    // pixel.
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
                                  const SizedBox(width: 16),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 150),
                                    width: 58,
                                    height: 58,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: isSelected
                                          ? Colors.black.withOpacity(0.55)
                                          : Colors.transparent,
                                    ),
                                    alignment: Alignment.center,
                                    child: AnimatedScale(
                                      duration: const Duration(milliseconds: 150),
                                      scale: isSelected ? 1.0 : 0.0,
                                      curve: Curves.easeOutBack,
                                      child: Container(
                                        width: 28,
                                        height: 28,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AurumTheme.accentOf(context),
                                        ),
                                        child: Icon(
                                          Icons.check_rounded,
                                          color: AurumTheme.bgOf(context),
                                          size: 18,
                                        ),
                                      ),
                                    ),
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
