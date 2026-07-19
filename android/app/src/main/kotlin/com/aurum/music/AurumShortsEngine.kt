package com.aurum.music

import android.content.Context
import android.util.Log
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Native Shorts playback engine — iTunes-sourced, audio-only,
 * 30-second clips.
 *
 * There is no search/match/resolve step at all anymore: Dart already
 * has the exact playable URL (iTunes `previewUrl`, from
 * ItunesShortsApi) by the time it calls playSong()/preloadNext(). This
 * engine's only job is running two pooled ExoPlayer instances
 * ("current" playing, "preload" next-card-buffered) against whatever
 * URL it's handed, plus a 30-second auto-advance timer per card.
 *
 * Previous versions of this engine did YouTube title+artist search,
 * best-match scoring, and a multi-step stream-URL resolve chain
 * (first a shorts-only Cloudflare Worker, later the main queue's
 * HybridStreamResolver) — all of that is gone. Every one of those
 * steps was a potential failure point (search miss, resolve timeout,
 * Worker downtime, YouTube blocking); removing them is what makes
 * playback reliable, not what makes it fragile. iTunes' previewUrl is
 * a direct CDN link with no dynamic resolution step behind it.
 *
 * Audio only — no video surface/track/PlatformView involved. The
 * visible layer is always the artwork (Ken Burns zoom, see
 * ShortsVisualCard).
 *
 * Completely isolated from AurumAudioEngine — separate ExoPlayer
 * instances, no shared state, no interaction with the main queue at
 * all now (not even a shared resolver class).
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AurumShortsEngine(private val context: Context) {

    companion object {
        private const val TAG = "AurumShortsEngine"
        private const val CLIP_DURATION_MS = 30_000L
    }

    enum class Status { NONE, LOADING, READY, FAILED }

    data class ShortsPlaybackState(
        val status: Status,
        val positionMs: Long,
        val durationMs: Long,
        val isPlaying: Boolean,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var loadJob: Job? = null
    private var preloadJob: Job? = null
    private var clipTimerJob: Job? = null

    private var currentPlayer: ExoPlayer? = null
    private var preloadPlayer: ExoPlayer? = null
    private var preloadedForDedupeKey: String? = null

    private var loadToken = 0

    var onStateChanged: ((ShortsPlaybackState) -> Unit)? = null
    var onAutoAdvance: (() -> Unit)? = null // 30s clip finished OR playback error -> ask Dart to advance

    private fun newPlayer(): ExoPlayer {
        // BUGFIX: iTunes' preview CDN (audio-ssl.itunes.apple.com) will
        // silently stall — never erroring, never reaching STATE_READY —
        // on requests carrying ExoPlayer's blank/default User-Agent.
        // From the UI this looks exactly like "shorts don't play": the
        // card sits on its loading state forever. A real UA plus
        // explicit connect/read timeouts makes the CDN respond
        // immediately, and turns any genuine network failure into a
        // fast onPlayerError() instead of an infinite hang.
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent("Aurum/1.0 (Android; ExoPlayer)")
            .setConnectTimeoutMs(8_000)
            .setReadTimeoutMs(8_000)
            .setAllowCrossProtocolRedirects(true)
        val mediaSourceFactory = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(httpFactory)
        return ExoPlayer.Builder(context)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
    }

    /**
     * Plays [previewUrl] as the active card. If [dedupeKey] matches
     * what was already preloaded, swaps players instantly with zero
     * network wait. Otherwise starts a fresh player immediately —
     * there's no resolve step to wait on, previewUrl is already
     * playable.
     */
    fun playSong(dedupeKey: String, title: String, artist: String, previewUrl: String) {
        loadJob?.cancel()
        val myToken = ++loadToken

        if (preloadedForDedupeKey == dedupeKey && preloadPlayer != null) {
            swapInPreloaded()
            return
        }

        if (previewUrl.isBlank()) {
            emitState(Status.FAILED, 0, 0, false)
            onAutoAdvance?.invoke()
            return
        }

        emitState(Status.LOADING, 0, 0, false)
        tearDownCurrent()
        startPlayback(previewUrl, myToken)
        startLoadWatchdog(myToken)
    }

    /**
     * BUGFIX: if a card never reaches STATE_READY (stuck CDN
     * connection, DNS issue, etc.) it used to just sit on the loading
     * spinner forever with no way out. This gives every card an 8s
     * budget to become playable before we give up and ask Dart to
     * advance, same as an explicit onPlayerError would.
     */
    private fun startLoadWatchdog(myToken: Int) {
        loadJob?.cancel()
        loadJob = scope.launch {
            delay(8_000)
            if (myToken != loadToken) return@launch
            if (currentPlayer?.playbackState == Player.STATE_READY) return@launch
            Log.w(TAG, "Load watchdog fired — clip never became ready, advancing")
            emitState(Status.FAILED, 0, 0, false)
            onAutoAdvance?.invoke()
        }
    }

    private fun startPlayback(previewUrl: String, myToken: Int) {
        val player = newPlayer()
        player.repeatMode = Player.REPEAT_MODE_ONE
        player.volume = 1.0f
        player.setMediaItem(MediaItem.fromUri(previewUrl))
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (myToken != loadToken) return
                when (playbackState) {
                    Player.STATE_READY -> {
                        loadJob?.cancel()
                        emitState(Status.READY, player.currentPosition, player.duration.coerceAtLeast(0), player.isPlaying)
                        startClipTimer(myToken)
                    }
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
    }

    /**
     * Each card is a 30-second clip regardless of the underlying
     * preview's real length (iTunes previews are already ~30s, but
     * this is a hard backstop). Starts counting only once playback is
     * confirmed READY (not from call-time), so a slow-starting stream
     * still gets a fair 30s of actual listening time.
     */
    private fun startClipTimer(myToken: Int) {
        clipTimerJob?.cancel()
        clipTimerJob = scope.launch {
            delay(CLIP_DURATION_MS)
            if (myToken != loadToken) return@launch
            onAutoAdvance?.invoke()
        }
    }

    private fun swapInPreloaded() {
        val old = currentPlayer
        val player = preloadPlayer!!
        preloadPlayer = null
        preloadedForDedupeKey = null

        player.volume = 1.0f
        player.repeatMode = Player.REPEAT_MODE_ONE
        player.play()
        currentPlayer = player
        emitState(Status.READY, player.currentPosition, player.duration.coerceAtLeast(0), true)
        startClipTimer(loadToken)

        old?.let { p ->
            scope.launch { p.release() }
        }
    }

    /** Called by Dart ahead of time with the NEXT card's identity + previewUrl. Buffers audio only, muted. */
    fun preloadNext(dedupeKey: String, title: String, artist: String, previewUrl: String) {
        preloadJob?.cancel()
        if (previewUrl.isBlank()) return

        preloadJob = scope.launch {
            val old = preloadPlayer
            preloadPlayer = null
            old?.let { scope.launch { it.release() } }

            val player = newPlayer()
            player.volume = 0f
            player.repeatMode = Player.REPEAT_MODE_ONE
            player.setMediaItem(MediaItem.fromUri(previewUrl))
            player.prepare()
            player.playWhenReady = false
            preloadPlayer = player
            preloadedForDedupeKey = dedupeKey
        }
    }

    fun togglePlayPause() {
        val p = currentPlayer ?: return
        if (p.isPlaying) p.pause() else p.play()
    }

    fun pause() = currentPlayer?.pause()
    fun resume() = currentPlayer?.play()

    private fun tearDownCurrent() {
        clipTimerJob?.cancel()
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
        clipTimerJob?.cancel()
        currentPlayer?.release()
        preloadPlayer?.release()
        currentPlayer = null
        preloadPlayer = null
        preloadedForDedupeKey = null
        scope.cancel()
    }
}
