package com.aurum.music

import android.util.Log
import io.github.shabinder.YoutubeDownloader
import io.github.shabinder.models.quality.AudioQuality
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Native YouTube stream resolution using io.github.shabinder:youtube-api-dl
 * (the same library SpotiFlyer uses) instead of a hand-rolled InnerTube
 * client. Our own OkHttp/JSON attempts kept hitting playabilityStatus=ERROR
 * or, when that got fixed, ciphered URLs we couldn't decode — this library
 * does both the InnerTube call AND the signature-cipher decoding (JS
 * player interpretation) internally, which is what ViMusic/SimpMusic-grade
 * stability actually depends on.
 */
object YoutubeInnertube {

    private const val TAG = "YoutubeInnertube"

    @Volatile
    var lastFailureReason: String = "unknown"
        private set

    private val downloader = YoutubeDownloader()

    data class AudioStream(
        val url: String,
        val bitrate: Int,
        val mimeType: String,
    )

    /**
     * Resolves [videoId] to the best available audio-only stream URL.
     * Runs on Dispatchers.IO since the library does blocking network calls.
     */
    suspend fun resolve(videoId: String): AudioStream? = withContext(Dispatchers.IO) {
        try {
            val video = downloader.getVideo(videoId)

            val best = (video.getAudioWithQuality(AudioQuality.high).firstOrNull()
                ?: video.getAudioWithQuality(AudioQuality.medium).firstOrNull()
                ?: video.getAudioWithQuality(AudioQuality.low).firstOrNull())

            val bestUrl: String? = best?.url
            if (bestUrl.isNullOrBlank()) {
                lastFailureReason = "videoId=$videoId no audio format with a usable URL"
                Log.w(TAG, lastFailureReason)
                return@withContext null
            }

            AudioStream(
                url = bestUrl,
                bitrate = best?.bitrate ?: 0,
                mimeType = best?.mimeType ?: "",
            )
        } catch (e: Exception) {
            lastFailureReason = "videoId=$videoId ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "resolve failed for $videoId: ${e.message}", e)
            null
        }
    }
}
