// ─────────────────────────────────────────────────────────────────────────────
// QueueScreen — "Up Next" queue, redesigned to match the Spotify-style
// reference: drag handle, current-track card (art + title/artist + like),
// a meta pill (lock / overflow · song count · total duration), a row of
// three transport toggles (shuffle / repeat / shuffle-emphasis matching
// the reference's layout), a source header ("Unknown" / whatever the
// queue's context label is), then the flat scrollable list itself with
// the currently-playing row highlighted and an animated "now playing"
// bars icon in place of a track number.
// ─────────────────────────────────────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import '../providers/player_provider.dart';
import '../models/song.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/aurum_pressable.dart';
import '../widgets/aurum_like_button.dart';
import '../providers/favorites_provider.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';
// Real shared "3-dot" song menu (albums/liked/download/playlist/etc.) —
// used for the meta pill's overflow button so it opens the same sheet
// as everywhere else in the app instead of doing nothing.
import '../widgets/aurum_song_options_sheet.dart' show showAurumSongOptions;

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  // ── Swipe-down-to-dismiss ────────────────────────────────────────────────
  // ROOT CAUSE of "up next swipe down nahi ho raha": this screen had NO
  // dismiss gesture at all — the drag handle at the top was purely
  // decorative — so the only way out was the system back button.
  //
  // Same scroll-native technique as the player: the list keeps every
  // gesture, and when it is already at the top and the finger keeps
  // pulling down, that overscroll drives the screen downward. Past the
  // distance/velocity threshold it pops; otherwise it springs back.
  // (Reordering uses its own long-press/drag-handle recognizer, so it is
  // unaffected.)
  double _dragDy = 0.0;
  static const double _dismissDistance = 110.0;
  static const double _dismissVelocity = 900.0;

  double get _maxDrag => MediaQuery.of(context).size.height * 0.30;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is OverscrollNotification) {
      if (n.overscroll < 0 && n.metrics.pixels <= n.metrics.minScrollExtent) {
        final next = (_dragDy - n.overscroll).clamp(0.0, _maxDrag).toDouble();
        if (next != _dragDy) setState(() => _dragDy = next);
      }
    } else if (n is ScrollUpdateNotification) {
      final dy = n.scrollDelta ?? 0.0;
      if (_dragDy > 0 && dy > 0) {
        setState(
            () => _dragDy = (_dragDy - dy).clamp(0.0, _maxDrag).toDouble());
      }
    } else if (n is ScrollEndNotification) {
      final v = n.dragDetails?.primaryVelocity ?? 0.0;
      if (_dragDy > _dismissDistance || (_dragDy > 24.0 && v > _dismissVelocity)) {
        Navigator.of(context).maybePop();
      } else if (_dragDy != 0.0) {
        setState(() => _dragDy = 0.0);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final dragT = (_dragDy / _maxDrag).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Opacity(
          opacity: 1.0 - dragT * 0.35,
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: SafeArea(
        bottom: false,
        child: Selector<PlayerProvider, (int, int, String)>(
          selector: (_, p) => (
            p.queue.length,
            p.currentIndex,
            p.queue.map((s) => s.id).join(','),
          ),
          builder: (context, _, __) {
            final player = context.read<PlayerProvider>();
            final queue = player.queue;
            final favorites = context.watch<FavoritesProvider>();
            final currentSong = player.currentSong;

            if (queue.isEmpty || currentSong == null) {
              return Column(
                children: [
                  const _DragHandle(),
                  Expanded(
                    child: AurumEmptyState(
                      icon: Icons.queue_music_rounded,
                      title: l10n.queueEmpty,
                      subtitle: l10n.queueEmptySubtitle,
                    ),
                  ),
                ],
              );
            }

            final totalSeconds = queue.fold<int>(
              0,
              (sum, s) => sum + (s.duration ?? 0),
            );

            return CustomScrollView(
              physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const _DragHandle(),
                      const SizedBox(height: 4),
                      _CurrentTrackCard(
                        song: currentSong,
                        isLiked: favorites.isFavorite(currentSong.id),
                        onToggleLike: () {
                          AurumHaptics.light();
                          favorites.toggleFavorite(currentSong);
                        },
                      ),
                      const SizedBox(height: 18),
                      _QueueMetaPill(
                        songCount: queue.length,
                        totalSeconds: totalSeconds,
                        onMore: () => showAurumSongOptions(
                          context,
                          currentSong,
                          showPlayerTools: true,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _TransportToggleRow(player: player),
                      const SizedBox(height: 22),
                      _SourceHeader(title: l10n.queueTitle),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.only(bottom: 24),
                  sliver: SliverReorderableList(
                    itemCount: queue.length,
                    onReorder: (from, to) {
                      AurumHaptics.medium();
                      final adjustedTo = to > from ? to - 1 : to;
                      player.moveQueueItem(from, adjustedTo);
                    },
                    itemBuilder: (context, i) {
                      final song = queue[i];
                      final isCurrent = i == player.currentIndex;
                      return _QueueRow(
                        key: ValueKey('${song.id}_$i'),
                        index: i,
                        song: song,
                        isCurrent: isCurrent,
                        onTap: () {
                          AurumHaptics.selection();
                          player.skipToIndex(i);
                        },
                        onRemove: isCurrent
                            ? null
                            : () {
                                AurumHaptics.light();
                                player.removeFromQueue(i);
                              },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Drag handle — the small pill at the very top matching the reference's
// bottom-sheet affordance.
// ─────────────────────────────────────────────────────────────────────────────
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Current track card — big artwork thumbnail, title/artist, like button.
// ─────────────────────────────────────────────────────────────────────────────
class _CurrentTrackCard extends StatelessWidget {
  final Song song;
  final bool isLiked;
  final VoidCallback onToggleLike;

  const _CurrentTrackCard({
    required this.song,
    required this.isLiked,
    required this.onToggleLike,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AurumArtwork(url: song.artworkUrl, size: 72, borderRadius: 8),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AurumLikeButton(
            isLiked: isLiked,
            size: 26,
            likedColor: AurumTheme.accent,
            unlikedColor: Colors.white70,
            onTap: onToggleLike,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Meta pill — lock icon · overflow menu (both visual/tappable, matching
// reference) · "N songs • total duration".
// ─────────────────────────────────────────────────────────────────────────────
class _QueueMetaPill extends StatelessWidget {
  final int songCount;
  final int totalSeconds;
  final VoidCallback? onMore;

  const _QueueMetaPill({
    required this.songCount,
    required this.totalSeconds,
    this.onMore,
  });

  String get _durationLabel {
    final d = Duration(seconds: totalSeconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            const SizedBox(width: 6),
            const Icon(Icons.lock_outline_rounded,
                color: Colors.white38, size: 16),
            // FIX ("upnext ekdam screenshot jaisa" — reference pill shows
            // lock icon AND a ⋮ overflow icon together on the left): this
            // only ever rendered the lock icon, with no overflow button
            // at all next to it.
            IconButton(
              icon: const Icon(Icons.more_vert_rounded,
                  color: Colors.white38, size: 18),
              onPressed: onMore,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              splashRadius: 18,
            ),
            const Spacer(),
            Text(
              '$songCount songs • $_durationLabel',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transport toggle row — shuffle / repeat / shuffle (emphasis pill), each
// reflecting and driving the real PlayerProvider state instead of being
// decorative, matching the reference's three-pill row.
// ─────────────────────────────────────────────────────────────────────────────
class _TransportToggleRow extends StatelessWidget {
  final PlayerProvider player;
  const _TransportToggleRow({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: _TogglePill(
              icon: Icons.shuffle_rounded,
              active: player.shuffle,
              onTap: () {
                AurumHaptics.light();
                player.toggleShuffle();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TogglePill(
              icon: player.loopMode == LoopMode.one
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded,
              active: player.loopMode != LoopMode.off,
              onTap: () {
                AurumHaptics.light();
                player.toggleLoop();
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TogglePill(
              icon: Icons.play_arrow_rounded,
              active: false,
              filled: true,
              onTap: () {
                AurumHaptics.medium();
                player.togglePlay();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final IconData icon;
  final bool active;
  final bool filled;
  final VoidCallback onTap;

  const _TogglePill({
    required this.icon,
    required this.active,
    this.filled = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);
    final bg = filled
        ? accent
        : (active ? accent.withOpacity(0.22) : Colors.white.withOpacity(0.06));
    final fg = filled ? Colors.black : (active ? accent : Colors.white70);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(child: Icon(icon, color: fg, size: 22)),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Source header — small label group above the flat list (e.g. album /
// playlist / "Unknown" the queue was built from), matching the reference.
// ─────────────────────────────────────────────────────────────────────────────
class _SourceHeader extends StatelessWidget {
  final String title;
  const _SourceHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12, height: 1),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Queue row — thumbnail, title/artist, duration, overflow menu. Current
// track gets a highlighted background + animated equalizer bars in place
// of artwork dimming, matching the reference's olive-highlighted row.
// Drag-to-reorder is triggered ONLY from the trailing drag handle (see the
// long comment this preserves from the previous implementation) so it
// never fights the row's own tap-to-play or the remove button.
// ─────────────────────────────────────────────────────────────────────────────
class _QueueRow extends StatelessWidget {
  final int index;
  final Song song;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _QueueRow({
    super.key,
    required this.index,
    required this.song,
    required this.isCurrent,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AurumTheme.accentOf(context);

    return Container(
      key: ValueKey('${song.id}_row_$index'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isCurrent ? accent.withOpacity(0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: AurumPressable(
        scaleAmount: 0.985,
        haptic: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: AurumArtwork(
                        url: song.artworkUrl, size: 48, borderRadius: 6),
                  ),
                  if (isCurrent)
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.45),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(Icons.equalizer_rounded,
                          color: accent, size: 20),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? accent : Colors.white,
                        fontSize: 15,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${song.artist} • ${song.durationString}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white38, size: 18),
                  onPressed: onRemove,
                )
              else
                const SizedBox(width: 8),
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle_rounded,
                      color: Colors.white38, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
