package com.aurum.music

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import io.flutter.plugin.platform.PlatformView

/**
 * TextureView wrapper embedded via PlatformView so ExoPlayer renders
 * into a Surface backed by a SurfaceTexture.
 *
 * NOTE: this used to be a raw SurfaceView. Flutter's AndroidView hosts
 * platform views through a TextureView-backed composition path — nesting
 * an independent SurfaceView (which renders on its own separate hardware
 * layer/window, outside Flutter's normal compositor stack) inside that
 * causes exactly the symptoms we were seeing: the Surface being created
 * late or torn down/recreated on every swipe/relayout, so ExoPlayer would
 * randomly end up with no valid Surface to render or play audio into,
 * and frames would freeze. TextureView plays natively with how AndroidView
 * already composites, so surface lifecycle stays consistent.
 *
 * Registered once per Shorts feed screen instance (see
 * AurumShortsViewFactory) and hands its Surface to
 * AurumShortsEngine.attachSurface() as soon as it's available, and
 * detaches (passes null) on destroy so ExoPlayer never holds a
 * reference to a torn-down Surface.
 */
class AurumShortsSurfaceView(
    context: Context,
    private val engine: AurumShortsEngine,
) : PlatformView, TextureView.SurfaceTextureListener {

    private val textureView = TextureView(context)
    private var currentSurface: Surface? = null

    init {
        textureView.surfaceTextureListener = this
        textureView.isOpaque = false
    }

    override fun getView() = textureView

    override fun onSurfaceTextureAvailable(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        val surface = Surface(surfaceTexture)
        currentSurface = surface
        engine.attachSurface(surface)
    }

    override fun onSurfaceTextureSizeChanged(surfaceTexture: SurfaceTexture, width: Int, height: Int) {
        // No-op: ExoPlayer adapts to the surface's actual size on its own.
    }

    override fun onSurfaceTextureDestroyed(surfaceTexture: SurfaceTexture): Boolean {
        engine.attachSurface(null)
        currentSurface?.release()
        currentSurface = null
        // Returning true lets TextureView release the SurfaceTexture itself.
        return true
    }

    override fun onSurfaceTextureUpdated(surfaceTexture: SurfaceTexture) {
        // No-op: called on every new frame, nothing to do here.
    }

    override fun dispose() {
        textureView.surfaceTextureListener = null
        currentSurface?.release()
        currentSurface = null
    }
}
