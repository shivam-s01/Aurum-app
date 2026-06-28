import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_empty_state.dart';
import 'dart:ui';

class UpNextSheet extends StatelessWidget {
  final PlayerProvider player;
  const UpNextSheet({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    final queue = player.queue;
    final current = player.currentIndex;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, controller) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A).withOpacity(0.92),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: Colors.white.withOpacity(0.08)),
            ),
            child: Column(children: [
              const SizedBox(height: 10),
              Container(width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  const Text('Up Next', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  Text('${queue.length} songs', style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 13)),
                ]),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: queue.isEmpty
                    ? const AurumEmptyState(
                        icon: Icons.queue_music_rounded,
                        title: 'Queue is empty',
                        subtitle: 'Songs you play next will line up here',
                      )
                    : ListView.builder(
                        controller: controller,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: queue.length,
                        itemBuilder: (_, i) {
                          final s = queue[i];
                          final isCurrent = i == current;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            decoration: BoxDecoration(
                              color: isCurrent ? AurumTheme.gold.withOpacity(0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: isCurrent ? Border.all(color: AurumTheme.gold.withOpacity(0.3)) : null,
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              leading: AurumArtwork(
                                url: s.artworkUrl,
                                size: 48,
                                borderRadius: 10,
                              ),
                              title: Text(s.title,
                                  style: TextStyle(color: isCurrent ? AurumTheme.gold : Colors.white,
                                      fontSize: 14, fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(s.artist,
                                  style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: isCurrent
                                  ? const Icon(Icons.equalizer_rounded, color: AurumTheme.gold, size: 20)
                                  : Icon(Icons.drag_handle_rounded, color: Colors.white.withOpacity(0.2), size: 20),
                              onTap: () {
                                HapticFeedback.selectionClick();
                                Navigator.pop(context);
                                player.skipToIndex(i);
                              },
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
