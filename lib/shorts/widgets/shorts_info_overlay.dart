import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../theme/aurum_theme.dart';
import '../models/short_item.dart';
import 'shorts_waveform_bar.dart';

/// Bottom-anchored info block for a Shorts card: small artwork,
/// title/artist, animated progress bar with gradient fade backdrop.
class ShortsInfoOverlay extends StatelessWidget {
  final ShortItem item;
  final Duration position;
  final Duration duration;

  const ShortsInfoOverlay({
    super.key,
    required this.item,
    required this.position,
    required this.duration,
  });

  @override
  Widget build(BuildContext context) {
    final double progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
          stops: [0.0, 0.75],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(18, 40, 90, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: item.artworkUrl,
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 42,
                    height: 42,
                    color: Colors.white10,
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 42,
                    height: 42,
                    color: Colors.white10,
                    child: const Icon(Icons.music_note,
                        color: Colors.white38, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ShortsWaveformBar(
            progress: progress,
            seed: item.id,
          ),
        ],
      ),
    );
  }
}
