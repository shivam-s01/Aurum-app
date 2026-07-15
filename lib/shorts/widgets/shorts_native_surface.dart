import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Embeds the native TextureView that AurumShortsEngine (Kotlin) renders
/// ExoPlayer's decoded video into directly. Replaces the old
/// VideoPlayer(controller) widget — there is no Dart-side video texture
/// or controller anymore; this is a pure passthrough to native.
///
/// Uses AndroidView, which hosts platform views via a TextureView-backed
/// composition path. The native side (see AurumShortsSurfaceView.kt) is
/// also a TextureView now — previously it was a raw SurfaceView, which
/// doesn't compose reliably when nested inside AndroidView (surface
/// created late / torn down on relayout, causing frozen frames and
/// silent audio failures on some devices). No change needed here; this
/// widget just hosts whatever native view the factory returns.
class ShortsNativeSurface extends StatelessWidget {
  const ShortsNativeSurface({super.key});

  static const _viewType = 'com.aurum.music/shorts_surface';

  @override
  Widget build(BuildContext context) {
    return const AndroidView(
      viewType: _viewType,
      creationParams: null,
      creationParamsCodec: StandardMessageCodec(),
    );
  }
}
