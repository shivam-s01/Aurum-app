import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/aurum_theme.dart';

class AurumArtwork extends StatelessWidget {
  final String url;
  final double size;
  final double borderRadius;
  final String? localSongId;

  const AurumArtwork({
    super.key,
    required this.url,
    required this.size,
    this.borderRadius = 8,
    this.localSongId,
  });

  @override
  Widget build(BuildContext context) {
    if (localSongId != null) {
      if (url.startsWith('content://')) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image(
            image: ResizeImage(
              NetworkImage(url),
              width: size.toInt(),
              height: size.toInt(),
            ),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(context),
          ),
        );
      }
      if (url.isNotEmpty) {
        final file = File(url);
        if (file.existsSync()) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: Image.file(
              file,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(context),
            ),
          );
        }
      }
      return _placeholder(context);
    }

    if (url.isEmpty) return _placeholder(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, __) => _shimmer(context),
        errorWidget: (_, __, ___) => _placeholder(context),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Icon(
          Icons.music_note_rounded,
          color: AurumTheme.textMutedOf(context),
          size: size * 0.4,
        ),
      );

  Widget _shimmer(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AurumTheme.bgSurfaceOf(context),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      );
}
