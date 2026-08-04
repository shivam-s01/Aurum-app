import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/aurum_theme.dart';
import '../widgets/aurum_artwork.dart';
import '../widgets/aurum_empty_state.dart';
import '../widgets/aurum_pressable.dart';
import '../l10n/generated/app_localizations.dart';
import '../utils/aurum_haptics.dart';

class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AurumTheme.bg,
      appBar: AppBar(
        backgroundColor: AurumTheme.bg,
        title: ShaderMask(
          shaderCallback: (b) => AurumTheme.goldGradient.createShader(b),
          child: Text(
            l10n.queueTitle,
            style: const TextStyle(
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
            AurumHaptics.selection();
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
            return AurumEmptyState(
              icon: Icons.queue_music_rounded,
              title: l10n.queueEmpty,
              subtitle: l10n.queueEmptySubtitle,
            );
          }

          return ReorderableListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: queue.length,
            // FIX ("drag sirf white line dikhata hai, actual reorder nahi
            // hota"): ReorderableListView's default behavior makes the
            // WHOLE row a long-press drag trigger. Every row here also has
            // its own tap (skipToIndex) and a close/remove button wrapped
            // in AurumPressable's own GestureDetector — those compete with
            // the reorder long-press recognizer in the same gesture arena,
            // so a drag starting anywhere on the row was actually
            // ambiguous between "tap this song" and "start reordering",
            // and mostly lost to the tap recognizer. All that visibly
            // reached the user was Material's brief lift/elevation shadow
            // (looks like a thin white line) as the drag recognizer won
            // for an instant before losing the arena — never a real,
            // completed drag. buildDefaultDragHandles: false turns off
            // that whole-row trigger; ReorderableDragStartListener below
            // wraps ONLY the drag_handle icon as the trigger instead —
            // same YouTube Music / Spotify pattern (drag only from the
            // handle, tap/swipe anywhere else on the row behaves
            // normally, no gesture-arena conflict is possible since only
            // one recognizer now ever claims the handle's own touch area).
            buildDefaultDragHandles: false,
            onReorder: (from, to) {
              AurumHaptics.medium();
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
                  AurumHaptics.selection();
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
                          AurumHaptics.light();
                          player.removeFromQueue(i);
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.close_rounded, color: AurumTheme.textMuted, size: 18),
                        ),
                      ),
                    ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_handle_rounded, color: AurumTheme.textMuted, size: 20),
                      ),
                    ),
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
