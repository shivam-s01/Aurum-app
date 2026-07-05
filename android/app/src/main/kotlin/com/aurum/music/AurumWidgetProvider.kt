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

        /**
         * Called from AurumMediaSessionService.onDestroy() so that once
         * playback/the session is gone, the widget doesn't keep showing
         * a stale cached thumbnail from whatever song was last playing —
         * it should fall back to the plain "Aurum / Tap to play
         * something" state, same as a fresh app install.
         */
        fun clearArtworkCache() {
            lastArtworkUrl = null
            lastThumbBitmap = null
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
                manager.updateAppWidget(id, views)
            } else {
                // Song/artwork changed (or there's no cached bitmap yet) —
                // explicitly clear the thumbnail back to the placeholder
                // drawable right now. Without this, the ImageView keeps
                // showing whatever bitmap the widget host already had
                // for it (the PREVIOUS song's artwork) until the new
                // download finishes, which is exactly the "thumbnail
                // doesn't change with the song" bug.
                views.setImageViewResource(R.id.widget_artwork_thumb, R.drawable.widget_thumb_mask)
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
                    } ?: return@launch

                    lastArtworkUrl = url
                    lastThumbBitmap = thumb

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
                    manager.updateAppWidget(widgetId, views)
                } catch (e: Throwable) {
                    Log.w(TAG, "Thumbnail load failed for $url: ${e.message}")
                }
            }
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
            return try {
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
