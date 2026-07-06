package com.aurum.music

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger

/**
 * Routes resolve() by source:
 *  - "youtube"  -> native YoutubeInnertube (Kotlin -> YouTube, no Worker, no
 *                  MethodChannel round-trip)
 *  - "saavn"/"local" -> unchanged, delegates to MethodChannelStreamResolver
 *                       (direct CDN URLs, no InnerTube needed there)
 *
 * This keeps AurumAudioEngine untouched: it still just calls
 * resolver.resolve(song) / resolver.invalidate(song) same as before.
 */
class HybridStreamResolver(messenger: BinaryMessenger) : StreamResolver {

    companion object {
        private const val TAG = "HybridStreamResolver"
    }

    private val fallback = MethodChannelStreamResolver(messenger)

    override suspend fun resolve(song: NativeSong, forceRefresh: Boolean): String? {
        if (song.source != "youtube") {
            return fallback.resolve(song, forceRefresh)
        }

        // Worker fallback intentionally removed — testing pure native
        // InnerTube path in isolation. If this returns null, the failure
        // is 100% in YoutubeInnertube, not masked by the old Worker path.
        val native = try {
            YoutubeInnertube.resolve(song.id)
        } catch (e: Exception) {
            Log.w(TAG, "Native resolve threw for ${song.id}: ${e.message}")
            null
        }

        return native?.url
    }

    override suspend fun invalidate(song: NativeSong) {
        // Nothing cached natively yet (URLs aren't stored here); still
        // forward so any Dart-side cache for this song is cleared too.
        fallback.invalidate(song)
    }
}
