package com.aurum.music

import android.util.Log
import io.github.shalva97.initNewPipe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.ServiceList

/**
 * Native YouTube stream resolution using NewPipeExtractor, via the NewValve
 * OkHttp wrapper (com.github.shalva97:NewValve) — the same extraction
 * approach SimpMusic, InnerTune, and YouMusic all rely on for stable
 * YouTube Music playback.
 *
 * Replaces the earlier io.github.shabinder:youtube-api-dl-android approach,
 * which was unmaintained since ~2022 and started throwing
 * BadPageException once YouTube changed its page/response format.
 * NewPipeExtractor is actively patched against YouTube's InnerTube/cipher
 * changes on an ongoing basis (see TeamNewPipe/NewPipeExtractor releases),
 * which is the actual reason those apps' playback stays stable over time.
 */
object YoutubeInnertube {

    private const val TAG = "YoutubeInnertube"

    @Volatile
    var lastFailureReason: String = "unknown"
        private set

    data class AudioStream(
        val url: String,
        val bitrate: Int,
        val mimeType: String,
    )

    @Volatile
    private var initialized = false

    private fun ensureInit() {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            initNewPipe()
            initialized = true
        }
    }

    /**
     * Resolves [videoId] to the best available audio-only stream URL.
     * Runs on Dispatchers.IO since NewPipeExtractor does blocking network
     * calls (InnerTube request + player JS cipher/nsig deobfuscation).
     */
    suspend fun resolve(videoId: String): AudioStream? = withContext(Dispatchers.IO) {
        try {
            ensureInit()
            resolveOnce(videoId)
        } catch (e: Exception) {
            // NewPipeExtractor's YouTube extractor sometimes fails its
            // first page fetch transiently — most commonly
            // "ContentNotAvailableException: The page needs to be
            // reloaded", but also occasional IOException/ParsingException
            // on a flaky mobile connection. None of these mean the video
            // is actually unavailable; a stale/half-populated extractor
            // instance can't just be retried in place though — a fresh
            // getStreamExtractor() + fetchPage() call is required.
            //
            // NOTE: the "reloaded" message specifically was, in a lot of
            // real cases, actually a genuine upstream extractor bug fixed
            // by TeamNewPipe/NewPipeExtractor PR #1438 — no amount of
            // in-app retrying fixes that class of failure, only pulling a
            // fixed extractor version does (see build.gradle, which now
            // pins v0.26.1 instead of the stale one bundled by NewValve
            // 1.5). What retrying HERE is for is the separate, genuinely
            // transient case: per-request flakiness (e.g. YouTube's
            // SABR-related A/B experiments) where the exact same request
            // can succeed on a second try even with an up-to-date
            // extractor. Two retries with a short backoff between them
            // gives that transient case a real chance to clear, instead
            // of an instant single retry that can hit the same transient
            // condition again immediately.
            val transient = e.javaClass.simpleName in TRANSIENT_EXCEPTION_NAMES ||
                e.message?.contains("reloaded", ignoreCase = true) == true

            if (transient) {
                for (attempt in 1..2) {
                    Log.w(TAG, "Transient error for $videoId (${e.javaClass.simpleName}), retry $attempt/2: ${e.message}")
                    delay(600L * attempt)
                    try {
                        return@withContext resolveOnce(videoId)
                    } catch (eRetry: Exception) {
                        lastFailureReason = "videoId=$videoId ${eRetry.javaClass.simpleName}: ${eRetry.message}"
                        Log.w(TAG, "resolve retry $attempt/2 failed for $videoId: ${eRetry.message}", eRetry)
                        if (attempt == 2) return@withContext null
                    }
                }
            }
            lastFailureReason = "videoId=$videoId ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "resolve failed for $videoId: ${e.message}", e)
            null
        }
    }

    private val TRANSIENT_EXCEPTION_NAMES = setOf(
        "ContentNotAvailableException",
        "ParsingException",
        "ExtractionException",
        "IOException",
        "SocketTimeoutException",
    )

    private fun resolveOnce(videoId: String): AudioStream? {
        val url = "https://www.youtube.com/watch?v=$videoId"
        val extractor = ServiceList.YouTube.getStreamExtractor(url)
        extractor.fetchPage()

        val audioStreams = extractor.audioStreams
        if (audioStreams.isNullOrEmpty()) {
            lastFailureReason = "videoId=$videoId no audio streams returned"
            Log.w(TAG, lastFailureReason)
            return null
        }

        // Highest average bitrate first — mirrors the old
        // high->medium->low quality fallback intent.
        val best = audioStreams.maxByOrNull { it.averageBitrate }

        val bestUrl = best?.content
        if (bestUrl.isNullOrBlank()) {
            lastFailureReason = "videoId=$videoId no audio stream with a usable URL"
            Log.w(TAG, lastFailureReason)
            return null
        }

        return AudioStream(
            url = bestUrl,
            bitrate = best.averageBitrate,
            mimeType = best.format?.mimeType ?: "",
        )
    }
}
