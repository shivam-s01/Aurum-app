package com.aurum.music

import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import android.os.SystemClock

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
        private const val URL_TTL_MS = 45L * 60L * 1000L
        // Same channel AurumEngineChannelHandler's callbackChannel uses for
        // every other Kotlin -> Dart reverse call (onLikeToggleRequested,
        // etc) — reusing it here means Dart's existing single
        // _handleEngineCallback dispatcher (native_engine_bridge.dart) just
        // gets one more case, no new channel/listener plumbing needed.
        private const val ENGINE_CHANNEL = "com.aurum.music/audio_engine"
    }

    private val fallback = MethodChannelStreamResolver(messenger)

    // NATIVE STREAM-URL CACHE (data fix): the native YouTube path used to have NO
    // cache at all (the Dart-side cache is bypassed by it), so every replay,
    // queue restart, skip-back or watchdog recovery re-ran the full NewPipe
    // extraction -- YouTube page + player JSON, hundreds of KB each time, often
    // bigger than the audio itself at Data Saver bitrates. YouTube stream URLs
    // stay valid for hours; 45 min is conservative. A dead URL still recovers:
    // every recovery path calls invalidate() first, which drops the entry here.
    private class CachedUrl(val url: String, val bitrate: Int, val at: Long)
    private val urlCache = object : LinkedHashMap<String, CachedUrl>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, CachedUrl>?): Boolean =
            size > 40
    }
    private fun cacheKey(id: String) = if (YoutubeSaverResolver.active) "$id|s" else "$id|n"
    private fun cacheGet(id: String): CachedUrl? = synchronized(urlCache) {
        val e = urlCache[cacheKey(id)] ?: return null
        if (SystemClock.elapsedRealtime() - e.at > URL_TTL_MS) { urlCache.remove(cacheKey(id)); null } else e
    }
    private fun cachePut(id: String, url: String, bitrate: Int) = synchronized(urlCache) {
        urlCache[cacheKey(id)] = CachedUrl(url, bitrate, SystemClock.elapsedRealtime())
    }
    private fun cacheDrop(id: String) = synchronized(urlCache) {
        urlCache.remove("$id|s"); urlCache.remove("$id|n")
    }
    // FIX ("Auto" quality always shown for YouTube songs in the Bluetooth/
    // output-device sheet and Settings > Player & Audio): YoutubeInnertube
    // .resolve() already computes a real averageBitrate from YouTube's own
    // audio stream formats (see YoutubeInnertube.kt), but this function
    // used to return only `native.url` — the bitrate it had just computed
    // was silently discarded one line below, so AudioPrefs.lastResolvedKbps
    // (which both quality labels read) never had a real YouTube value to
    // fall back from "Auto" to. This channel reports the real number back
    // to Dart the same way the existing Worker/JioSaavn resolve path
    // already does via 'reportResolvedBitrate' in native_engine_bridge.dart
    // — fire-and-forget, matching that call's own "never block the resolve
    // path on a side-channel report" reasoning.
    private val callbackChannel = MethodChannel(messenger, ENGINE_CHANNEL)

    override suspend fun resolve(song: NativeSong, forceRefresh: Boolean): String? {
        if (song.source != "youtube") {
            return fallback.resolve(song, forceRefresh)
        }

        if (!forceRefresh) {
            val hit = cacheGet(song.id)
            if (hit != null) {
                callbackChannel.invokeMethod(
                    "onYoutubeBitrateResolved",
                    mapOf("kbps" to hit.bitrate.takeIf { it > 0 }),
                )
                return hit.url
            }
        } else {
            cacheDrop(song.id)
        }

        // Native path first: no MethodChannel round-trip, no Worker network
        // hop — fastest path for the vast majority of videos.
        val native = try {
            // Data Saver: low-bitrate pick from the separate saver resolver
            // first; null (or saver off) -> normal best-quality path.
            (if (YoutubeSaverResolver.active) YoutubeSaverResolver.resolve(song.id) else null)
                ?: YoutubeInnertube.resolve(song.id)
        } catch (e: Exception) {
            Log.w(TAG, "Native resolve threw for ${song.id}: ${e.message}")
            null
        }
        if (native?.url != null) {
            // Real YouTube audio bitrate (typically ~128-160kbps Opus/AAC —
            // YouTube never offers a 320kbps audio-only stream the way
            // JioSaavn's fixed '320kbps' field does, so this is genuinely
            // the true ceiling for this source, not a bug). Reported on a
            // best-effort basis: a failure here must never affect playback,
            // it only means the quality label stays on "Auto" for this one
            // song instead of showing the real number.
            callbackChannel.invokeMethod(
                "onYoutubeBitrateResolved",
                mapOf("kbps" to native.bitrate.takeIf { it > 0 }),
            )
            cachePut(song.id, native.url, native.bitrate)
            try {
                AurumDiagnosticLog.logEvent(
                    "data",
                    "resolve ${song.id}: ${native.bitrate}kbps ${native.mimeType} saver=${YoutubeSaverResolver.active}",
                )
            } catch (_: Throwable) {}
            return native.url
        }

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
        try {
            AurumDiagnosticLog.logEvent("data", "resolve ${song.id}: native failed, Worker fallback, saver=${YoutubeSaverResolver.active}")
        } catch (_: Throwable) {}
        return fallback.resolve(song, forceRefresh)
    }

    override suspend fun invalidate(song: NativeSong) {
        cacheDrop(song.id)
        // Also forward so any Dart-side cache for this song is cleared too.
        fallback.invalidate(song)
    }
}
