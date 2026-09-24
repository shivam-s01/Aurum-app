import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../services/stream_quality_store.dart';

/// Center pill under the seek bar: a static hi-res/codec glyph + the codec
/// of the current song (OPUS / AAC / MP3 / VORBIS). If the codec can't be
/// determined, the original "Astra" label is shown instead.
///
/// Lightweight by design: StreamQualityStore.codecFor() is now a pure,
/// synchronous lookup (no network call, no polling, no retry timers — see
/// stream_quality_store.dart), so this widget only needs to rebuild when
/// the current song changes. No extra Listenable/AnimatedBuilder wiring.
class AurumStreamQualityChip extends StatelessWidget {
  const AurumStreamQualityChip({super.key, required this.player});
  final PlayerProvider player;

  @override
  Widget build(BuildContext context) {
    return Selector<PlayerProvider, String?>(
      selector: (_, p) => p.currentSong?.id,
      builder: (context, _, __) {
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  size: 14,
                  color: base,
                ),
                if (label != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: base,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
