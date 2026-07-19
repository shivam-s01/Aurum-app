package com.aurum.musictv.player

import android.content.ComponentName
import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.aurum.musictv.data.model.Song
import com.aurum.musictv.data.remote.AurumApi
import com.aurum.musictv.data.remote.NetworkResilience
import com.aurum.musictv.settings.SettingsStore
import com.aurum.musictv.sync.SyncRepository
import com.google.common.util.concurrent.MoreExecutors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class PlayerUiState(
    val currentSong: Song? = null,
    val queue: List<Song> = emptyList(),
    val currentIndex: Int = 0,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val isBuffering: Boolean = false,
    /** Non-null right after a tap fails to produce anything playable —
     *  this is what used to be a silent no-op. UI can show this as a
     *  toast/snackbar so a click always gives feedback. */
    val playbackError: String? = null,
    /** True while resolveStreamUrl/retry is in flight for a tap that
     *  hasn't started playing yet — separate from ExoPlayer's own
     *  STATE_BUFFERING (which only exists once a MediaItem is prepared). */
    val isResolving: Boolean = false,
    /** Whether the current song is in the user's Liked Songs — drives the
     *  heart icon on PlayerScreen. Kept here rather than fetched fresh by
     *  the screen so it survives navigating away and back without an
     *  extra round-trip. */
    val isCurrentSongLiked: Boolean = false,
)

/**
 * Talks to the player through a MediaController connected to
 * AurumTvPlaybackService, NOT a private ExoPlayer instance. This matters:
 * it's what gives us background playback that survives navigating away
 * from PlayerScreen, system media-key handling (play/pause/next/prev on
 * the remote), and a proper notification/session — all the things a
 * bare ExoPlayer in an Activity does not get you for free. One
 * MediaController for the whole app lifecycle, created once here.
 */
class PlayerManager(private val context: Context) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var controller: MediaController? = null
    private var controllerFuture: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null
    private var playerListener: Player.Listener? = null

    private val _uiState = MutableStateFlow(PlayerUiState())
    val uiState: StateFlow<PlayerUiState> = _uiState.asStateFlow()

    init {
        val sessionToken = SessionToken(
            context,
            ComponentName(context, AurumTvPlaybackService::class.java),
        )
        val controllerFuture = MediaController.Builder(context, sessionToken).buildAsync()
        this.controllerFuture = controllerFuture
        controllerFuture.addListener({
            controller = controllerFuture.get()
            attachListener()
        }, MoreExecutors.directExecutor())

        // Position ticker — also drives the periodic sync push.
        scope.launch {
            while (true) {
                delay(1000)
                controller?.let { c ->
                    _uiState.value = _uiState.value.copy(positionMs = c.currentPosition.coerceAtLeast(0))
                }
            }
        }
        scope.launch {
            while (true) {
                delay(5000)
                pushStateNow()
            }
        }
    }

    private fun attachListener() {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                _uiState.value = _uiState.value.copy(isPlaying = isPlaying)
                pushStateNow()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                val c = controller ?: return
                _uiState.value = _uiState.value.copy(
                    isBuffering = playbackState == Player.STATE_BUFFERING,
                    durationMs = c.duration.coerceAtLeast(0),
                )
                if (playbackState == Player.STATE_ENDED) {
                    scope.launch { maybeAutoplayNext() }
                }
            }

            // A track that fails mid-playback (expired stream URL, network
            // drop) used to just stop with no UI signal and no recovery —
            // this surfaces it and auto-skips so one bad link in a queue
            // doesn't stall the whole session.
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                _uiState.value = _uiState.value.copy(
                    playbackError = "Couldn't play \"${_uiState.value.currentSong?.title ?: "song"}\" — skipping",
                    isBuffering = false,
                )
                scope.launch { maybeAutoplayNext() }
            }
        }
        playerListener = listener
        controller?.addListener(listener)
    }

    /** Respects the Autoplay setting: if off, playback simply stops at the
     *  end of the current track instead of always continuing into the
     *  next queue item. */
    private suspend fun maybeAutoplayNext() {
        val autoplay = runCatching { SettingsStore.snapshot(context).autoplay }.getOrDefault(true)
        if (autoplay) playNext()
    }

    private fun pushStateNow() {
        val song = _uiState.value.currentSong ?: return
        val c = controller ?: return
        scope.launch {
            SyncRepository.pushPlaybackState(
                song = song,
                positionMs = c.currentPosition,
                isPlaying = c.isPlaying,
            )
        }
    }

    fun playQueue(songs: List<Song>, startIndex: Int) {
        _uiState.value = _uiState.value.copy(queue = songs, currentIndex = startIndex, playbackError = null)
        scope.launch { SyncRepository.pushQueue(songs, startIndex) }
        playIndex(startIndex)
    }

    /** Clears a shown playback error — call after the UI has displayed it
     *  so it doesn't linger in state forever. */
    fun dismissPlaybackError() {
        _uiState.value = _uiState.value.copy(playbackError = null)
    }

    private fun playIndex(index: Int, skipAttempt: Int = 0) {
        val queue = _uiState.value.queue
        val song = queue.getOrNull(index) ?: return
        _uiState.value = _uiState.value.copy(
            currentSong = song,
            currentIndex = index,
            isResolving = true,
            playbackError = null,
        )

        scope.launch {
            // MediaController connects asynchronously (see init{}) — if the
            // user taps a song from Search (or right after app launch)
            // before that connection lands, `controller` is still null.
            // Wait briefly for it instead of bailing immediately.
            val c = awaitController()
            if (c == null) {
                _uiState.value = _uiState.value.copy(
                    isResolving = false,
                    playbackError = "Player not ready — try again",
                )
                return@launch
            }

            if (!NetworkResilience.isOnline(context)) {
                _uiState.value = _uiState.value.copy(
                    isResolving = false,
                    playbackError = "You're offline — check your connection",
                )
                return@launch
            }

            // This was the exact click bug: resolveStreamUrl returning
            // null meant this just `return@launch`ed with the song already
            // set as "current" but nothing actually playing — looked like
            // the click did nothing. AurumApi.resolveStreamUrl now retries
            // + falls back to YouTube internally; if it STILL fails here,
            // auto-skip to the next song (up to 3 tries) instead of
            // leaving the UI stuck.
            val streamUrl = song.streamUrl ?: AurumApi.resolveStreamUrl(song)
            if (streamUrl == null) {
                _uiState.value = _uiState.value.copy(isResolving = false)
                if (skipAttempt < 3 && index + 1 < queue.size) {
                    _uiState.value = _uiState.value.copy(
                        playbackError = "Couldn't play \"${song.title}\" — trying next",
                    )
                    playIndex(index + 1, skipAttempt + 1)
                } else {
                    _uiState.value = _uiState.value.copy(
                        playbackError = "Couldn't play \"${song.title}\" — check your connection",
                    )
                }
                return@launch
            }

            c.setMediaItem(MediaItem.fromUri(streamUrl))
            c.prepare()
            c.play()
            _uiState.value = _uiState.value.copy(isResolving = false)
            SyncRepository.logRecentlyPlayed(song)
            refreshLikedState(song)
        }
    }

    /** Checks whether [song] is already in Liked Songs and updates the
     *  heart-icon state accordingly. Called on every song change so
     *  Player never shows a stale like-state carried over from the
     *  previous track. */
    private fun refreshLikedState(song: Song) {
        scope.launch {
            val liked = runCatching { SyncRepository.isSongLiked(song.id) }.getOrDefault(false)
            // Guard against a slow lookup landing after the user has
            // already skipped to a different song.
            if (_uiState.value.currentSong?.id == song.id) {
                _uiState.value = _uiState.value.copy(isCurrentSongLiked = liked)
            }
        }
    }

    /** Toggles like state for the currently playing song — the "save to
     *  Library" action behind the heart icon on PlayerScreen. Optimistic
     *  UI flip (feels instant on a remote), reconciled with the real
     *  Supabase result — reverted if the write actually fails. */
    fun toggleLikeCurrentSong() {
        val song = _uiState.value.currentSong ?: return
        val wasLiked = _uiState.value.isCurrentSongLiked
        _uiState.value = _uiState.value.copy(isCurrentSongLiked = !wasLiked)
        scope.launch {
            runCatching {
                if (wasLiked) SyncRepository.unlikeSong(song.id) else SyncRepository.likeSong(song)
            }.onFailure {
                if (_uiState.value.currentSong?.id == song.id) {
                    _uiState.value = _uiState.value.copy(isCurrentSongLiked = wasLiked)
                }
            }
        }
    }

    /** Waits up to ~3s for the MediaController to finish connecting
     *  (typically instant, but never guaranteed by the time the first
     *  song click can happen). Returns null if it still isn't ready —
     *  callers should treat that as "can't play right now" rather than
     *  retrying forever. */
    private suspend fun awaitController(): MediaController? {
        repeat(30) {
            controller?.let { return it }
            delay(100)
        }
        return controller
    }

    fun togglePlayPause() {
        val c = controller ?: return
        if (c.isPlaying) c.pause() else c.play()
    }

    fun playNext() {
        val state = _uiState.value
        val nextIndex = state.currentIndex + 1
        if (nextIndex < state.queue.size) playIndex(nextIndex)
    }

    fun playPrevious() {
        val state = _uiState.value
        val prevIndex = (state.currentIndex - 1).coerceAtLeast(0)
        playIndex(prevIndex)
    }

    fun seekTo(positionMs: Long) {
        controller?.seekTo(positionMs)
    }

    /** Resumes exactly what mobile was last playing — called from the
     *  "Resume on TV" banner action on Home. */
    fun resumeFrom(song: Song, positionMs: Long) {
        playQueue(listOf(song), 0)
        scope.launch {
            delay(500) // let prepare() land first
            controller?.seekTo(positionMs)
        }
    }

    fun release() {
        // Was leaking: the position-ticker and sync-push `while(true)`
        // coroutines launched in init{} were never cancelled here, so
        // they kept running (and the Player.Listener stayed attached)
        // even after MainActivity.onDestroy() called this. On a 1GB-RAM
        // TV box that's a slow background leak every relaunch.
        scope.cancel()
        playerListener?.let { controller?.removeListener(it) }
        playerListener = null
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controller = null
        controllerFuture = null
    }
}

