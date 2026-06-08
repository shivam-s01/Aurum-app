import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/aurum_theme.dart';

class AurumArtwork extends StatelessWidget {
  final String? url;
  final double size;
  final double borderRadius;
  final bool showShadow;

  const AurumArtwork({
    super.key,
    this.url,
    this.size = 56,
    this.borderRadius = 8,
    this.showShadow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: AurumTheme.gold.withOpacity(0.3),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: url != null && url!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                placeholder: (_, __) => _shimmer(),
                errorWidget: (_, __, ___) => _placeholder(),
              )
            : _placeholder(),
      ),
    );
  }

  Widget _shimmer() => Shimmer.fromColors(
    baseColor: AurumTheme.bgCard,
    highlightColor: AurumTheme.bgSurface,
    child: Container(color: AurumTheme.bgCard),
  );

  Widget _placeholder() => Container(
    color: AurumTheme.bgCard,
    child: Icon(
      Icons.music_note_rounded,
      color: AurumTheme.gold.withOpacity(0.4),
      size: size * 0.4,
    ),
  );
}
