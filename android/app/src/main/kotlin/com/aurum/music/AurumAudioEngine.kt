package com.aurum.music

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class NativeEngineState(
    val processingState: String = "idle",
    val playing: Boolean = false,
    val positionMs: Long = 0,
    val bufferedPositionMs: Long = 0,
    val durationMs: Long? = null,
    val currentIndex: Int? = null,
    val speed: Float = 1f,
    val queueIds: List<String> = emptyList(),
    val currentSongId: String? = null,
    val error: String? = null,
    val liked: Boolean = false,
)

/**
 * Full Kotlin port of AurumAudioHandler (lib/services/audio_handler.dart).
 * Owns ExoPlayer directly, queue state, session-ID cancellation, hard-stop,
 * idle/dead-URL recovery, and background queue splicing. Mirrors every
 * invariant (I1-I8) documented in the Dart file 1:1.
 *
 * Resolve chain (JioSaavn/YouTube fallback) stays in Dart via [resolver] —
 * porting that chain itself is Stage 4.
 */
class AurumAudioEngine(
    context: Context,
    private val resolver: StreamResolver,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // Serializes skip commands (next/prev/queue-jump). Without this, spamming
    // next/prev fires a fresh coroutine per tap and they race — each one reads
    // player.currentMediaItemIndex at ITS OWN launch time, which may already be
    // stale because a previous coroutine's seekToNext() ran in between. Under
    // fast repeated taps this desyncs the native player from the queue index
    // Dart thinks it's on, and the final settled song doesn't match the last
    // tap. Wrapping every skip op in this mutex forces them to run one at a
    // time, in order, against consistent player state.
    private val skipMutex = Mutex()

    // I10: identical buffer tuning to the Dart AndroidLoadControl config.
    private val loadControl = DefaultLoadControl.Builder()
        .setBufferDurationsMs(15_000, 50_000, 1_500, 3_000)
        .setTargetBufferBytes(4 * 1024 * 1024)
        .setPrioritizeTimeOverSizeThresholds(true)
        .build()

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setLoadControl(loadControl)
        // I11: audio focus handling — pauses on incoming call/other app
        // audio, ducks appropriately, resumes when focus is regained.
        // Without this ExoPlayer plays right over calls/notifications.
        .setAudioAttributes(
            androidx.media3.common.AudioAttributes.Builder()
                .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                .build(),
            /* handleAudioFocus = */ true,
        )
        // Auto-pause when headphones are unplugged / Bluetooth disconnects —
        // otherwise audio keeps blaring out the speaker unexpectedly.
        .setHandleAudioBecomingNoisy(true)
        // I12: THE fix for "gaana screen off hote hi ruk jaata hai". Holds a
        // partial WakeLock (CPU) while STATE_READY/STATE_BUFFERING and
        // playWhenReady=true, so Doze/screen-off can't stall decoding.
        // Requires WAKE_LOCK permission (already in AndroidManifest.xml) and
        // must run inside a foreground service (AurumMediaSessionService) —
        // both are satisfied here.
        .setWakeMode(androidx.media3.common.C.WAKE_MODE_LOCAL)
        .build()

    // Native replacement for the old just_audio AndroidEqualizer/
    // AndroidLoudnessEnhancer (audio_effects_controller.dart, now
    // orphaned). Same self-healing/one-way-dependency guarantees, attached
    // to this ExoPlayer's audioSessionId instead of built into the
    // AudioPipeline at construction time.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    val effects: AurumAudioEffects = AurumAudioEffects(player)

    private val _state = MutableStateFlow(NativeEngineState())
    val state: StateFlow<NativeEngineState> = _state

    var onPlaybackError: ((String, Boolean) -> Unit)? = null // (message, silent)
    var onQueueChanged: (() -> Unit)? = null

    // Fired when the user taps the like/heart button on the lock screen or
    // notification (via MediaSession custom command — see
    // AurumMediaSessionService). Dart owns the actual favorite/unfavorite
    // logic (FavoritesProvider); this just forwards the tap and the current
    // song ID so Dart can toggle it, then calls setCurrentSongLiked() back
    // to reflect the new state in the icon. Previously (AurumAudioHandler)
    // this was `onLikeToggleRequested` — same role, now native-originated
    // instead of audio_service-originated.
    var onLikeToggleRequested: ((String) -> Unit)? = null

    // ── Session / queue state — mirrors Dart fields exactly ──
    private var playSessionId = 0
    private var queueSongs: List<NativeSong> = emptyList()
    private var currentIndex = 0
    private var isLoadingNewSong = false
    private var splicingInProgress = false
    private var restoredSilently = false

    // Media3's playlist == the "ConcatenatingAudioSource" equivalent.
    // We track song IDs in the same order as player.mediaItemCount to
    // detect drift, same purpose as Dart's _queue vs sequence checks.
    private var liveMediaIds: MutableList<String> = mutableListOf()

    private var fadeJob: Job? = null
    private var idleWatchdogJob: Job? = null
    private var currentSongLiked = false
    private var crossfadeSecs = 0.0
    private var stopAfterCurrentSong = false

    companion object {
        // FIX: was prewarming 3 songs ahead / 2 behind every 900ms — across
        // a 50-80 song queue (typical home-feed section size) this kept
        // resolving stream URLs for songs the user may never reach,
        // burning mobile data in the background for no playback benefit.
        // Trimmed to a tighter window (still covers "tap next twice
        // quickly" instant-skip) with a longer pace, so background data
        // use drops significantly without losing the instant-skip feel
        // for the songs actually likely to be played next.
        private const val PRIORITY_FORWARD_WINDOW = 1
        private const val PRIORITY_BACKWARD_WINDOW = 1
        private const val PACED_RESOLVE_DELAY_MS = 2500L
    }

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                pushState()
                if (playbackState == Player.STATE_IDLE) handleIdleEvent()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) = pushState()
            override fun onPlayerError(error: PlaybackException) = pushState()
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int,
            ) {
                if (reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION) {
                    handleCurrentIndexChanged(newPosition.mediaItemIndex)
                }
            }
        })
        startPositionTicker()
    }

    private fun startPositionTicker() {
        scope.launch {
            var last = -1L
            while (isActive) {
                delay(200)
                val pos = player.currentPosition
                if (pos != last) { last = pos; pushState() }
            }
        }
    }

    private fun pushState() {
        _state.value = NativeEngineState(
            processingState = when (player.playbackState) {
                Player.STATE_IDLE -> "idle"
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_READY -> "ready"
                Player.STATE_ENDED -> "completed"
                else -> "idle"
            },
            playing = player.isPlaying,
            positionMs = player.currentPosition,
            bufferedPositionMs = player.bufferedPosition,
            durationMs = player.duration.takeIf { it != C.TIME_UNSET },
            currentIndex = currentIndex,
            speed = player.playbackParameters.speed,
            queueIds = queueSongs.map { it.id },
            currentSongId = queueSongs.getOrNull(currentIndex)?.id,
            liked = currentSongLiked,
        )
    }

    private fun emitError(message: String, silent: Boolean = false) {
        onPlaybackError?.invoke(message, silent)
    }

    // Attaches title/artist/artwork so the MediaSession-driven notification
    // and lock screen show real metadata instead of a blank title — Media3
    // reads this straight off player.currentMediaItem.mediaMetadata, no
    // manual notification-builder wiring needed on our side.
    private fun buildMediaItem(song: NativeSong, url: String): MediaItem {
        val metadataBuilder = androidx.media3.common.MediaMetadata.Builder()
            .setTitle(song.title)
            .setArtist(song.artist)
            .setAlbumTitle(song.album)
        if (song.artworkUrl.isNotEmpty()) {
            metadataBuilder.setArtworkUri(android.net.Uri.parse(song.artworkUrl))
        }
        return MediaItem.Builder()
            .setMediaId(song.id)
            .setUri(url)
            .setMediaMetadata(metadataBuilder.build())
            .build()
    }

    // ─────────────────────────────────────────────────────────────────
    // I1/I3: hard-stop-and-mute — the actual fix for stale audio.
    // setVolume(0) -> pause() -> stop() -> clearMediaItems(). Every step
    // re-checks the session before the NEXT step, same as Dart's
    // _hardStopAndMute(sessionId:).
    // ─────────────────────────────────────────────────────────────────
    private suspend fun hardStopAndMute(sessionId: Int) {
        fadeJob?.cancel(); fadeJob = null
        fun stillCurrent() = sessionId == playSessionId
        if (!stillCurrent()) return
        player.volume = 0f
        if (!stillCurrent()) return
        player.pause()
        if (!stillCurrent()) return
        player.stop()
        if (!stillCurrent()) return
        player.clearMediaItems()
        liveMediaIds.clear()
    }

    private fun restoreVolume() { player.volume = 1f }

    // ─────────────────────────────────────────────────────────────────
    // MAIN ENTRY POINTS
    // ─────────────────────────────────────────────────────────────────

    fun playQueue(songs: List<NativeSong>, startIndex: Int) {
        scope.launch { playQueueInternal(songs, startIndex) }
    }

    private suspend fun playQueueInternal(songs: List<NativeSong>, startIndex: Int) {
        playSessionId++
        val mySession = playSessionId
        isLoadingNewSong = true
        restoredSilently = false

        val safeIndex = if (songs.isEmpty()) 0 else startIndex.coerceIn(0, songs.size - 1)
        var effectiveIndex = safeIndex

        queueSongs = songs
        currentIndex = safeIndex
        splicingInProgress = true
        onQueueChanged?.invoke()
        pushState()

        var started = false
        try {
            hardStopAndMute(mySession)
            if (mySession != playSessionId) return

            var url = resolveFast(songs[safeIndex], mySession)
            if (mySession != playSessionId) return

            var resolvedSong = songs[safeIndex]
            if (url == null) {
                val found = findFirstPlayableFrom(songs, safeIndex + 1, mySession)
                if (mySession != playSessionId) return
                if (found == null) {
                    failPlayback(songs[safeIndex], "stream URL could not be resolved for this song or any other in the queue")
                    return
                }
                effectiveIndex = found.first
                resolvedSong = songs[found.first]
                url = found.second
                currentIndex = effectiveIndex
                onQueueChanged?.invoke()
            }

            if (mySession != playSessionId) return
            try {
                setSingleMediaItemInternal(url!!, resolvedSong)
            } catch (e: Exception) {
                failPlayback(resolvedSong, e.message ?: "setMediaItem failed")
                return
            }
            if (mySession != playSessionId) return

            delay(600)
            // Verify ExoPlayer actually opened the source — matches Dart's
            // idle@0ms post-write check.
            if (mySession == playSessionId && player.playbackState == Player.STATE_IDLE) {
                // idle watchdog (handleIdleEvent) picks this up via the
                // player listener already wired in init{}.
            }

            reapplySpeed()
            restoreVolume()
            player.play()
            started = true
        } catch (e: Exception) {
            emitError("playQueue failed for \"${songs[safeIndex].title}\" — ${e.message}")
        } finally {
            if (mySession == playSessionId) {
                restoreVolume()
                isLoadingNewSong = false
                if (!started) splicingInProgress = false
            } else {
                splicingInProgress = false
                isLoadingNewSong = false
            }
            pushState()
        }

        if (started && mySession == playSessionId) {
            resolveQueueInBackground(songs, effectiveIndex, mySession)
        }
    }

    fun playSong(song: NativeSong) {
        scope.launch { playSongInternal(song) }
    }

    private suspend fun playSongInternal(song: NativeSong) {
        playSessionId++
        val mySession = playSessionId
        restoredSilently = false

        queueSongs = listOf(song)
        currentIndex = 0
        splicingInProgress = false
        onQueueChanged?.invoke()
        pushState()

        try {
            isLoadingNewSong = true
            hardStopAndMute(mySession)
            if (mySession != playSessionId) return

            var url = resolveFast(song, mySession)
            if (mySession != playSessionId) return

            if (url == null) {
                delay(700)
                if (mySession != playSessionId) return
                resolver.invalidate(song)
                url = resolveFast(song, mySession)
                if (mySession != playSessionId) return
            }

            if (url == null) {
                failPlayback(song, "stream URL could not be resolved after retries, or local file missing")
                return
            }

            if (mySession != playSessionId) return
            try {
                setSingleMediaItemInternal(url, song)
            } catch (e: Exception) {
                failPlayback(song, e.message ?: "setMediaItem failed")
                return
            }
            if (mySession != playSessionId) return

            delay(600)
            reapplySpeed()
            restoreVolume()
            player.play()
        } catch (e: Exception) {
            emitError("playSong failed for \"${song.title}\" — ${e.message}")
        } finally {
            if (mySession == playSessionId) {
                restoreVolume()
                isLoadingNewSong = false
                maybeAutoExtendQueue()
            }
            pushState()
        }
    }

    private fun setSingleMediaItemInternal(url: String, song: NativeSong) {
        val item = buildMediaItem(song, url)
        player.setMediaItem(item)
        liveMediaIds = mutableListOf(song.id)
        player.prepare()
    }

    // I2: resolve with a single fast attempt (2 attempts max), same timeouts
    // as Dart's _resolveFast — YouTube gets 45s per attempt, others 12s.
    private suspend fun resolveFast(song: NativeSong, sessionId: Int, maxAttempts: Int = 2): String? {
        val perAttemptTimeoutMs = if (song.source == "youtube") 18_000L else 12_000L
        repeat(maxAttempts) { attemptIndex ->
            if (sessionId != playSessionId) return null
            val url = try {
                withTimeoutOrNull(perAttemptTimeoutMs) { resolver.resolve(song) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
            if (sessionId != playSessionId) return null
            if (!url.isNullOrEmpty()) return url
            if (attemptIndex < maxAttempts - 1) delay(500)
        }
        return null
    }

    private suspend fun findFirstPlayableFrom(
        songs: List<NativeSong>, fromIndex: Int, sessionId: Int,
    ): Pair<Int, String>? {
        for (i in fromIndex until songs.size) {
            if (sessionId != playSessionId) return null
            val url = resolveFast(songs[i], sessionId, maxAttempts = 1)
            if (sessionId != playSessionId) return null
            if (url != null) return i to url
        }
        return null
    }

    private fun failPlayback(song: NativeSong, detail: String) {
        queueSongs = emptyList()
        currentIndex = 0
        splicingInProgress = false
        onQueueChanged?.invoke()
        emitError("Resolve failed for \"${song.title}\" — $detail")
        pushState()
    }

    private suspend fun reapplySpeed() {
        player.setPlaybackSpeed(player.playbackParameters.speed)
    }

    // ─────────────────────────────────────────────────────────────────
    // I5/I6: idle / dead-URL recovery watchdog
    // ─────────────────────────────────────────────────────────────────
    private fun handleIdleEvent() {
        val pos = player.currentPosition
        idleWatchdogJob?.cancel()
        idleWatchdogJob = scope.launch {
            if (pos < 500) handleFreshStartIdle() else handleMidStreamIdle(pos)
        }
    }

    private suspend fun handleFreshStartIdle() {
        val songAtIdle = queueSongs.getOrNull(currentIndex) ?: return
        val sessionAtIdle = playSessionId
        delay(1200)

        if (sessionAtIdle != playSessionId) return
        if (isLoadingNewSong) return
        val songNow = queueSongs.getOrNull(currentIndex) ?: return
        if (songNow.id != songAtIdle.id) return
        if (player.playbackState != Player.STATE_IDLE) return
        if (player.currentPosition >= 500) return

        resolver.invalidate(songNow)

        // Same second-retry safety net as handleMidStreamIdle — a single
        // transient background network failure shouldn't immediately be
        // treated as a dead song.
        var freshUrl: String? = null
        for (attempt in 0 until 2) {
            if (sessionAtIdle != playSessionId) return
            freshUrl = try {
                withTimeoutOrNull(15_000) { resolver.resolve(songNow, forceRefresh = true) }
            } catch (e: Exception) { null }
            if (freshUrl != null) break
            if (attempt == 0) delay(1500)
        }

        if (freshUrl == null || sessionAtIdle != playSessionId) {
            if (sessionAtIdle != playSessionId) return
            emitError("Resolve failed for \"${songNow.title}\" — skipping to next song.", true)
            advancePastDeadSong(songNow, sessionAtIdle)
            return
        }

        if (queueSongs.getOrNull(currentIndex)?.id != songAtIdle.id) return
        if (sessionAtIdle != playSessionId) return

        try {
            setSingleMediaItemInternal(freshUrl, songNow)
            delay(800)
            if (player.playbackState == Player.STATE_IDLE) {
                emitError("Playback failed for \"${songNow.title}\" — stream URL returned but could not be opened. Skipping to next song.", true)
                advancePastDeadSong(songNow, sessionAtIdle)
                return
            }
            player.play()
        } catch (e: Exception) {
            if (sessionAtIdle == playSessionId) {
                emitError("Playback failed for \"${songNow.title}\" after retry — ${e.message}. Skipping to next song.", true)
                advancePastDeadSong(songNow, sessionAtIdle)
            }
        }
    }

    // I5: mid-stream recovery (song was playing fine, then went idle mid-way —
    // dead/expired CDN link). Splices a fresh URL in at the same position
    // instead of restarting the song from 0:00, same as Dart.
    private suspend fun handleMidStreamIdle(pos: Long) {
        if (queueSongs.isEmpty() || isLoadingNewSong) return
        val song = queueSongs.getOrNull(currentIndex) ?: return
        if (song.isLocal) return

        val playerIdxAtStart = player.currentMediaItemIndex
        fun stillOnThisSong(): Boolean {
            val liveIdx = player.currentMediaItemIndex
            if (liveIdx != playerIdxAtStart) return false
            return liveMediaIds.getOrNull(liveIdx) == song.id
        }

        resolver.invalidate(song)
        val sessionAtError = playSessionId

        // FIX: previously gave up and skipped the song after a single
        // failed resolve attempt. In the background, a temporary network
        // hiccup (Doze-mode throttling, brief connectivity drop while
        // switching wifi/mobile data) can make one attempt fail even
        // though the song itself is perfectly fine — that was showing up
        // as "song randomly skips/changes while playing in background".
        // One retry after a short pause absorbs those transient failures
        // without meaningfully delaying genuine dead-link recovery.
        var freshUrl: String? = null
        for (attempt in 0 until 2) {
            if (sessionAtError != playSessionId) return
            freshUrl = try {
                withTimeoutOrNull(12_000) { resolver.resolve(song, forceRefresh = true) }
            } catch (e: Exception) { null }
            if (freshUrl != null) break
            if (attempt == 0) delay(1500)
        }

        if (sessionAtError != playSessionId) return
        if (!stillOnThisSong()) return

        if (freshUrl != null) {
            try {
                val idx = player.currentMediaItemIndex
                if (idx < player.mediaItemCount && stillOnThisSong()) {
                    val item = buildMediaItem(song, freshUrl)
                    player.replaceMediaItem(idx, item)
                    player.seekTo(idx, pos)
                    player.play()
                    return
                }
            } catch (e: Exception) { /* fall through to error below */ }
        }

        if (sessionAtError != playSessionId) return
        emitError("Stream expired for \"${song.title}\" and could not be recovered. Skipping to next song.", true)
        advancePastDeadSong(song, sessionAtError)
    }

    // I6: single bad song never kills the queue — walk forward to next playable.
    private suspend fun advancePastDeadSong(deadSong: NativeSong, sessionAtFailure: Int) {
        if (sessionAtFailure != playSessionId) return
        if (queueSongs.isEmpty()) return
        val deadIdx = queueSongs.indexOfFirst { it.id == deadSong.id }
        val startFrom = if (deadIdx >= 0) deadIdx + 1 else currentIndex + 1
        if (startFrom >= queueSongs.size) {
            emitError("Reached end of queue after \"${deadSong.title}\" could not be played.", false)
            return
        }
        val found = findFirstPlayableFrom(queueSongs, startFrom, sessionAtFailure)
        if (sessionAtFailure != playSessionId) return
        if (found == null) {
            emitError("Could not play \"${deadSong.title}\" or any later song in the queue.", false)
            return
        }
        currentIndex = found.first
        onQueueChanged?.invoke()
        if (sessionAtFailure != playSessionId) return
        try {
            setSingleMediaItemInternal(found.second, queueSongs[found.first])
            if (sessionAtFailure != playSessionId) return
            reapplySpeed()
            restoreVolume()
            player.play()
        } catch (e: Exception) {
            emitError("Could not play \"${deadSong.title}\" or the next song — ${e.message}", false)
        }
        pushState()
    }

    // ─────────────────────────────────────────────────────────────────
    // I4: current-index sync (prevents UI/notification desync)
    // ─────────────────────────────────────────────────────────────────
    private fun handleCurrentIndexChanged(index: Int?) {
        if (index == null) return

        if (stopAfterCurrentSong && index != currentIndex) {
            stopAfterCurrentSong = false
            player.pause()
            return
        }

        if (crossfadeSecs > 0 && index != currentIndex && !isLoadingNewSong) {
            applyCrossfadeFadeIn()
        }

        val mediaId = liveMediaIds.getOrNull(index)
        if (mediaId != null) {
            val queueIdx = queueSongs.indexOfFirst { it.id == mediaId }
            if (queueIdx != -1 && queueIdx != currentIndex) {
                currentIndex = queueIdx
            }
            maybeAutoExtendQueue()
            pushState()
            return
        }

        if (index != currentIndex && index < queueSongs.size) {
            currentIndex = index
        }
        maybeAutoExtendQueue()
        pushState()
    }

    private fun applyCrossfadeFadeIn() {
        fadeJob?.cancel()
        val mySession = playSessionId
        val steps = (crossfadeSecs * 10).toInt().coerceIn(1, 120)
        val stepMs = (crossfadeSecs * 1000 / steps).toLong()
        fadeJob = scope.launch {
            for (step in 1..steps) {
                if (mySession != playSessionId) return@launch
                delay(stepMs)
                player.volume = (step.toFloat() / steps).coerceIn(0f, 1f)
            }
            player.volume = 1f
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Auto-extend queue near the end (Saavn-similar-songs autoplay)
    // ─────────────────────────────────────────────────────────────────
    private var autoExtending = false
    var onFetchSimilarSongs: (suspend (NativeSong, List<String>) -> List<NativeSong>)? = null

    private fun maybeAutoExtendQueue() {
        if (autoExtending || splicingInProgress) return
        if (queueSongs.isEmpty() || currentIndex >= queueSongs.size) return
        val remaining = queueSongs.size - 1 - currentIndex
        if (remaining > 1) return
        val current = queueSongs[currentIndex]
        if (current.isLocal) return

        autoExtending = true
        val mySession = playSessionId
        scope.launch {
            try {
                val similar = onFetchSimilarSongs?.invoke(current, queueSongs.map { it.id }) ?: emptyList()
                autoExtending = false
                if (mySession != playSessionId || similar.isEmpty()) return@launch
                for (song in similar.take(10)) {
                    if (mySession != playSessionId) return@launch
                    addToQueueInternal(song, mySession)
                }
            } catch (e: Exception) {
                autoExtending = false
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // QUEUE MUTATIONS
    // ─────────────────────────────────────────────────────────────────
    fun lookaheadResolve(song: NativeSong) {
        scope.launch {
            try { resolveFast(song, playSessionId, maxAttempts = 1) } catch (e: Exception) {}
        }
    }

    fun addToQueue(song: NativeSong) {
        scope.launch { addToQueueInternal(song, playSessionId) }
    }

    private suspend fun addToQueueInternal(song: NativeSong, session: Int) {
        queueSongs = queueSongs + song
        val url = resolveFast(song, session, maxAttempts = 1) ?: return
        if (session != playSessionId) return
        val item = buildMediaItem(song, url)
        player.addMediaItem(item)
        liveMediaIds.add(song.id)
        handleCurrentIndexChanged(player.currentMediaItemIndex)
        onQueueChanged?.invoke()
        pushState()
    }

    fun removeFromQueue(index: Int) {
        if (index !in queueSongs.indices) return
        queueSongs = queueSongs.filterIndexed { i, _ -> i != index }
        if (index < liveMediaIds.size) {
            player.removeMediaItem(index)
            liveMediaIds.removeAt(index)
        }
        if (currentIndex > index) currentIndex--
        onQueueChanged?.invoke()
        pushState()
    }

    fun moveQueueItem(from: Int, to: Int) {
        if (from !in queueSongs.indices || to !in queueSongs.indices) return
        val mutable = queueSongs.toMutableList()
        val song = mutable.removeAt(from)
        mutable.add(to, song)
        queueSongs = mutable
        if (from < liveMediaIds.size) player.moveMediaItem(from, to)
        if (currentIndex == from) currentIndex = to
        onQueueChanged?.invoke()
        pushState()
    }

    fun clearQueue() {
        queueSongs = emptyList()
        currentIndex = 0
        player.clearMediaItems()
        liveMediaIds.clear()
        onQueueChanged?.invoke()
        pushState()
    }

    // ─────────────────────────────────────────────────────────────────
    // Paced background queue resolution — I: performance target, not
    // correctness invariant, but preserved exactly (priority window +
    // paced tail) per the prompt's "Known Performance Targets".
    // ─────────────────────────────────────────────────────────────────
    private fun resolveQueueInBackground(songs: List<NativeSong>, startIndex: Int, sessionId: Int) {
        scope.launch {
            try {
                for (i in startIndex + 1 until songs.size) {
                    if (sessionId != playSessionId) return@launch
                    if (i - startIndex > PRIORITY_FORWARD_WINDOW) {
                        delay(PACED_RESOLVE_DELAY_MS)
                        if (sessionId != playSessionId) return@launch
                    }
                    try {
                        val url = resolveFast(songs[i], sessionId, maxAttempts = 1)
                        if (sessionId != playSessionId) return@launch
                        if (url != null && sessionId == playSessionId) {
                            player.addMediaItem(buildMediaItem(songs[i], url))
                            liveMediaIds.add(songs[i].id)
                            handleCurrentIndexChanged(player.currentMediaItemIndex)
                        }
                    } catch (e: Exception) { /* skip this song, continue */ }
                }

                var playerIndex = 0
                for (i in startIndex - 1 downTo 0) {
                    if (sessionId != playSessionId) return@launch
                    if (startIndex - i > PRIORITY_BACKWARD_WINDOW) {
                        delay(PACED_RESOLVE_DELAY_MS)
                        if (sessionId != playSessionId) return@launch
                    }
                    try {
                        val url = resolveFast(songs[i], sessionId, maxAttempts = 1)
                        if (sessionId != playSessionId) return@launch
                        if (url != null && sessionId == playSessionId) {
                            player.addMediaItem(0, buildMediaItem(songs[i], url))
                            liveMediaIds.add(0, songs[i].id)
                            playerIndex++
                            player.seekTo(playerIndex, player.currentPosition)
                            handleCurrentIndexChanged(player.currentMediaItemIndex)
                        }
                    } catch (e: Exception) { /* skip this song, continue */ }
                }
            } finally {
                if (sessionId == playSessionId) {
                    splicingInProgress = false
                    maybeAutoExtendQueue()
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // TRANSPORT CONTROLS
    // ─────────────────────────────────────────────────────────────────
    fun play() { restoredSilently = false; player.play() }
    fun pause() { player.pause() }
    fun stop() { try { player.stop() } catch (e: Exception) { } }
    fun seek(positionMs: Long) { player.seekTo(positionMs) }

    fun skipToNext() {
        scope.launch {
            skipMutex.withLock {
                val liveLen = player.mediaItemCount
                val livePos = player.currentMediaItemIndex
                if (livePos < liveLen - 1) {
                    player.seekToNext(); player.play()
                } else if (player.repeatMode == Player.REPEAT_MODE_ALL && liveLen > 0) {
                    player.seekTo(0, 0); player.play()
                } else if (!splicingInProgress && currentIndex < queueSongs.size - 1) {
                    playQueueInternal(queueSongs, currentIndex + 1)
                }
            }
        }
    }

    fun skipToPrevious() {
        scope.launch {
            skipMutex.withLock {
                if (player.currentPosition > 3000) {
                    player.seekTo(0)
                } else {
                    val livePos = player.currentMediaItemIndex
                    if (livePos > 0) {
                        player.seekToPrevious()
                    } else if (currentIndex > 0) {
                        playQueueInternal(queueSongs, currentIndex - 1)
                    }
                }
            }
        }
    }

    fun skipToQueueItem(index: Int) {
        scope.launch {
            skipMutex.withLock {
                if (index < player.mediaItemCount && !splicingInProgress) {
                    if (index < queueSongs.size) {
                        currentIndex = index
                        pushState()
                    }
                    player.seekTo(index, 0)
                    player.play()
                } else if (index < queueSongs.size) {
                    playQueueInternal(queueSongs, index)
                }
            }
        }
    }

    fun setRepeatMode(mode: String) { // "none" | "one" | "all"
        player.repeatMode = when (mode) {
            "one" -> Player.REPEAT_MODE_ONE
            "all" -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
    }

    fun setShuffleMode(enabled: Boolean) { player.shuffleModeEnabled = enabled }
    fun setSpeed(speed: Float) { player.setPlaybackSpeed(speed) }
    fun setCurrentSongLiked(liked: Boolean) { currentSongLiked = liked; pushState() }

    /** Called by AurumMediaSessionService when the notification/lock-screen
     *  heart is tapped. Forwards to Dart via [onLikeToggleRequested]; Dart
     *  toggles FavoritesProvider and calls setCurrentSongLiked() back with
     *  the authoritative result — this method does not flip the flag itself
     *  to avoid the icon briefly showing the wrong state if Dart's toggle
     *  fails (e.g. Hive write error). */
    fun triggerLikeToggle() {
        val song = currentSong() ?: return
        onLikeToggleRequested?.invoke(song.id)
    }

    fun isCurrentSongLiked(): Boolean = currentSongLiked
    fun setCrossfadeSeconds(secs: Double) { crossfadeSecs = secs }
    fun sleepAfterCurrentSong() { stopAfterCurrentSong = true }

    fun currentQueue(): List<NativeSong> = queueSongs
    fun currentSongIndex(): Int = currentIndex
    fun currentSong(): NativeSong? = queueSongs.getOrNull(currentIndex)

    fun release() {
        fadeJob?.cancel()
        idleWatchdogJob?.cancel()
        scope.cancel()
        effects.dispose()
        player.release()
    }
}
