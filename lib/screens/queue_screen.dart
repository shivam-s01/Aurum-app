import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/aurum_pressable.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AurumTheme.bg,
      appBar: AppBar(
        backgroundColor: AurumTheme.bg,
        title: ShaderMask(
          shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
          child: const Text(
            'Queue',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
          color: AurumTheme.textSecondary,
          onPressed: () {
            HapticFeedback.selectionClick();
            Navigator.pop(context);
          },
        ),
      ),
      // PERF FIX: was Consumer<PlayerProvider>, rebuilding this entire
      // reorderable list (including every song tile) on every position
      // tick. Selector gates rebuilds to real queue/song changes only —
      // matters most exactly when the user is tapping fast through the
      // queue, which is when this screen tends to be open.
      body: Selector<PlayerProvider, (int, int, String)>(
        // Joined IDs catch reorders/removals that don't change length or
        // currentIndex (e.g. dragging item 5 to position 8 while song 0
        // is still playing) — cheap for typical queue sizes (tens of
        // songs), and only recomputed when PlayerProvider notifies at all.
        selector: (_, p) => (
          p.queue.length,
          p.currentIndex,
          p.queue.map((s) => s.id).join(','),
        ),
        builder: (context, _, __) {
          final player = context.read<PlayerProvider>();
          final queue = player.queue;
          if (queue.isEmpty) {
            return const AurumEmptyState(
              icon: Icons.queue_music_rounded,
              title: 'Queue is empty',
              subtitle: 'Songs you play next will line up here',
            );
          }

          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: queue.length,
            onReorder: (from, to) {
              HapticFeedback.mediumImpact();
              final adjustedTo = to > from ? to - 1 : to;
              player.moveQueueItem(from, adjustedTo);
            },
            itemBuilder: (context, i) {
              final song = queue[i];
              final isCurrent = i == player.currentIndex;
              return AurumPressable(
                key: ValueKey('${song.id}_$i'),
                scaleAmount: 0.985,
                haptic: false, // onTap below fires its own selectionClick
                onTap: () {
                  HapticFeedback.selectionClick();
                  player.skipToIndex(i);
                },
                child: ListTile(
                leading: Stack(
                  alignment: Alignment.center,
                  children: [
                    AurumArtwork(url: song.artworkUrl, size: 44, borderRadius: 6),
                    if (isCurrent)
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 20),
                      ),
                  ],
                ),
                title: Text(
                  song.title,
                  style: TextStyle(
                    color: isCurrent ? AurumTheme.gold : AurumTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  song.artist,
                  style: const TextStyle(color: AurumTheme.textSecondary, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isCurrent)
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          player.removeFromQueue(i);
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.close_rounded, color: AurumTheme.textMuted, size: 18),
                        ),
                      ),
                    const Icon(Icons.drag_handle_rounded, color: AurumTheme.textMuted, size: 20),
                  ],
                ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
