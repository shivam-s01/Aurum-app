package com.aurum.music

import android.util.Log
import io.github.shalva97.initNewPipe
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.stream.StreamInfoItem

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

    // ---------------------------------------------------------------
    // Shorts support: search-by-title/artist + muxed video+audio
    // stream resolution, alongside the audio-only path above.
    // ---------------------------------------------------------------

    data class VideoStream(val url: String, val resolution: String, val mimeType: String)
    data class SearchResult(val videoId: String, val title: String, val uploaderName: String, val durationSecs: Long)

    suspend fun search(query: String): List<SearchResult> = withContext(Dispatchers.IO) {
        try {
            ensureInit()
            val extractor = ServiceList.YouTube.getSearchExtractor(query)
            extractor.fetchPage()
            extractor.initialPage.items
                .filterIsInstance<StreamInfoItem>()
                .map {
                    SearchResult(
                        videoId = extractVideoId(it.url),
                        title = it.name ?: "",
                        uploaderName = it.uploaderName ?: "",
                        durationSecs = it.duration,
                    )
                }
                .filter { it.videoId.isNotEmpty() }
        } catch (e: Exception) {
            Log.w(TAG, "search failed for '$query': ${e.message}", e)
            emptyList()
        }
    }

    private fun extractVideoId(url: String): String {
        return try {
            val uri = android.net.Uri.parse(url)
            uri.getQueryParameter("v") ?: uri.lastPathSegment ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    suspend fun resolveVideo(videoId: String): VideoStream? = withContext(Dispatchers.IO) {
        try {
            ensureInit()
            resolveVideoOnce(videoId)
        } catch (e: Exception) {
            val transient = e.javaClass.simpleName in TRANSIENT_EXCEPTION_NAMES ||
                e.message?.contains("reloaded", ignoreCase = true) == true
            if (transient) {
                for (attempt in 1..2) {
                    Log.w(TAG, "Transient video-resolve error for $videoId, retry $attempt/2: ${e.message}")
                    delay(600L * attempt)
                    try {
                        return@withContext resolveVideoOnce(videoId)
                    } catch (eRetry: Exception) {
                        lastFailureReason = "videoId=$videoId ${eRetry.javaClass.simpleName}: ${eRetry.message}"
                        if (attempt == 2) return@withContext null
                    }
                }
            }
            lastFailureReason = "videoId=$videoId ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "resolveVideo failed for $videoId: ${e.message}", e)
            null
        }
    }

    private fun resolveVideoOnce(videoId: String): VideoStream? {
        val url = "https://www.youtube.com/watch?v=$videoId"
        val extractor = ServiceList.YouTube.getStreamExtractor(url)
        extractor.fetchPage()

        // Muxed (video+audio) streams preferred — playable by ExoPlayer
        // with zero extra work. Falls back to the highest-res available
        // stream if no fully-muxed option exists.
        val streams = extractor.videoStreams
        val best = streams?.filter { !it.isVideoOnly }
            ?.maxByOrNull { it.resolution?.replace("p", "")?.toIntOrNull() ?: 0 }
            ?: streams?.maxByOrNull { it.resolution?.replace("p", "")?.toIntOrNull() ?: 0 }

        val bestUrl = best?.content
        if (bestUrl.isNullOrBlank()) {
            lastFailureReason = "videoId=$videoId no muxed video stream with a usable URL"
            Log.w(TAG, lastFailureReason)
            return null
        }

        return VideoStream(
            url = bestUrl,
            resolution = best.resolution ?: "",
            mimeType = best.format?.mimeType ?: "",
        )
    }

    // ---------------------------------------------------------------
    // Related/"Up Next" videos — YouTube's own recommendation graph.
    //
    // ADDITIVE ONLY: nothing above this line was touched. This mirrors
    // resolve()/resolveOnce()'s exact structure (ensureInit → try →
    // transient-retry → same TRANSIENT_EXCEPTION_NAMES set) so it fails
    // the same safe way (null/empty, never throws) as every other
    // function here, and never touches AudioStream/VideoStream/search's
    // existing code paths — a caller not using getRelated is completely
    // unaffected by this addition.
    //
    // StreamExtractor already fetches the full watch page for
    // resolve()/resolveVideo() — that same page response carries
    // YouTube's related-videos ("Up Next" sidebar / autoplay queue)
    // data via NewPipeExtractor's relatedItems. This is what Musify
    // (via youtube_explode_dart's videos.getRelatedVideos) and every
    // other NewPipe-based player uses for YouTube-sourced autoplay —
    // it's literally YouTube's own algorithm output, not a guessed
    // search query, which is a strictly stronger signal than a
    // title/artist re-search for any song whose real identity lives on
    // YouTube (the same category of song api_service.dart's Signal 4
    // YouTube fallback already searches for). Kept as a clearly
    // separate, optional signal on the Dart side — this does not
    // replace Saavn's own similar-songs signal, which stays primary.
    // ---------------------------------------------------------------

    data class RelatedResult(
        val videoId: String,
        val title: String,
        val uploaderName: String,
        val durationSecs: Long,
        // -1 when NewPipeExtractor couldn't parse a view count for this
        // item (its own standard convention for "not available" on long
        // fields) — surfaced as-is rather than defaulted to 0, so the
        // Dart side can tell "genuinely zero views" apart from "unknown"
        // the same way it already treats a null viewCount for other
        // YouTube-sourced songs (see RecommendationEngine.isPremiumQuality).
        val viewCount: Long,
    )

    suspend fun getRelated(videoId: String): List<RelatedResult> = withContext(Dispatchers.IO) {
        try {
            ensureInit()
            getRelatedOnce(videoId)
        } catch (e: Exception) {
            val transient = e.javaClass.simpleName in TRANSIENT_EXCEPTION_NAMES ||
                e.message?.contains("reloaded", ignoreCase = true) == true
            if (transient) {
                for (attempt in 1..2) {
                    Log.w(TAG, "Transient related-videos error for $videoId, retry $attempt/2: ${e.message}")
                    delay(600L * attempt)
                    try {
                        return@withContext getRelatedOnce(videoId)
                    } catch (eRetry: Exception) {
                        lastFailureReason = "videoId=$videoId ${eRetry.javaClass.simpleName}: ${eRetry.message}"
                        Log.w(TAG, "getRelated retry $attempt/2 failed for $videoId: ${eRetry.message}", eRetry)
                        if (attempt == 2) return@withContext emptyList()
                    }
                }
            }
            lastFailureReason = "videoId=$videoId ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, "getRelated failed for $videoId: ${e.message}", e)
            emptyList()
        }
    }

    private fun getRelatedOnce(videoId: String): List<RelatedResult> {
        val url = "https://www.youtube.com/watch?v=$videoId"
        val extractor = ServiceList.YouTube.getStreamExtractor(url)
        extractor.fetchPage()

        // FIX: StreamExtractor.getRelatedItems() returns a nullable
        // InfoItemsCollector, NOT a List directly (unlike search()'s
        // extractor.initialPage.items above, which already is a List) —
        // the actual items come from the collector's own .items property.
        // Collector items can also include non-stream entries (e.g.
        // playlist/mix shelves alongside individual videos), so
        // filterIsInstance<StreamInfoItem> stays required here too.
        val relatedItems = extractor.relatedItems?.items ?: emptyList()

        return relatedItems
            .filterIsInstance<StreamInfoItem>()
            .map {
                RelatedResult(
                    videoId = extractVideoId(it.url),
                    title = it.name ?: "",
                    uploaderName = it.uploaderName ?: "",
                    durationSecs = it.duration,
                    // FIX: StreamInfoItem.getViewCount() is declared to
                    // throw ParsingException per-item (view count is
                    // scraped text, same as everything else NewPipe
                    // extracts) — letting one item's parse failure throw
                    // out of this whole .map{} would silently drop every
                    // OTHER already-successfully-parsed related video too.
                    // Isolating the try/catch per-item means a single
                    // odd item just falls back to -1 (unavailable)
                    // instead of losing the entire related-videos result.
                    viewCount = try { it.viewCount } catch (_: Exception) { -1L },
                )
            }
            .filter { it.videoId.isNotEmpty() }
    }
}
