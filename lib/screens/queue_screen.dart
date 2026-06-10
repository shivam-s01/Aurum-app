import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';

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
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Consumer<PlayerProvider>(
        builder: (context, player, _) {
          final queue = player.queue;
          if (queue.isEmpty) {
            return const Center(
              child: Text('Queue is empty', style: TextStyle(color: AurumTheme.textMuted)),
            );
          }

          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: queue.length,
            onReorder: (from, to) {
              final adjustedTo = to > from ? to - 1 : to;
              player.moveQueueItem(from, adjustedTo);
            },
            itemBuilder: (context, i) {
              final song = queue[i];
              final isCurrent = i == player.currentIndex;
              return ListTile(
                key: ValueKey('${song.id}_$i'),
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
                        onTap: () => player.removeFromQueue(i),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.close_rounded, color: AurumTheme.textMuted, size: 18),
                        ),
                      ),
                    const Icon(Icons.drag_handle_rounded, color: AurumTheme.textMuted, size: 20),
                  ],
                ),
                onTap: () => player.skipToIndex(i),
              );
            },
          );
        },
      ),
    );
  }
}
