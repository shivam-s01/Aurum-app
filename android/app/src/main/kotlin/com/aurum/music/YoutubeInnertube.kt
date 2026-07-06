package com.aurum.music

import android.util.Log
import io.github.shalva97.initNewPipe
import kotlinx.coroutines.Dispatchers
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

            val url = "https://www.youtube.com/watch?v=$videoId"
            val extractor = ServiceList.YouTube.getStreamExtractor(url)
            extractor.fetchPage()

            val audioStreams = extractor.audioStreams
            if (audioStreams.isNullOrEmpty()) {
                lastFailureReason = "videoId=$videoId no audio streams returned"
                Log.w(TAG, lastFailureReason)
                return@withContext null
            }

            // Highest average bitrate first — mirrors the old
            // high->medium->low quality fallback intent.
            val best = audioStreams.maxByOrNull { it.averageBitrate }

            val bestUrl = best?.content
            if (bestUrl.isNullOrBlank()) {
                lastFailureReason = "videoId=$videoId no audio stream with a usable URL"
                Log.w(TAG, lastFailureReason)
                return@withContext null
            }

            AudioStream(
                url = bestUrl,
                bitrate = best.averageBitrate,
                mimeType = best.format?.mimeType ?: "",
            )
        } catch (e: Exception) {
            lastFailureReason = "videoId=$videoId ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "resolve failed for $videoId: ${e.message}", e)
            null
        }
    }
}
