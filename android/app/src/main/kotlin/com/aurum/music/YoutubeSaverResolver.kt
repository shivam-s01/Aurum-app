package com.aurum.music

import android.util.Log
import io.github.shalva97.initNewPipe
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.AudioStream as NpAudioStream
import org.schabi.newpipe.extractor.stream.DeliveryMethod

/**
 * Data-Saver-aware YouTube audio picker.
 *
 * YoutubeInnertube.resolve() always returns the HIGHEST-bitrate audio-only
 * stream (~130-160kbps) and knows nothing about Data Saver. This object is a
 * separate, self-contained resolver that HybridStreamResolver consults FIRST
 * while Data Saver is active; YoutubeInnertube.kt is not touched at all.
 *
 * Pick policy (same idea as YouTube Music's own "Data saver" / low tier):
 *  1. Only progressive-HTTP streams with a known bitrate (same kind of
 *     stream the normal path already plays).
 *  2. Only the ORIGINAL audio track (never an auto-dubbed language).
 *  3. Among streams <= [CEILING_KBPS]: prefer Opus over AAC (Opus is far
 *     better at low bitrate), then the highest bitrate under the ceiling.
 *     Typical result: Opus ~50kbps (~0.37 MB/min, vs ~1 MB/min at 130kbps).
 *  4. If nothing is under the ceiling, take the smallest stream available.
 *
 * Any failure returns null, so HybridStreamResolver falls straight back to
 * the normal best-quality path -> Data Saver can never break playback.
 */
object YoutubeSaverResolver {

    private const val TAG = "YoutubeSaverResolver"

    /**
     * Ceiling for the Data Saver pick. YouTube's audio-only tiers are
     * roughly: AAC ~48, Opus ~50, Opus ~70, AAC ~128, Opus ~130 kbps.
     * 64 lands on Opus ~50kbps (the cleanest stream YouTube offers at that
     * size; Opus beats AAC at low bitrate) = ~22 MB/hour, i.e. ~4.4 hours of
     * music per 100 MB. Tune: 100 = Opus ~70kbps (~3.2 h / 100 MB, more
     * headroom), 140 = saver effectively off.
     */
    private const val CEILING_KBPS = 64

    /** Mirrors AudioPrefs.dataSaverActiveNotifier; set from AurumAudioEngine.setDataSaverActive(). */
    @Volatile
    var active: Boolean = false

    suspend fun resolve(videoId: String): YoutubeInnertube.AudioStream? =
        withContext(Dispatchers.IO) {
            try {
                if (NewPipe.getDownloader() == null) initNewPipe()

                val extractor = ServiceList.YouTube.getStreamExtractor(
                    "https://www.youtube.com/watch?v=$videoId"
                )
                extractor.fetchPage()

                val all = extractor.audioStreams.orEmpty().filter {
                    it.averageBitrate > 0 && !it.content.isNullOrBlank()
                }
                if (all.isEmpty()) return@withContext null

                val progressive = all.filter {
                    it.deliveryMethod == DeliveryMethod.PROGRESSIVE_HTTP
                }.ifEmpty { all }

                val original = progressive.filter { isOriginalTrack(it) }.ifEmpty { progressive }

                val underCeiling = original.filter { it.averageBitrate <= CEILING_KBPS }
                val picked: NpAudioStream? = if (underCeiling.isNotEmpty()) {
                    underCeiling.maxWithOrNull(
                        compareBy<NpAudioStream>({ isOpus(it) }, { it.averageBitrate })
                    )
                } else {
                    original.minByOrNull { it.averageBitrate }
                }
                val best = picked ?: return@withContext null

                Log.i(TAG, "saver pick for $videoId: ${best.averageBitrate}kbps ${best.format?.mimeType}")
                YoutubeInnertube.AudioStream(
                    url = best.content,
                    bitrate = best.averageBitrate,
                    mimeType = best.format?.mimeType ?: "",
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "saver resolve failed for $videoId, using normal path: ${e.message}")
                null
            }
        }

    private fun isOpus(s: NpAudioStream): Boolean {
        val mime = s.format?.mimeType?.lowercase() ?: return false
        return mime.contains("opus") || mime.contains("webm")
    }

    // audioTrackType only exists on newer extractor builds; read it via
    // reflection so this file compiles no matter what and treats "unknown"
    // as original.
    private fun isOriginalTrack(s: NpAudioStream): Boolean = try {
        val v = s.javaClass.methods
            .firstOrNull { it.name == "getAudioTrackType" && it.parameterTypes.isEmpty() }
            ?.invoke(s)?.toString()
        v == null || v == "ORIGINAL"
    } catch (e: Throwable) {
        true
    }
}
