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

        // Native path first: no MethodChannel round-trip, no Worker network
        // hop — fastest path for the vast majority of videos.
        val native = try {
            YoutubeInnertube.resolve(song.id)
        } catch (e: Exception) {
            Log.w(TAG, "Native resolve threw for ${song.id}: ${e.message}")
            null
        }
        if (native?.url != null) return native.url

        // Fallback: the native extractor can legitimately fail (YouTube
        // page/cipher format changes NewPipeExtractor hasn't patched yet,
        // a transient ContentNotAvailableException that survived its own
        // internal retry, regional blocks the embedded-bypass doesn't
        // clear, etc). Previously there was NO fallback here at all — a
        // native failure meant the song simply never played, which is
        // exactly the "resolve failed" behavior reported. Falling through
        // to the existing Worker-backed Dart resolver keeps the native
        // path as the fast common case while a native failure degrades to
        // the same reliability the app already had before this migration,
        // instead of degrading to "song doesn't play."
        Log.w(TAG, "Native resolve failed for ${song.id} (${YoutubeInnertube.lastFailureReason}), falling back to Worker")
        return fallback.resolve(song, forceRefresh)
    }

    override suspend fun invalidate(song: NativeSong) {
        // Nothing cached natively yet (URLs aren't stored here); still
        // forward so any Dart-side cache for this song is cleared too.
        fallback.invalidate(song)
    }
}
