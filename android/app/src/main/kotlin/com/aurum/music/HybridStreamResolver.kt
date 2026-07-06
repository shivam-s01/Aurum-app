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

        val native = try {
            YoutubeInnertube.resolve(song.id)
        } catch (e: Exception) {
            Log.w(TAG, "Native resolve threw for ${song.id}: ${e.message}")
            null
        }

        if (native != null) return native.url

        // Native path exhausted its own internal fallback chain already;
        // as a last resort defer to the Dart-side resolver (Worker/Piped),
        // so a single YouTube song failing doesn't fail plainly when the
        // legacy path could still succeed (e.g. differing IP/region luck).
        Log.w(TAG, "Native InnerTube resolve failed for ${song.id}, falling back to Dart resolver")
        return fallback.resolve(song, forceRefresh)
    }

    override suspend fun invalidate(song: NativeSong) {
        // Nothing cached natively yet (URLs aren't stored here); still
        // forward so any Dart-side cache for this song is cleared too.
        fallback.invalidate(song)
    }
}
