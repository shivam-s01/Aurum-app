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
  // Driven by the ROUTE'S OWN animation controller (see
  // utils/route_drag_dismiss.dart): the finger sets the route's value, the
  // route's SlideTransition moves the whole queue, and releasing lets the
  // same controller finish. One motion only — no extra transform/layer.
  late final RouteDragDismiss _dismiss;

  @override
  void initState() {
    super.initState();
    _dismiss = RouteDragDismiss(context);
  }

  // Live finger velocity (px/s, +down). ScrollEndNotification.dragDetails
  // is null after a fling, so the old flick-dismiss always read 0.
  double _velPx = 0.0;
  int _lastTickUs = 0;

  void _trackVelocity(double deltaDown) {
    final now = DateTime.now().microsecondsSinceEpoch;
    if (_lastTickUs != 0) {
      final dt = (now - _lastTickUs) / 1e6;
      if (dt > 0.0005) {
        _velPx = _velPx * 0.6 + (deltaDown / dt) * 0.4;
      }
    }
    _lastTickUs = now;
  }

  static const double _dismissDistance = 110.0;
  static const double _dismissVelocity = 900.0;

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;

    if (n is ScrollStartNotification) {
      _velPx = 0.0;
      _lastTickUs = 0;
    } else if (n is OverscrollNotification) {
      if (n.overscroll < 0 && n.metrics.pixels <= n.metrics.minScrollExtent) {
        if (!_dismiss.isActive && !_dismiss.start()) return false;
        if (n.dragDetails != null) _trackVelocity(-n.overscroll);
        _dismiss.update(-n.overscroll);
      }
    } else if (n is ScrollUpdateNotification) {
      final dy = n.scrollDelta ?? 0.0;
      if (_dismiss.isActive && dy > 0) {
        _trackVelocity(-dy);
        _dismiss.update(-dy);
      }
    } else if (n is ScrollEndNotification) {
      if (_dismiss.isActive) {
        _dismiss.end(
          velocityPxPerSec: n.dragDetails?.primaryVelocity ?? _velPx,
          dismissDistance: _dismissDistance,
          dismissVelocity: _dismissVelocity,
        );
      }
    }
    return false;
  }

  @override
  void dispose() {
    _dismiss.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        // The route's SlideTransition moves this whole subtree; no
        // per-frame transform/opacity/rebuild happens here.
        child: RepaintBoundary(
            child: ColoredBox(
              // Solid base travels WITH the content (was fixed on the
              // Scaffold, leaving a static layer behind while dragging).
              color: const Color(0xFF121212),
              child: SafeArea(
        bottom: false,
        child: Selector<PlayerProvider, (int, int, int, bool, LoopMode)>(
          // PERF: was queue.map(id).join(',') — allocated a list + a huge
          // string on EVERY provider notify (100+ songs, several times a
          // second). A rolling int hash over the ids is allocation-free
          // and still changes on add / remove / reorder.
          // FIX: shuffle + loop are now part of the key, so the pills
          // actually refresh when toggled (before, they never updated).
          selector: (_, p) {
            final q = p.queue;
            var h = 0;
            for (var i = 0; i < q.length; i++) {
              h = 0x1fffffff & (h * 31 + q[i].id.hashCode);
            }
            return (q.length, p.currentIndex, h, p.shuffle, p.loopMode);
          },
          builder: (context, _, __) {
            final player = context.read<PlayerProvider>();
            final queue = player.queue;
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
                      // Scoped rebuild: a like change repaints only this
                      // card, never the whole queue.
                      Selector<FavoritesProvider, bool>(
                        selector: (_, f) => f.isFavorite(currentSong.id),
                        builder: (context, isLiked, _) => _CurrentTrackCard(
                          song: currentSong,
                          isLiked: isLiked,
                          onToggleLike: () {
                            AurumHaptics.light();
                            context
                                .read<FavoritesProvider>()
                                .toggleFavorite(currentSong);
                          },
                        ),
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
          color: const Color(0x0FFFFFFF),
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
        : (active ? accent.withAlpha(56) : const Color(0x0FFFFFFF));
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

    return RepaintBoundary(
      child: Container(
      key: ValueKey('${song.id}_row_$index'),
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isCurrent ? accent.withAlpha(41) : Colors.transparent,
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
                        color: const Color(0x73000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: _EqualizerBars(color: accent),
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
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Equalizer bars for the current row. One tiny controller, only exists for
// the single current row, and it STOPS while paused (zero frames, zero
// CPU). It listens to isPlaying itself, so the queue list is never
// rebuilt for it. Painted by a CustomPainter inside a RepaintBoundary —
// no widget tree churn per frame.
// ─────────────────────────────────────────────────────────────────────────────
class _EqualizerBars extends StatefulWidget {
  final Color color;
  const _EqualizerBars({required this.color});

  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  PlayerProvider? _player;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = context.read<PlayerProvider>();
    if (!identical(p, _player)) {
      _player?.removeListener(_sync);
      _player = p..addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    final playing = _player?.isPlaying ?? false;
    if (playing) {
      if (!_c.isAnimating) _c.repeat();
    } else if (_c.isAnimating) {
      _c.stop(); // freeze bars in place while paused
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RepaintBoundary(
        child: CustomPaint(
          size: const Size(18, 18),
          painter: _BarsPainter(_c, widget.color),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final Animation<double> t;
  final Color color;
  _BarsPainter(this.t, this.color) : super(repaint: t);

  static const _phase = [0.0, 0.33, 0.66];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final barW = size.width / 5;
    for (var i = 0; i < 3; i++) {
      // triangle wave 0..1..0, phase-shifted per bar
      final v = ((t.value + _phase[i]) % 1.0);
      final h = 0.25 + 0.75 * (v < 0.5 ? v * 2 : (1 - v) * 2);
      final bh = size.height * h;
      final x = i * barW * 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - bh, barW, bh),
          const Radius.circular(1.5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.color != color;
}
