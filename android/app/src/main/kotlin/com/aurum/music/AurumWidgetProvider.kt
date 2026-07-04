package com.aurum.music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews

/**
 * Home-screen widget for Aurum — two sizes (compact "now playing" strip,
 * and a full version with prev/play-pause/next transport controls).
 *
 * ARTWORK/BLUR PERMANENTLY REMOVED. Both the GPU RenderEffect path and
 * the pure-software box-blur fallback were tried; both still produced
 * "An error occurred when loading widget" on the actual device even
 * with every catch widened to Throwable (covers OutOfMemoryError too).
 * That means the failure happens on the WIDGET HOST side of the
 * updateAppWidget() Binder IPC call — most likely the delivered
 * RemoteViews' embedded Bitmap (background blur + thumbnail) either
 * exceeded the Binder transaction size limit, or the host's own
 * inflate of a large embedded bitmap failed for some other
 * device/launcher-specific reason. No code running in this app's
 * process can catch a failure that happens after the RemoteViews have
 * already been handed off to the host. Removing bitmaps from the
 * RemoteViews entirely removes that whole failure class — this widget
 * now only ever sends text + solid-color drawables + click intents,
 * all of which are small, static, resource-based content the host has
 * always been able to render reliably.
 */
open class AurumWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "AurumWidget"

        const val ACTION_PLAY_PAUSE = "com.aurum.music.widget.ACTION_PLAY_PAUSE"
        const val ACTION_NEXT = "com.aurum.music.widget.ACTION_NEXT"
        const val ACTION_PREV = "com.aurum.music.widget.ACTION_PREV"
        const val ACTION_REFRESH = "com.aurum.music.widget.ACTION_REFRESH"

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
            manager.updateAppWidget(id, views)
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
