package com.aurum.music

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import io.flutter.plugin.platform.PlatformView

/**
 * SurfaceView wrapper embedded via PlatformView so ExoPlayer renders
 * directly into a real Android Surface — no TextureView copy step,
 * which is what makes this "max smoothness" versus the old
 * video_player plugin's TextureView-based rendering.
 *
 * Registered once per Shorts feed screen instance (see
 * AurumShortsViewFactory) and hands its Surface to
 * AurumShortsEngine.attachSurface() as soon as it's created, and
 * detaches (passes null) on destroy so ExoPlayer never holds a
 * reference to a torn-down Surface.
 */
class AurumShortsSurfaceView(
    context: Context,
    private val engine: AurumShortsEngine,
) : PlatformView, SurfaceHolder.Callback {

    private val surfaceView = SurfaceView(context)

    init {
        surfaceView.holder.addCallback(this)
    }

    override fun getView() = surfaceView

    override fun surfaceCreated(holder: SurfaceHolder) {
        engine.attachSurface(holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        // No-op: ExoPlayer adapts to the surface's actual size on its own.
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        engine.attachSurface(null)
    }

    override fun dispose() {
        surfaceView.holder.removeCallback(this)
    }
}
