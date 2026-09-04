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
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.util.Log
import android.widget.RemoteViews
import androidx.palette.graphics.Palette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Home-screen widget for Aurum — two sizes (compact "now playing" strip,
 * and a full version with prev/play-pause/next transport controls).
 *
 * ARTWORK: only a small rounded THUMBNAIL is loaded — no blurred
 * background bitmap, no HardwareRenderer/RenderEffect (that combo was
 * the confirmed root cause of the earlier "An error occurred when
 * loading widget" crash: RemoteViews only supports a fixed allowlist
 * of view classes, and this widget previously also used a bare <View>
 * tag, which isn't on that allowlist — that was the actual bug, fixed
 * by switching to FrameLayout/LinearLayout containers instead).
 * The thumbnail path here is deliberately minimal: one small bitmap,
 * one simple rounded-rect crop, Throwable-guarded end to end, with a
 * static placeholder shown immediately and swapped only on success.
 */
open class AurumWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "AurumWidget"

        const val ACTION_PLAY_PAUSE = "com.aurum.music.widget.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.aurum.music.widget.ACTION_NEXT"
        const val ACTION_PREV = "com.aurum.music.widget.ACTION_PREV"
        const val ACTION_REFRESH = "com.aurum.music.widget.ACTION_REFRESH"

        private var lastArtworkUrl: String? = null
        private var lastThumbBitmap: Bitmap? = null
        // Dynamic-background color computed from the current artwork.
        // Cached alongside lastThumbBitmap/lastArtworkUrl (same lifetime,
        // same invalidation point) so a widget resize/reconfigure that
        // re-renders without a song change reapplies the same tint
        // instead of momentarily flashing back to the static fallback.
        private var lastBgColor: Int? = null

        /**
         * Called from AurumMediaSessionService.onDestroy() so that once
         * playback/the session is gone, the widget doesn't keep showing
         * a stale cached thumbnail from whatever song was last playing —
         * it should fall back to the plain "Aurum / Tap to play
         * something" state, same as a fresh app install.
         */
        fun clearArtworkCache() {
            lastArtworkUrl = null
            // LOW-END DEVICE FIX: same reasoning as loadAndApplyThumbnail's
            // replacement path — recycle before dropping the reference so
            // the native bitmap memory is freed immediately.
            lastThumbBitmap?.let { if (!it.isRecycled) it.recycle() }
            lastThumbBitmap = null
            lastBgColor = null
        }

        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        fun refreshAll(context: Context) {
            try {
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
            } catch (e: Throwable) {
                Log.e(TAG, "refreshAll crashed: ${e.message}", e)
            }
        }

        internal fun updateWidgets(
            context: Context,
            manager: AppWidgetManager,
            ids: IntArray,
            isCompact: Boolean,
        ) {
            for (id in ids) {
                try {
                    updateSingleWidget(context, manager, id, isCompact)
                } catch (e: Throwable) {
                    Log.e(TAG, "updateSingleWidget failed for id=$id: ${e.message}", e)
                    try {
                        val safeViews = RemoteViews(
                            context.packageName,
                            if (isCompact) R.layout.widget_compact else R.layout.widget_full
                        )
                        safeViews.setTextViewText(R.id.widget_title, "Aurum")
                        safeViews.setTextViewText(R.id.widget_artist, "Tap to open")
                        safeViews.setImageViewResource(R.id.widget_play_pause, R.drawable.ic_widget_play)
                        manager.updateAppWidget(id, safeViews)
                    } catch (fatal: Throwable) {
                        Log.e(TAG, "Fallback render also failed for id=$id: ${fatal.message}", fatal)
                    }
                }
            }
        }

        private fun updateSingleWidget(
            context: Context,
            manager: AppWidgetManager,
            id: Int,
            isCompact: Boolean,
        ) {
            val engine = AurumMediaSessionService.sharedEngine
            val player = engine?.player

            val views = RemoteViews(
                context.packageName,
                if (isCompact) R.layout.widget_compact else R.layout.widget_full
            )

            val metadata = player?.mediaMetadata
            val title = metadata?.title?.toString()
            val artist = metadata?.artist?.toString()
            val hasSong = player != null && player.mediaItemCount > 0 && !title.isNullOrEmpty()
            val isPlaying = player?.isPlaying == true

            views.setTextViewText(R.id.widget_title, if (hasSong) title else "Aurum")
            views.setTextViewText(
                R.id.widget_artist,
                if (hasSong) (artist ?: "") else "Tap to play something"
            )
            views.setImageViewResource(
                R.id.widget_play_pause,
                if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
            )

            wirePendingIntents(context, views)

            val artworkUri = metadata?.artworkUri?.toString()
            if (artworkUri != null && artworkUri == lastArtworkUrl && lastThumbBitmap != null) {
                views.setImageViewBitmap(R.id.widget_artwork_thumb, lastThumbBitmap)
                applyDynamicBackground(views, lastBgColor)
                manager.updateAppWidget(id, views)
            } else {
                // Song/artwork changed (or there's no cached bitmap yet) —
                // explicitly clear the thumbnail back to the placeholder
                // drawable right now. Without this, the ImageView keeps
                // showing whatever bitmap the widget host already had
                // for it (the PREVIOUS song's artwork) until the new
                // download finishes, which is exactly the "thumbnail
                // doesn't change with the song" bug. Dynamic background
                // gets the same treatment for the same reason — otherwise
                // the OLD song's color would sit behind the NEW song's
                // title/artist text until the new artwork's palette
                // finishes computing.
                views.setImageViewResource(R.id.widget_artwork_thumb, R.drawable.widget_thumb_mask)
                applyDynamicBackground(views, null)
                manager.updateAppWidget(id, views)
                if (!artworkUri.isNullOrEmpty()) {
                    loadAndApplyThumbnail(context, manager, id, isCompact, artworkUri)
                }
            }
        }

        private fun wirePendingIntents(context: Context, views: RemoteViews) {
            try {
                val openAppIntent = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)
                    ?.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP) }
                if (openAppIntent != null) {
                    val openAppPending = PendingIntent.getActivity(
                        context, 100, openAppIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    views.setOnClickPendingIntent(R.id.widget_root_tap, openAppPending)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "openApp PendingIntent failed: ${e.message}")
            }

            views.setOnClickPendingIntent(
                R.id.widget_play_pause,
                actionPendingIntent(context, ACTION_PLAY_PAUSE, 101),
            )
            views.setOnClickPendingIntent(
                R.id.widget_next,
                actionPendingIntent(context, ACTION_NEXT, 102),
            )
            views.setOnClickPendingIntent(
                R.id.widget_prev,
                actionPendingIntent(context, ACTION_PREV, 103),
            )
        }

        private fun actionPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
            val intent = Intent(context, AurumWidgetProvider::class.java).apply { this.action = action }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun loadAndApplyThumbnail(
            context: Context,
            manager: AppWidgetManager,
            widgetId: Int,
            isCompact: Boolean,
            url: String,
        ) {
            scope.launch {
                try {
                    val original = withContext(Dispatchers.IO) { downloadBitmap(url) } ?: return@launch
                    val thumb = withContext(Dispatchers.Default) {
                        roundedCrop(original, sizePx = 160, cornerRadiusPx = 22f)
                    }
                    // Palette runs on the SAME downloaded bitmap, before it's
                    // recycled below — no second network fetch or decode.
                    // Already off the main thread (this whole block runs
                    // inside withContext(Dispatchers.Default)/IO via the
                    // launch above), and Palette.Builder.generate() (sync,
                    // no listener) is itself just pixel math over a bitmap
                    // already this small (inSampleSize=8'd in downloadBitmap),
                    // so it's cheap enough to run inline here.
                    val bgColor = withContext(Dispatchers.Default) {
                        extractDominantColor(original)
                    }
                    // LOW-END DEVICE FIX (2GB RAM target): `original` is
                    // fully consumed by roundedCrop() by this point (it
                    // only reads from it to build `square`/`scaled`
                    // above) — recycling it here frees its native pixel
                    // memory immediately rather than waiting for GC,
                    // matching the same fix applied inside roundedCrop
                    // for its own intermediates.
                    original.recycle()
                    if (thumb == null) return@launch

                    // The bitmap this field held until now is about to be
                    // replaced and dropped — recycle it before overwriting
                    // so its native memory is freed immediately instead of
                    // leaking for the rest of the app process's lifetime.
                    // This field survives across every widget refresh for
                    // as long as the app process lives, so a leak here
                    // compounds continuously over a long session — exactly
                    // the "gets laggier the longer you use it" symptom.
                    lastThumbBitmap?.let { if (!it.isRecycled) it.recycle() }
                    lastArtworkUrl = url
                    lastThumbBitmap = thumb
                    lastBgColor = bgColor

                    val views = RemoteViews(
                        context.packageName,
                        if (isCompact) R.layout.widget_compact else R.layout.widget_full
                    )
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
                    wirePendingIntents(context, views)
                    views.setImageViewBitmap(R.id.widget_artwork_thumb, thumb)
                    applyDynamicBackground(views, bgColor)
                    manager.updateAppWidget(widgetId, views)
                } catch (e: Throwable) {
                    Log.w(TAG, "Thumbnail load failed for $url: ${e.message}")
                }
            }
        }

        /**
         * Runs Palette over the already-downloaded artwork bitmap and picks
         * one representative color to tint the widget background with.
         *
         * Vibrant-first, falling back through muted/dominant swatches:
         * Palette's "dominant" swatch is literally the most common pixel
         * color, which for album art is very often a near-black or
         * near-white border/letterboxing — visually correct but useless as
         * a background tint (everything would end up near-black). Vibrant
         * (then LightVibrant/Muted/DarkMuted) approximates what Spotify/
         * Apple Music actually show: a color that's clearly FROM the
         * artwork without just being "whatever pixel there's most of".
         * Falls back to null (caller keeps the static gradient) only if
         * Palette finds nothing usable at all — a valid outcome for very
         * flat/monochrome art, not an error.
         */
        private fun extractDominantColor(bitmap: Bitmap): Int? {
            return try {
                val palette = Palette.Builder(bitmap).maximumColorCount(16).generate()
                val swatch = palette.vibrantSwatch
                    ?: palette.lightVibrantSwatch
                    ?: palette.mutedSwatch
                    ?: palette.darkVibrantSwatch
                    ?: palette.dominantSwatch
                swatch?.rgb
            } catch (e: Throwable) {
                Log.w(TAG, "extractDominantColor failed: ${e.message}")
                null
            }
        }

        /**
         * Applies (or clears) the artwork-derived tint on widget_dynamic_bg.
         *
         * Darkened the same way the in-app "now playing stage" backdrop
         * treats its extracted color — text/controls sit directly on this
         * background with no separate scrim layer here, so it has to stay
         * dark enough for white text at full opacity to read clearly
         * regardless of which swatch Palette picked.
         */
        private fun applyDynamicBackground(views: RemoteViews, color: Int?) {
            if (color == null) {
                views.setImageViewResource(R.id.widget_dynamic_bg, 0)
                return
            }
            val darkened = darkenForBackground(color)
            views.setImageViewBitmap(R.id.widget_dynamic_bg, solidRoundedBitmap(darkened))
        }

        /**
         * Scales channels toward black rather than alpha-blending over a
         * fixed color, so the hue survives (a blend would pull every color
         * toward the same grey) while staying legible under white text —
         * same approach as the in-app dynamic-backdrop darkening.
         */
        private fun darkenForBackground(color: Int, factor: Float = 0.55f): Int {
            val r = (Color.red(color) * factor).toInt().coerceIn(0, 255)
            val g = (Color.green(color) * factor).toInt().coerceIn(0, 255)
            val b = (Color.blue(color) * factor).toInt().coerceIn(0, 255)
            return Color.rgb(r, g, b)
        }

        /**
         * A single solid-color bitmap, rounded to match widget_gradient_card/
         * widget_background_fallback's own corner radius so the tint doesn't
         * show square corners poking out from behind the rounded card.
         *
         * Deliberately tiny (48x48, scaled up by the ImageView) — this is a
         * flat fill, not a photo, so there's no detail lost by not matching
         * the widget's actual pixel size, and it keeps this bitmap far under
         * the RemoteViews per-update memory budget alongside the artwork
         * thumbnail (see loadBitmap's note on the ~20MB cap).
         */
        private fun solidRoundedBitmap(color: Int, sizePx: Int = 48, cornerRadiusPx: Float = 22f): Bitmap {
            val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
            val rectF = RectF(0f, 0f, sizePx.toFloat(), sizePx.toFloat())
            canvas.drawRoundRect(rectF, cornerRadiusPx, cornerRadiusPx, paint)
            return output
        }

        private fun downloadBitmap(urlString: String): Bitmap? {
            return try {
                val connection = URL(urlString).openConnection() as HttpURLConnection
                connection.connectTimeout = 3000
                connection.readTimeout = 3000
                connection.doInput = true
                connection.connect()
                connection.inputStream.use { stream ->
                    val opts = BitmapFactory.Options().apply { inSampleSize = 8 }
                    BitmapFactory.decodeStream(stream, null, opts)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "downloadBitmap failed: ${e.message}")
                null
            }
        }

        private fun roundedCrop(source: Bitmap, sizePx: Int, cornerRadiusPx: Float): Bitmap? {
            // LOW-END DEVICE FIX (2GB RAM target — "app gets laggier the
            // longer you use it"): `square` and `scaled` were intermediate
            // bitmaps, dead the moment `output` is drawn from them below,
            // but were never recycled — left for the GC to eventually
            // reclaim on its own schedule instead of freeing the native
            // bitmap memory immediately. This function runs on every home-
            // screen widget artwork refresh for the life of the app
            // process; on a memory-constrained device those un-recycled
            // intermediates accumulate pressure that shows up as
            // increasing GC pause frequency/duration over a long session —
            // exactly the "smoothness degrades over time" symptom. Bitmap
            // objects created via createBitmap/createScaledBitmap own real
            // native (non-Dalvik-heap) pixel memory that .recycle() frees
            // deterministically and immediately, rather than waiting on
            // GC. `square` is only skipped if it's literally the same
            // object as `source` (createBitmap can return the input
            // unchanged when x=0,y=0 and the requested region already
            // matches the source's full size) — recycling it in that case
            // would recycle the caller's bitmap out from under them.
            return try {
                val squareSize = minOf(source.width, source.height)
                val x = (source.width - squareSize) / 2
                val y = (source.height - squareSize) / 2
                val square = Bitmap.createBitmap(source, x, y, squareSize, squareSize)
                val scaled = Bitmap.createScaledBitmap(square, sizePx, sizePx, true)
                if (square !== source && square !== scaled) square.recycle()

                val output = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(output)
                val paint = Paint(Paint.ANTI_ALIAS_FLAG)
                val rect = Rect(0, 0, sizePx, sizePx)
                val rectF = RectF(rect)

                canvas.drawARGB(0, 0, 0, 0)
                canvas.drawRoundRect(rectF, cornerRadiusPx, cornerRadiusPx, paint)
                paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
                canvas.drawBitmap(scaled, rect, rect, paint)
                if (scaled !== output) scaled.recycle()

                output
            } catch (e: Throwable) {
                Log.w(TAG, "roundedCrop failed: ${e.message}")
                null
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try {
            val isCompact = this !is AurumWidgetProviderFull
            updateWidgets(context, appWidgetManager, appWidgetIds, isCompact)
        } catch (e: Throwable) {
            Log.e(TAG, "onUpdate crashed: ${e.message}", e)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        try {
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
                    engine?.skipToNext()
                }
                ACTION_PREV -> {
                    engine?.skipToPrevious()
                }
                ACTION_REFRESH -> refreshAll(context)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "onReceive crashed for action=${intent.action}: ${e.message}", e)
        }
    }
}

class AurumWidgetProviderFull : AurumWidgetProvider() {
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try {
            AurumWidgetProvider.updateWidgets(context, appWidgetManager, appWidgetIds, isCompact = false)
        } catch (e: Throwable) {
            Log.e("AurumWidget", "Full onUpdate crashed: ${e.message}", e)
        }
    }
}
