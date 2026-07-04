package com.aurum.music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Home-screen widget for Aurum — two sizes (compact "now playing" strip,
 * and a full version with prev/play-pause/next transport controls),
 * matching the widget picker's small/large tile conventions shown in
 * Android's own "Add widget" sheet.
 *
 * Reads state directly from [AurumMediaSessionService.sharedEngine]'s
 * ExoPlayer — the SAME player instance the in-app UI, lock screen, and
 * Bluetooth/Android Auto controls all already observe (see
 * AurumMediaSessionService.kt). This widget does not go through Flutter
 * or any MethodChannel at all: button taps here fire broadcast intents
 * straight back to this same provider, which calls the player directly.
 * That means widget controls keep working even if the Flutter engine/
 * Activity isn't currently running, exactly like the lock-screen
 * notification already does.
 */
class AurumWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "AurumWidget"

        const val ACTION_PLAY_PAUSE = "com.aurum.music.widget.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.aurum.music.widget.ACTION_NEXT"
        const val ACTION_PREV = "com.aurum.music.widget.ACTION_PREV"
        const val ACTION_REFRESH = "com.aurum.music.widget.ACTION_REFRESH"

        // Small in-process cache so rapid consecutive refreshes (several
        // player events firing in quick succession during a track change)
        // don't each independently re-download + re-blur the same
        // artwork URL — only the URL actually changing triggers new work.
        private var lastArtworkUrl: String? = null
        private var lastBlurredBitmap: Bitmap? = null
        private var lastThumbBitmap: Bitmap? = null

        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        /**
         * Public entry point called from AurumMediaSessionService whenever
         * the player's metadata/play-state changes, and once right after
         * the session is created so widgets don't sit on stale "Tap to
         * play something" text if a song was already playing when the
         * widget was added.
         */
        fun refreshAll(context: Context) {
            val appContext = context.applicationContext
            val manager = AppWidgetManager.getInstance(appContext)

            val compactIds = manager.getAppWidgetIds(
                ComponentName(appContext, AurumWidgetProvider::class.java)
            )
            if (compactIds.isNotEmpty()) {
                updateWidgets(appContext, manager, compactIds, isCompact = true)
            }

            val fullIds = manager.getAppWidgetIds(
                ComponentName(appContext, AurumWidgetProviderFull::class.java)
            )
            if (fullIds.isNotEmpty()) {
                updateWidgets(appContext, manager, fullIds, isCompact = false)
            }
        }

        internal fun updateWidgets(
            context: Context,
            manager: AppWidgetManager,
            ids: IntArray,
            isCompact: Boolean,
        ) {
            val engine = AurumMediaSessionService.sharedEngine
            val player = engine?.player

            for (id in ids) {
                val views = RemoteViews(
                    context.packageName,
                    if (isCompact) R.layout.widget_compact else R.layout.widget_full
                )

                val metadata = player?.mediaMetadata
                val title = metadata?.title?.toString()
                val artist = metadata?.artist?.toString()
                val hasSong = player != null && player.mediaItemCount > 0 && !title.isNullOrEmpty()
                val isPlaying = player?.isPlaying == true

                views.setTextViewText(
                    R.id.widget_title,
                    if (hasSong) title else "Aurum"
                )
                views.setTextViewText(
                    R.id.widget_artist,
                    if (hasSong) (artist ?: "") else "Tap to play something"
                )
                views.setImageViewResource(
                    R.id.widget_play_pause,
                    if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
                )

                wirePendingIntents(context, views, isCompact)

                // Artwork: fire an async load+blur pass, but paint
                // whatever we already have cached immediately so the
                // widget never flashes blank while that finishes.
                val artworkUri = metadata?.artworkUri?.toString()
                if (artworkUri != null && artworkUri == lastArtworkUrl && lastBlurredBitmap != null) {
                    views.setImageViewBitmap(R.id.widget_bg_image, lastBlurredBitmap)
                    views.setImageViewBitmap(R.id.widget_artwork_thumb, lastThumbBitmap)
                    manager.updateAppWidget(id, views)
                } else if (artworkUri.isNullOrEmpty()) {
                    views.setImageViewResource(R.id.widget_bg_image, R.drawable.widget_background_fallback)
                    views.setImageViewResource(R.id.widget_artwork_thumb, R.drawable.widget_thumb_mask)
                    manager.updateAppWidget(id, views)
                } else {
                    // Push the text/controls now; artwork follows async.
                    manager.updateAppWidget(id, views)
                    loadAndApplyArtwork(context, manager, id, isCompact, artworkUri)
                }
            }
        }

        private fun wirePendingIntents(context: Context, views: RemoteViews, isCompact: Boolean) {
            // Opening the app: tap on artwork thumb or the text column.
            val openAppIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP) }
            val openAppPending = PendingIntent.getActivity(
                context, 100, openAppIntent ?: Intent(),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root_tap, openAppPending)

            views.setOnClickPendingIntent(
                R.id.widget_play_pause,
                actionPendingIntent(context, ACTION_PLAY_PAUSE, 101),
            )
            if (!isCompact) {
                views.setOnClickPendingIntent(
                    R.id.widget_next,
                    actionPendingIntent(context, ACTION_NEXT, 102),
                )
                views.setOnClickPendingIntent(
                    R.id.widget_prev,
                    actionPendingIntent(context, ACTION_PREV, 103),
                )
            }
        }

        private fun actionPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
            val intent = Intent(context, AurumWidgetProvider::class.java).apply { this.action = action }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun loadAndApplyArtwork(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            isCompact: Boolean,
            url: String,
        ) {
            scope.launch {
                try {
                    val original = withContext(Dispatchers.IO) { downloadBitmap(url) } ?: return@launch
                    val blurred = withContext(Dispatchers.Default) { blur(context, original, radius = 30f) }
                    val thumb = withContext(Dispatchers.Default) {
                        roundedCrop(original, sizePx = 200, cornerRadiusPx = 28f)
                    }

                    lastArtworkUrl = url
                    lastBlurredBitmap = blurred
                    lastThumbBitmap = thumb

                    val views = RemoteViews(
                        context.packageName,
                        if (isCompact) R.layout.widget_compact else R.layout.widget_full
                    )
                    // Re-wire text/controls/intents too — updateAppWidget
                    // replaces the whole RemoteViews tree for this id, not
                    // a partial patch, so a bitmap-only views object here
                    // would otherwise blank the text back to defaults.
                    val engine = AurumMediaSessionService.sharedEngine
                    val player = engine?.player
                    val metadata = player?.mediaMetadata
                    val hasSong = player != null && player.mediaItemCount > 0 && !metadata?.title?.toString().isNullOrEmpty()
                    views.setTextViewText(R.id.widget_title, if (hasSong) metadata?.title?.toString() else "Aurum")
                    views.setTextViewText(
                        R.id.widget_artist,
                        if (hasSong) (metadata?.artist?.toString() ?: "") else "Tap to play something"
                    )
                    views.setImageViewResource(
                        R.id.widget_play_pause,
                        if (player?.isPlaying == true) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
                    )
                    wirePendingIntents(context, views, isCompact)
                    views.setImageViewBitmap(R.id.widget_bg_image, blurred)
                    views.setImageViewBitmap(R.id.widget_artwork_thumb, thumb)
                    manager.updateAppWidget(widgetId, views)
                } catch (e: Exception) {
                    Log.w(TAG, "Artwork load/blur failed for $url: ${e.message}")
                }
            }
        }

        private fun downloadBitmap(urlString: String): Bitmap? {
            return try {
                val connection = URL(urlString).openConnection() as HttpURLConnection
                connection.connectTimeout = 6000
                connection.readTimeout = 6000
                connection.doInput = true
                connection.connect()
                connection.inputStream.use { stream ->
                    // Downsample — the widget never needs full-resolution
                    // artwork, and decoding at full size just to blur/
                    // shrink it afterward wastes memory on low-RAM devices.
                    val opts = BitmapFactory.Options().apply { inSampleSize = 2 }
                    BitmapFactory.decodeStream(stream, null, opts)
                }
            } catch (e: Exception) {
                Log.w(TAG, "downloadBitmap failed: ${e.message}")
                null
            }
        }

        /**
         * Blur used for the widget's full-bleed background. Uses the
         * hardware RenderEffect blur on Android 12+ (cheap, GPU-backed —
         * same class of API the in-app UI's own ImageFiltered blur uses
         * on the Flutter/Skia side); falls back to a fast software box
         * blur on older API levels where RenderEffect doesn't exist.
         */
        private fun blur(context: Context, source: Bitmap, radius: Float): Bitmap {
            // Downscale before blurring — blurring at full widget-bitmap
            // resolution is unnecessary (the blur destroys detail anyway)
            // and meaningfully slower on the CPU fallback path.
            val scaled = Bitmap.createScaledBitmap(source, 120, 120, true)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                return try {
                    blurWithRenderEffect(scaled, radius)
                } catch (e: Exception) {
                    Log.w(TAG, "RenderEffect blur failed, falling back: ${e.message}")
                    boxBlur(scaled, radius.toInt().coerceIn(1, 25))
                }
            }
            return boxBlur(scaled, radius.toInt().coerceIn(1, 25))
        }

        /**
         * RenderEffect only operates on live Views/RenderNodes, not plain
         * Bitmaps directly — so we draw the source into an
         * android.graphics.RenderNode, attach the blur RenderEffect to
         * it, and read the result back out via a HardwareRenderer into a
         * new Bitmap. This is the standard documented pattern for
         * "blur an existing bitmap" on API 31+ without a live UI hierarchy.
         */
        private fun blurWithRenderEffect(source: Bitmap, radius: Float): Bitmap {
            val renderNode = android.graphics.RenderNode("blur")
            val hardwareRenderer = android.graphics.HardwareRenderer()
            hardwareRenderer.setContentRoot(renderNode)
            val bufferWidth = source.width.coerceAtLeast(1)
            val bufferHeight = source.height.coerceAtLeast(1)
            renderNode.setPosition(0, 0, bufferWidth, bufferHeight)

            val recordingCanvas = renderNode.beginRecording()
            recordingCanvas.drawBitmap(source, 0f, 0f, null)
            renderNode.endRecording()
            renderNode.setRenderEffect(
                RenderEffect.createBlurEffect(radius, radius, Shader.TileMode.CLAMP)
            )

            val imageReader = android.media.ImageReader.newInstance(
                bufferWidth, bufferHeight, android.graphics.PixelFormat.RGBA_8888, 1,
            )
            hardwareRenderer.setSurface(imageReader.surface)
            val renderRequest = hardwareRenderer.createRenderRequest()
            renderRequest.setWaitForPresent(true)
            renderRequest.syncAndDraw()

            val image = imageReader.acquireNextImage()
            val plane = image.planes[0]
            val bitmap = Bitmap.createBitmap(
                bufferWidth + (plane.rowStride - plane.pixelStride * bufferWidth) / plane.pixelStride,
                bufferHeight, Bitmap.Config.ARGB_8888,
            )
            bitmap.copyPixelsFromBuffer(plane.buffer)

            image.close()
            imageReader.close()
            hardwareRenderer.destroy()
            renderNode.discardDisplayList()

            return if (bitmap.width != bufferWidth) {
                Bitmap.createBitmap(bitmap, 0, 0, bufferWidth, bufferHeight)
            } else {
                bitmap
            }
        }

        /** Simple, dependency-free box blur fallback for API < 31. */
        private fun boxBlur(source: Bitmap, radius: Int): Bitmap {
            if (radius <= 0) return source
            val w = source.width
            val h = source.height
            val pixels = IntArray(w * h)
            source.getPixels(pixels, 0, w, 0, 0, w, h)

            fun blurPass(horizontal: Boolean) {
                val out = IntArray(pixels.size)
                val lineLen = if (horizontal) w else h
                val lines = if (horizontal) h else w
                for (line in 0 until lines) {
                    for (pos in 0 until lineLen) {
                        var r = 0; var g = 0; var b = 0; var a = 0; var count = 0
                        for (k in -radius..radius) {
                            val p = pos + k
                            if (p < 0 || p >= lineLen) continue
                            val idx = if (horizontal) line * w + p else p * w + line
                            val px = pixels[idx]
                            a += (px shr 24) and 0xFF
                            r += (px shr 16) and 0xFF
                            g += (px shr 8) and 0xFF
                            b += px and 0xFF
                            count++
                        }
                        val outIdx = if (horizontal) line * w + pos else pos * w + line
                        out[outIdx] = ((a / count) shl 24) or ((r / count) shl 16) or ((g / count) shl 8) or (b / count)
                    }
                }
                System.arraycopy(out, 0, pixels, 0, pixels.size)
            }

            blurPass(horizontal = true)
            blurPass(horizontal = false)

            return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
        }

        /** Center-crops to a square and rounds the corners — used for the
         *  small artwork thumbnail (RemoteViews ImageView can't clip its
         *  own content to a background shape, so rounding has to be baked
         *  into the bitmap itself). */
        private fun roundedCrop(source: Bitmap, sizePx: Int, cornerRadiusPx: Float): Bitmap {
            val squareSize = minOf(source.width, source.height)
            val x = (source.width - squareSize) / 2
            val y = (source.height - squareSize) / 2
            val square = Bitmap.createBitmap(source, x, y, squareSize, squareSize)
            val scaled = Bitmap.createScaledBitmap(square, sizePx, sizePx, true)

            val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val rect = Rect(0, 0, sizePx, sizePx)
            val rectF = RectF(rect)

            canvas.drawARGB(0, 0, 0, 0)
            canvas.drawRoundRect(rectF, cornerRadiusPx, cornerRadiusPx, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(scaled, rect, rect, paint)

            return output
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val isCompact = this !is AurumWidgetProviderFull
        updateWidgets(context, appWidgetManager, appWidgetIds, isCompact)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val engine = AurumMediaSessionService.sharedEngine
        val player = engine?.player

        when (intent.action) {
            ACTION_PLAY_PAUSE -> {
                if (engine == null || player == null) return
                if (player.isPlaying) engine.pause() else engine.play()
                refreshAll(context)
            }
            ACTION_NEXT -> {
                // Routed through the engine's own skipToNext() (not a raw
                // player.seekToNext() call) — it's mutex-guarded against
                // the exact rapid-tap race condition documented at the
                // top of AurumAudioEngine.kt, and it correctly handles
                // queue-boundary/repeat-mode cases a bare seek wouldn't.
                engine?.skipToNext()
            }
            ACTION_PREV -> {
                engine?.skipToPrevious()
            }
            ACTION_REFRESH -> refreshAll(context)
        }
    }
}

/**
 * Second provider class for the full/large widget. Android ties each
 * <receiver> in the manifest (and therefore each distinct widget-info
 * XML/layout pairing shown in the OS widget picker) to its own concrete
 * class — a single AppWidgetProvider can't serve two differently-sized,
 * independently-placeable widgets. This subclass carries no logic of its
 * own; it only exists so AndroidManifest.xml can point a second
 * <receiver>/<meta-data> pair at "the full-size variant" while every
 * actual update/click code path above stays shared and unduplicated.
 */
class AurumWidgetProviderFull : AurumWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        AurumWidgetProvider.updateWidgets(context, appWidgetManager, appWidgetIds, isCompact = false)
    }
}
