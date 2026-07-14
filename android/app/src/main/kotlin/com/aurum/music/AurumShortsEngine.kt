package com.aurum.music

import android.content.Context
import android.util.Log
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Fully native replacement for the old Dart-side Shorts video pipeline
 * (ShortsVideoService + ShortsFeedController's VideoPlayerController
 * usage). Owns:
 *   - search (title+artist -> best-match YouTube video id)
 *   - resolve (video id -> muxed stream URL, via YoutubeInnertube)
 *   - two pooled ExoPlayer instances: "current" (playing, attached to
 *     the visible SurfaceView) and "preload" (next card, paused/muted,
 *     fully buffered ahead of time)
 *
 * Dart's job shrinks to: tell this engine which song is active, hand
 * it a Surface to render into, and listen for status/position via
 * MethodChannel. No VideoPlayerController, no per-card Dart-side
 * decoder object, no GC churn from tearing down Flutter plugin
 * wrappers every swipe — matches the same "native owns the player"
 * shape as AurumAudioEngine for the main queue.
 *
 * Completely isolated from AurumAudioEngine — separate ExoPlayer
 * instances, no shared state, no interaction with the main queue.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AurumShortsEngine(private val context: Context) {

    companion object {
        private const val TAG = "AurumShortsEngine"
        private const val UA = "com.google.android.apps.youtube.vr.oculus/1.71.26 " +
            "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    }

    enum class Status { NONE, LOADING, READY, FAILED }

    data class ShortsPlaybackState(
        val status: Status,
        val positionMs: Long,
        val durationMs: Long,
        val isPlaying: Boolean,
    )

    // dedupeKey -> resolved videoId (null = not found)
    private val idCache = HashMap<String, String?>()
    // videoId -> resolved stream url (null = failed)
    private val streamCache = HashMap<String, String?>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var loadJob: Job? = null
    private var preloadJob: Job? = null

    private var currentPlayer: ExoPlayer? = null
    private var preloadPlayer: ExoPlayer? = null
    private var preloadedForVideoId: String? = null

    private var currentSurface: Surface? = null
    private var loadToken = 0
    private var preloadToken = 0

    var onStateChanged: ((ShortsPlaybackState) -> Unit)? = null
    var onAutoAdvance: (() -> Unit)? = null // clip finished OR resolve failed -> ask Dart to advance

    private fun httpDataSourceFactory() = DefaultHttpDataSource.Factory()
        .setUserAgent(UA)
        .setAllowCrossProtocolRedirects(true)

    private fun newPlayer(): ExoPlayer {
        val mediaSourceFactory = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(httpDataSourceFactory())
        return ExoPlayer.Builder(context)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
    }

    /** Attaches the visible SurfaceView's Surface to the current player. */
    fun attachSurface(surface: Surface?) {
        currentSurface = surface
        currentPlayer?.setVideoSurface(surface)
    }

    /**
     * Loads and plays [videoId]/[title]/[artist] as the active card.
     * If it was already preloaded (fast path), swaps players instantly
     * with zero network wait. Otherwise resolves + plays fresh.
     */
    fun playSong(dedupeKey: String, title: String, artist: String) {
        loadJob?.cancel()
        val myToken = ++loadToken

        if (preloadedForVideoId != null && idCache[dedupeKey] == preloadedForVideoId && preloadPlayer != null) {
            swapInPreloaded()
            return
        }

        emitState(Status.LOADING, 0, 0, false)
        tearDownCurrent()

        loadJob = scope.launch {
            val videoId = resolveVideoId(dedupeKey, title, artist)
            if (myToken != loadToken) return@launch
            if (videoId == null) {
                emitState(Status.FAILED, 0, 0, false)
                onAutoAdvance?.invoke()
                return@launch
            }
            val streamUrl = resolveStreamUrl(videoId)
            if (myToken != loadToken) return@launch
            if (streamUrl == null) {
                emitState(Status.FAILED, 0, 0, false)
                onAutoAdvance?.invoke()
                return@launch
            }
            startPlayback(streamUrl, myToken)
        }
    }

    private fun startPlayback(streamUrl: String, myToken: Int) {
        val player = newPlayer()
        player.setVideoSurface(currentSurface)
        player.repeatMode = Player.REPEAT_MODE_ONE
        player.volume = 1.0f
        player.setMediaItem(MediaItem.fromUri(streamUrl))
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (myToken != loadToken) return
                when (playbackState) {
                    Player.STATE_READY -> emitState(Status.READY, player.currentPosition, player.duration.coerceAtLeast(0), player.isPlaying)
                    Player.STATE_ENDED -> { /* REPEAT_MODE_ONE handles looping; no-op */ }
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (myToken != loadToken) return
                emitState(Status.READY, player.currentPosition, player.duration.coerceAtLeast(0), isPlaying)
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.w(TAG, "ExoPlayer error: ${error.message}")
                if (myToken != loadToken) return
                emitState(Status.FAILED, 0, 0, false)
                onAutoAdvance?.invoke()
            }
        })
        player.prepare()
        player.play()
        currentPlayer = player
        unawaitedPreloadNext()
    }

    private fun swapInPreloaded() {
        val old = currentPlayer
        val player = preloadPlayer!!
        preloadPlayer = null
        preloadedForVideoId = null

        player.setVideoSurface(currentSurface)
        player.volume = 1.0f
        player.repeatMode = Player.REPEAT_MODE_ONE
        player.play()
        currentPlayer = player
        emitState(Status.READY, player.currentPosition, player.duration.coerceAtLeast(0), true)

        old?.let { p ->
            scope.launch { p.release() }
        }
        unawaitedPreloadNext()
    }

    /** Called by Dart ahead of time with the NEXT card's identity. */
    fun preloadNext(dedupeKey: String, title: String, artist: String) {
        preloadJob?.cancel()
        val myToken = ++preloadToken
        preloadJob = scope.launch {
            val videoId = resolveVideoId(dedupeKey, title, artist) ?: return@launch
            if (myToken != preloadToken) return@launch
            val streamUrl = resolveStreamUrl(videoId) ?: return@launch
            if (myToken != preloadToken) return@launch

            val old = preloadPlayer
            preloadPlayer = null
            old?.let { scope.launch { it.release() } }

            val player = newPlayer()
            player.volume = 0f
            player.repeatMode = Player.REPEAT_MODE_ONE
            player.setMediaItem(MediaItem.fromUri(streamUrl))
            player.prepare()
            player.playWhenReady = false
            preloadPlayer = player
            preloadedForVideoId = videoId
        }
    }

    private fun unawaitedPreloadNext() {
        // Dart drives this via preloadNext() with the actual next
        // item's identity — nothing to do here without that context.
    }

    fun togglePlayPause() {
        val p = currentPlayer ?: return
        if (p.isPlaying) p.pause() else p.play()
    }

    fun pause() = currentPlayer?.pause()
    fun resume() = currentPlayer?.play()

    /**
     * Search (title+artist -> videoId) is ALWAYS native — the
     * aurum-shorts-video Worker has no search endpoint (confirmed
     * against worker.js: only /api/video-resolve, /api/video-proxy,
     * /health exist), so there's nothing to call there. This matches
     * the original Dart pipeline too, which used youtube_explode_dart
     * directly for this stage, never the Worker.
     */
    private suspend fun resolveVideoId(dedupeKey: String, title: String, artist: String): String? {
        idCache[dedupeKey]?.let { return it }
        if (idCache.containsKey(dedupeKey)) return null // cached miss

        val results = YoutubeInnertube.search("$artist $title")
        val best = pickBestMatch(results, title, artist)
        idCache[dedupeKey] = best
        return best
    }

    /**
     * PRIMARY: aurum-shorts-video Worker (ShortsWorkerResolver) —
     * videoId -> muxed stream URL. Same Worker + same
     * android_vr/ios/tv-embed/piped chain the old Dart pipeline used.
     * Lets Krish fix YouTube resolve issues by redeploying the Worker
     * alone (`wrangler deploy`) — zero app rebuild/reinstall needed.
     * FALLBACK: native on-device NewPipeExtractor (YoutubeInnertube) —
     * only used if the Worker call fails outright (network error,
     * timeout, bad response, Worker down), same safety-net pattern as
     * HybridStreamResolver.kt uses for the main audio queue.
     */
    private suspend fun resolveStreamUrl(videoId: String): String? {
        if (streamCache.containsKey(videoId)) return streamCache[videoId]

        val workerUrl = ShortsWorkerResolver.resolveStream(videoId)
        if (workerUrl != null) {
            streamCache[videoId] = workerUrl
            return workerUrl
        }

        Log.w(TAG, "Worker resolve failed for $videoId, falling back to native")
        val stream = YoutubeInnertube.resolveVideo(videoId)
        val url = stream?.url
        streamCache[videoId] = url
        return url
    }

    /**
     * Same scoring approach as the old Dart _pickBestMatch: prefers
     * official/"- Topic" uploads matching the artist, penalizes
     * covers/live/reaction/lyric/speed-altered reuploads, and rejects
     * anything under a minimum score bar rather than guessing.
     */
    private fun pickBestMatch(
        candidates: List<YoutubeInnertube.SearchResult>,
        title: String,
        artist: String,
    ): String? {
        val normTitle = normalize(title)
        val normArtist = normalize(artist)

        var best: YoutubeInnertube.SearchResult? = null
        var bestScore = -1

        for (v in candidates) {
            if (v.durationSecs < 45 || v.durationSecs > 600) continue

            val normVTitle = normalize(v.title)
            val normAuthor = normalize(v.uploaderName)

            if (!normVTitle.contains(normTitle) && !looseContains(normVTitle, normTitle)) continue
            if (isJunkTitle(normVTitle)) continue

            var score = 0
            if (normAuthor == "$normArtist topic" || normAuthor.contains("$normArtist - topic")) {
                score += 100
            } else if (normAuthor.contains(normArtist) || normArtist.contains(normAuthor)) {
                score += 60
            }

            if (normVTitle.contains("official video") || normVTitle.contains("official music video")) {
                score += 40
            } else if (normVTitle.contains("official audio")) {
                score += 25
            } else if (normVTitle.contains("official")) {
                score += 15
            }

            if (normVTitle == normTitle || normVTitle == "$normArtist $normTitle") score += 20

            if (normVTitle.contains("cover")) score -= 50
            if (normVTitle.contains("live") || normVTitle.contains("concert")) score -= 40
            if (normVTitle.contains("reaction")) score -= 100
            if (normVTitle.contains("lyric")) score -= 10
            if (normVTitle.contains("8d audio") || normVTitle.contains("slowed") || normVTitle.contains("sped up")) {
                score -= 80
            }

            if (score > bestScore) {
                bestScore = score
                best = v
            }
        }

        if (bestScore < 15) return null
        return best?.videoId
    }

    private val junkMarkers = listOf(
        "trailer", "interview", "behind the scenes", "making of", "full album",
        "compilation", "mashup", "ringtone", "karaoke", "instrumental only", "type beat",
    )

    private fun isJunkTitle(normTitle: String) = junkMarkers.any { normTitle.contains(it) }

    private fun normalize(s: String) = s.lowercase()
        .replace(Regex("[^\\w\\s]"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    private fun looseContains(haystack: String, needle: String): Boolean {
        val needleWords = needle.split(" ").filter { it.length > 2 }.toSet()
        if (needleWords.isEmpty()) return false
        val haystackWords = haystack.split(" ").toSet()
        val overlap = needleWords.intersect(haystackWords).size
        return overlap.toDouble() / needleWords.size >= 0.7
    }

    private fun tearDownCurrent() {
        val old = currentPlayer
        currentPlayer = null
        old?.let { scope.launch { it.release() } }
    }

    private fun emitState(status: Status, positionMs: Long, durationMs: Long, isPlaying: Boolean) {
        onStateChanged?.invoke(ShortsPlaybackState(status, positionMs, durationMs, isPlaying))
    }

    /** Full teardown — call when the Shorts feed screen is closed. */
    fun release() {
        loadJob?.cancel()
        preloadJob?.cancel()
        currentPlayer?.release()
        preloadPlayer?.release()
        currentPlayer = null
        preloadPlayer = null
        preloadedForVideoId = null
        idCache.clear()
        streamCache.clear()
        scope.cancel()
    }
}
