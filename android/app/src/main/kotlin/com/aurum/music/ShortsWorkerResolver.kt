package com.aurum.music

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * PRIMARY resolve path for Shorts — talks to the aurum-shorts-video
 * Cloudflare Worker (same Worker the old Dart ShortsVideoService used).
 * Kept as a real HTTP call so it's just as usable as the native path,
 * but the actual YouTube resolution logic (android_vr/ios/tv-embed/
 * piped chain) lives on the Worker — meaning Krish can push a fix
 * there (`wrangler deploy`) any time YouTube changes something, with
 * ZERO app rebuild/reinstall.
 *
 * Confirmed against the real worker.js router: it exposes exactly
 * /api/video-resolve, /api/video-proxy, and /health. NO search
 * endpoint exists — title+artist -> videoId search stays fully
 * native (see AurumShortsEngine.resolveVideoId / YoutubeInnertube),
 * matching the original Dart pipeline which used youtube_explode_dart
 * directly for that stage too.
 *
 * IMPORTANT: /api/video-proxy resolves the video ITSELF internally
 * (it does not accept a pre-resolved url/client — those params don't
 * exist in the handler) and streams the muxed bytes straight through
 * with Range support built in. So the correct call here is a single
 * hit to /api/video-proxy?id=<videoId> — one round trip, no redundant
 * pre-resolve step, no wasted double work.
 *
 * AurumShortsEngine tries this FIRST for every stream resolve; only
 * on failure (network error, timeout, non-2xx after a lightweight
 * HEAD probe) does it fall back to YoutubeInnertube's native
 * on-device NewPipeExtractor path — same safety-net shape as
 * HybridStreamResolver.kt uses for the main audio queue.
 */
object ShortsWorkerResolver {

    private const val TAG = "ShortsWorkerResolver"
    private const val BASE_URL = "https://aurum-shorts-video.krish908090.workers.dev"

    private val client = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /**
     * Returns a playable URL for [videoId] — the Worker's own
     * /api/video-proxy endpoint, which resolves + streams the muxed
     * video+audio in one shot. Handed straight to ExoPlayer as a
     * MediaItem source, same as any other network stream.
     *
     * A lightweight HEAD probe confirms the Worker can actually serve
     * this video (not just that the domain is reachable) before we
     * commit to it as the ExoPlayer source — a video-proxy call that
     * 502s deep into playback would otherwise show up to the user as
     * a stuck/frozen card rather than a clean fallback to native.
     */
    suspend fun resolveStream(videoId: String): String? = withContext(Dispatchers.IO) {
        val proxyUrl = "$BASE_URL/api/video-proxy?id=$videoId"
        try {
            val probe = Request.Builder().url(proxyUrl).head().build()
            client.newCall(probe).execute().use { resp ->
                if (!resp.isSuccessful) {
                    Log.w(TAG, "video-proxy probe HTTP ${resp.code} for $videoId")
                    return@withContext null
                }
            }
            proxyUrl
        } catch (e: Exception) {
            Log.w(TAG, "video-proxy probe failed for $videoId: ${e.message}")
            null
        }
    }
}
