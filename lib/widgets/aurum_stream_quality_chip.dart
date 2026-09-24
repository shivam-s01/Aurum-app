import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/stream_quality_store.dart';
import 'aurum_equalizer_bars.dart';

/// Center pill under the seek bar: live equalizer wave + the codec of the
/// current song (OPUS / AAC / MP3 / VORBIS). If the codec can't be
/// determined, the original "Astra" label is shown instead. The wave
/// animates only while audio is actually playing.
class AurumStreamQualityChip extends StatelessWidget {
  const AurumStreamQualityChip({super.key, required this.player});
  final PlayerProvider player;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, (String?, bool, bool)>(
      selector: (_, p) => (p.currentSong?.id, p.isPlaying, p.isLoading),
      builder: (context, data, _) {
        final (_, isPlaying, isLoading) = data;
        return AnimatedBuilder(
          animation: StreamQualityStore.instance,
          builder: (context, _) {
            final song = player.currentSong;
            final store = StreamQualityStore.instance;
            final codec = song == null ? null : store.codecFor(song);
            final label = codec ??
                ((song != null && store.showFallback(song)) ? 'Astra' : null);
            final base = Colors.white.withOpacity(0.85);

            return AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AurumEqualizerBars(
                      playing: isPlaying && !isLoading,
                      color: base,
                      size: 13,
                      barCount: 4,
                    ),
                    if (label != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: base,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
