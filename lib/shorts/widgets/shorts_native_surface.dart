import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Embeds the native SurfaceView that AurumShortsEngine (Kotlin) renders
/// ExoPlayer's decoded video into directly. Replaces the old
/// VideoPlayer(controller) widget — there is no Dart-side video texture
/// or controller anymore; this is a pure passthrough to native.
///
/// Uses AndroidView (TextureView-backed platform view *hosting*), but the
/// actual pixel path inside native is a real SurfaceView — Flutter's
/// AndroidView is just the embedding mechanism to place native views in
/// the widget tree, not the render path. The engine's SurfaceHolder
/// callback (see AurumShortsSurfaceView.kt) attaches directly to
/// ExoPlayer, so decoded frames never cross back into Flutter's own
/// compositor.
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
