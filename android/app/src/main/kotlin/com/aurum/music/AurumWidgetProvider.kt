package com.aurum.music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews

/**
 * MINIMAL DIAGNOSTIC VERSION.
 *
 * Temporarily stripped down to rule out a crash source: no
 * AurumMediaSessionService/player access, no network, no bitmaps, no
 * coroutines — just static text and a single button that opens the app.
 * If this version still shows "An error occurred when loading widget",
 * the problem is NOT in any of the logic that was removed (blur,
 * artwork download, media session state) — it's something structural
 * (manifest, resource IDs, RemoteViews layout itself, or the widget
 * host/launcher). If this version works fine, we add features back one
 * at a time to find exactly which one breaks it.
 */
open class AurumWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "AurumWidget"

        fun refreshAll(context: Context) {
            // No-op in the minimal diagnostic build.
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        try {
            for (id in appWidgetIds) {
                val views = RemoteViews(context.packageName, R.layout.widget_compact)

                val engine = try { AurumMediaSessionService.sharedEngine } catch (e: Exception) {
                    Log.e(TAG, "sharedEngine access crashed: ${e.message}", e)
                    null
                }
                val player = engine?.player
                val metadata = try { player?.mediaMetadata } catch (e: Exception) {
                    Log.e(TAG, "mediaMetadata access crashed: ${e.message}", e)
                    null
                }
                val title = metadata?.title?.toString()
                val artist = metadata?.artist?.toString()
                val hasSong = player != null && player.mediaItemCount > 0 && !title.isNullOrEmpty()

                views.setTextViewText(R.id.widget_title, if (hasSong) title else "Aurum")
                views.setTextViewText(
                    R.id.widget_artist,
                    if (hasSong) (artist ?: "") else "Tap to play something"
                )

                val openAppIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                if (openAppIntent != null) {
                    openAppIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    val pending = PendingIntent.getActivity(
                        context, 100, openAppIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    )
                    views.setOnClickPendingIntent(R.id.widget_root_tap, pending)
                }

                appWidgetManager.updateAppWidget(id, views)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Step1 onUpdate crashed: ${e.message}", e)
        }
    }
}

class AurumWidgetProviderFull : AurumWidgetProvider()
