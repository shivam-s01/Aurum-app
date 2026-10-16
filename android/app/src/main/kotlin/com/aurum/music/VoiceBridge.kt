package com.aurum.music

import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Gemini/Assistant -> MediaSession.onSetMediaItems(searchQuery) -> here -> Dart.
 * If Dart isn't reachable (app killed), query is parked in [pending] and the
 * app is launched; Dart pulls it via "getPending" on startup.
 */
object VoiceBridge {
    @Volatile var pending: String? = null
    @Volatile var sink: ((String) -> Unit)? = null

    fun dispatch(ctx: Context, q: String) {
        val s = sink
        if (s != null) {
            Handler(Looper.getMainLooper()).post { s(q) }
            return
        }
        pending = q
        try {
            ctx.startActivity(
                Intent(ctx, MainActivity::class.java).apply {
                    action = "android.media.action.MEDIA_PLAY_FROM_SEARCH"
                    putExtra(SearchManager.QUERY, q)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
            )
        } catch (_: Exception) {}
    }

    fun take(): String? { val q = pending; pending = null; return q }
}
