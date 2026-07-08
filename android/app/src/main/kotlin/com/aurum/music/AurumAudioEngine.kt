package com.aurum.music

import android.content.Context
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
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
    private val context: Context,
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

    // Lightweight buffer profile: enough to avoid audible stalls on a
    // typical connection, without ExoPlayer greedily decoding 60-90s ahead
    // in the background 24/7 — that constant background decode+network
    // activity was direct battery/RAM pressure, and on low-RAM phones the
    // extra memory held by a 90s/4MB buffer increases the odds of the OS
    // reclaiming memory from the app (which surfaces as "song randomly
    // pauses").
    //
    // FIX (2026-07-07) — "songs keep pausing and restarting on their own,
    // every source including offline": setTargetBufferBytes was previously
    // 1 * 1024 * 1024 (1 MiB). At typical audio bitrates (~40 KB/s for a
    // 320kbps stream), 1 MiB of buffered media is only ~25 SECONDS of
    // audio — far below the 30s maxBufferMs this same LoadControl was
    // trying to hold. Whichever threshold ExoPlayer hits FIRST wins, and
    // size and time were fighting each other: the moment buffered audio
    // exceeded ~25s of an average-bitrate file, the 1 MiB size cap
    // triggered STATE_BUFFERING (a real pause+rebuffer, visible to the
    // user as playback randomly stopping/restarting) even though the
    // 30s time-based ceiling hadn't been reached yet, and even on a fast
    // connection or when reading purely from local disk cache/offline
    // storage (this LoadControl applies to ALL playback through this
    // ExoPlayer instance, network or local — which is why the symptom
    // showed up on Saavn, YouTube, AND offline songs alike, not just slow
    // network conditions).
    //
    // setPrioritizeTimeOverSizeThresholds(true) does NOT fix this — it
    // only decides which threshold ExoPlayer consults FIRST when both are
    // still unmet; it doesn't disable the size cap once buffered bytes
    // actually exceed it.
    //
    // Fix: disable the byte-based cap entirely (-1, ExoPlayer's documented
    // "no limit" sentinel for this field) so only the time-based
    // thresholds (15s min / 30s max) govern buffering. Battery/RAM
    // reasoning from the original comment above is unaffected — a 30s cap
    // was always the actual intended ceiling; the byte cap was firing
    // long before that ceiling was ever reached, defeating its own
    // purpose.
    private val loadControl = DefaultLoadControl.Builder()
        .setBufferDurationsMs(15_000, 30_000, 1_500, 3_000)
        .setTargetBufferBytes(-1)
        .setPrioritizeTimeOverSizeThresholds(true)
        .build()

    // Disables the video renderer entirely. This is what makes it safe for
    // the Worker to sometimes hand back a MUXED (video+audio combined) URL
    // as a fallback — see worker.js _extractMuxed(): YouTube's bot-detection
    // scrutinizes audio-only adaptive formats harder than legacy progressive
    // (muxed) formats, so when audio-only resolution is blocked, the Worker
    // falls back to a muxed itag 18/22 URL instead of failing the song
    // entirely. Without this track selector, ExoPlayer would decode AND
    // render the video track too — wasted CPU/battery and (if a UI surface
    // were ever attached) an unwanted video frame. With it, ExoPlayer still
    // downloads the combined stream (some extra bandwidth vs pure audio-only,
    // unavoidable trade-off of this fallback) but only decodes/outputs the
    // audio track — behaves identically to a normal audio-only URL from the
    // player's perspective. Also applies to plain audio-only URLs (the
    // common case) with zero side effects, since there's no video track to
    // disable in that case anyway.
    private val trackSelector = DefaultTrackSelector(context).apply {
        setParameters(
            buildUponParameters()
                .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)
        )
    }

    // ─────────────────────────────────────────────────────────────────
    // DISK CACHE — ViMusic-inspired (github.com/vfsfitvnm/ViMusic,
    // PlayerService.kt createCacheDataSource()/createDataSourceFactory()).
    //
    // PREVIOUSLY MISSING: every play of every song re-downloaded every
    // byte from scratch, even for a song played 30 seconds ago, even for
    // rewinding within the same song past already-buffered-then-evicted
    // audio. This is pure disk cache with an LRU evictor — once a chunk
    // of a stream is downloaded, it's kept on disk (up to the size cap
    // below) and served instantly from there on any future request that
    // overlaps it, with ZERO network call and ZERO dependency on the
    // stream URL still being valid (googlevideo URLs expire; a cached
    // chunk doesn't care, because it's not re-fetching that URL for
    // data that already exists on disk).
    //
    // Concretely fixes: replaying a recently-played song, seeking
    // backward in the current song, and resuming immediately after a
    // brief network drop — all previously required a full URL
    // re-resolve + full re-download from position 0/wherever ExoPlayer
    // asked; now the on-disk portion serves instantly and only the
    // missing portion (if any) triggers a network fetch.
    //
    // 350MB cap: enough for roughly 60-90 average songs at typical
    // compressed audio bitrates, evicted least-recently-used first.
    // Stored under the app's private cache dir — cleared automatically
    // by Android under storage pressure, no manual cleanup needed, and
    // never counts against the user's "app storage" the way a files-dir
    // cache would.
    // ─────────────────────────────────────────────────────────────────
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private val streamCache: SimpleCache by lazy {
        val cacheDir = java.io.File(context.cacheDir, "aurum_stream_cache")
        val evictor = LeastRecentlyUsedCacheEvictor(350L * 1024 * 1024)
        val databaseProvider = StandaloneDatabaseProvider(context)
        SimpleCache(cacheDir, evictor, databaseProvider)
    }

    // Upstream (network) data source used only for bytes not already on
    // disk. Same connect/read timeouts as ViMusic's working config, and a
    // real browser-style User-Agent — googlevideo.com and Saavn's CDN both
    // serve more consistently to a request that looks like a real browser
    // than to a bare/default HTTP client UA.
    //
    // FIX — "downloaded songs don't play at all": this used to return the
    // bare DefaultHttpDataSource.Factory directly. That factory ONLY
    // understands http:// and https:// schemes. Every downloaded/local
    // song is played via a file:// URI (see resolveFast's isLocal branch
    // below), which this factory has no handler for — ExoPlayer would
    // fail to open the source and the song would never start. Wrapping it
    // in DefaultDataSource.Factory keeps the exact same HTTP behavior for
    // streamed songs (it delegates to the HTTP factory for http/https)
    // while adding the missing file/content/asset/rawresource handlers
    // needed for local playback, with zero change to network timeouts,
    // User-Agent, or the disk cache wrapping below.
    private fun createHttpFactory() = DefaultHttpDataSource.Factory()
        .setConnectTimeoutMs(16_000)
        .setReadTimeoutMs(8_000)
        .setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")

    private fun createUpstreamFactory() = DefaultDataSource.Factory(context, createHttpFactory())

    // Wraps the upstream factory with the disk cache. Every read first
    // checks streamCache; only genuinely missing bytes hit the network.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun createCacheDataSourceFactory() = CacheDataSource.Factory()
        .setCache(streamCache)
        .setUpstreamDataSourceFactory(createUpstreamFactory())

    private val cachedMediaSourceFactory = DefaultMediaSourceFactory(createCacheDataSourceFactory())

    val player: ExoPlayer = ExoPlayer.Builder(context)
        .setLoadControl(loadControl)
        .setTrackSelector(trackSelector)
        // Routes every playback through the disk-cache-backed data source
        // above instead of ExoPlayer's bare default (which re-fetches from
        // network every time with no persistence between plays).
        .setMediaSourceFactory(cachedMediaSourceFactory)
        // FIX — "song randomly pauses for 1-2s then auto-resumes, happens
        // 50+ times during a single playback": this used to be
        // handleAudioFocus = true, which hands ALL focus decisions to
        // Media3's built-in AudioFocusManager. That built-in handler
        // pauses playback on *every* focus request from *any* app,
        // including short-lived, harmless ones — a notification sound, a
        // keyboard click's audio feedback, a background app's brief audio
        // ping. Each one is a full pause+resume cycle, and on a phone
        // with typical notification traffic that adds up to dozens of
        // audible micro-interruptions during a single song — exactly the
        // reported symptom, and it happens identically for YouTube,
        // Saavn, and offline/local songs because it has nothing to do
        // with the source — it is purely an audio-focus routing issue
        // that affects the player globally.
        //
        // Fix: hand focus handling to our own listener (requestAudioFocus
        // below) instead, which distinguishes real, sustained focus loss
        // (an actual phone call, another music app taking over) — where
        // pausing is correct and expected — from the genuinely transient,
        // duckable case (notification sounds, UI click feedback, brief
        // pings from other apps), where it only lowers volume briefly
        // instead of stopping playback outright. That duck-only handling
        // for AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK is what eliminates the
        // repeated pause/resume cycles.
        .setAudioAttributes(
            androidx.media3.common.AudioAttributes.Builder()
                .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                .build(),
            /* handleAudioFocus = */ false,
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

    // ─────────────────────────────────────────────────────────────────
    // Custom audio focus handling (replaces ExoPlayer's built-in one —
    // see the long comment above ExoPlayer.Builder for why).
    // ─────────────────────────────────────────────────────────────────
    private val audioManager: AudioManager by lazy {
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }

    // Remembers whether we auto-paused for a duckable/transient loss so we
    // know whether to auto-resume when focus returns. We deliberately do
    // NOT auto-resume after a genuine AUDIOFOCUS_LOSS (a real phone call,
    // another app taking over playback) — that should require the user to
    // press play again, matching every other music app's behavior. These
    // are two separate flags (not one) specifically so AUDIOFOCUS_GAIN can
    // tell the two cases apart and only auto-resume the transient one.
    private var duckedForTransientFocusLoss = false
    private var pausedForTransientFocusLoss = false
    private var pausedForSustainedFocusLoss = false
    private var preduckVolume = 1f

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Sustained loss — another app has taken over audio
                // entirely (rare: another music player, screen recording,
                // etc). Pause and require an explicit user tap to resume.
                if (player.isPlaying) {
                    pausedForSustainedFocusLoss = true
                    player.pause()
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // A real, but temporary, competing audio need — most
                // commonly an incoming/active phone call. Pause and let
                // AUDIOFOCUS_GAIN below resume it once the call ends —
                // this matches every other music app's behavior for calls.
                if (player.isPlaying) {
                    pausedForTransientFocusLoss = true
                    player.pause()
                }
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // THE actual fix for the reported "pauses 50+ times during
                // a single song" bug: this is the genuinely short-lived
                // case — notification sounds, keyboard/UI click feedback,
                // brief pings from other apps. Android's own contract for
                // this focus type is "you may keep playing, just get
                // quieter if you want" — it explicitly does NOT ask for a
                // pause. Only duck (lower volume briefly), never stop
                // playback. This one change is what eliminates the
                // dozens of audible micro-interruptions per song.
                if (player.isPlaying) {
                    preduckVolume = player.volume
                    player.volume = preduckVolume * 0.3f
                    duckedForTransientFocusLoss = true
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (duckedForTransientFocusLoss) {
                    player.volume = preduckVolume
                    duckedForTransientFocusLoss = false
                }
                if (pausedForTransientFocusLoss) {
                    // Auto-resume — this was a call/transient interruption,
                    // not the user or another app deliberately taking over.
                    player.play()
                    pausedForTransientFocusLoss = false
                }
                // pausedForSustainedFocusLoss is intentionally NOT
                // auto-resumed here — see comment on the field above.
                pausedForSustainedFocusLoss = false
            }
        }
    }

    private var focusRequest: AudioFocusRequest? = null

    private fun requestAudioFocus(): Boolean {
        val attrs = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener(focusChangeListener)
            .build()
        focusRequest = request
        return audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
    }


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

    // FIX (loading-stuck / "10-20s pe atak jaata hai"): between a tap and
    // ExoPlayer actually getting a MediaItem, player.playbackState stays
    // STATE_IDLE the whole time resolveFast() is awaiting the worker/
    // fallback chain (up to ~18s for YouTube + retries). pushState() was
    // reporting "idle" during that entire window, so Dart's _isLoading
    // (state.processingState == "loading"/"buffering") never went true —
    // whatever spinner WAS showing was local tap-state with no backing
    // timeout, not a signal driven by real engine progress. This flag is
    // true for the exact span we're actually resolving, and is reported as
    // processingState "loading" so Dart's existing isLoading getter picks
    // it up with zero call-site changes needed.
    private var isResolving = false

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

        // FIX (loading-stuck, 10-20s no-feedback window): hard ceiling on
        // how long ANY single resolve attempt chain (resolveFast + its
        // internal retries, or findFirstPlayableFrom's walk) is allowed to
        // run before we give up and surface a real error instead of
        // silently continuing to await. Matches the Worker's own max
        // per-request timeout (isUrlAlive/AbortSignal.timeout(7000) plus
        // margin for one retry) for Saavn/Worker-backed sources so
        // Dart-side and native-side "give up" points line up.
        //
        // YouTube resolution runs natively via YoutubeInnertube (InnerTube
        // call + JS cipher decode), which routinely takes longer than the
        // Worker ever did. resolveFast() already gives it an 18s
        // per-attempt budget internally (see perAttemptTimeoutMs below),
        // but this OUTER cap was flatly 8s for every source, silently
        // killing YouTube resolution before its own internal timeout ever
        // got a chance to finish. Bumped so the outer cap can never be
        // tighter than the inner per-attempt budget.
        private const val RESOLVE_HARD_CAP_MS = 8_000L
        private const val RESOLVE_HARD_CAP_YOUTUBE_MS = 20_000L

        private fun hardCapFor(song: NativeSong): Long =
            if (song.source == "youtube") RESOLVE_HARD_CAP_YOUTUBE_MS else RESOLVE_HARD_CAP_MS
    }

    init {
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                pushState()
                if (playbackState == Player.STATE_IDLE) handleIdleEvent()
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                pushState()
                updateTickerState(isPlaying)
                // Request focus the moment anything actually starts
                // playing, from ANY path (initial play, skip, retry,
                // crossfade, restore-after-focus-gain) — not just the
                // play() wrapper below, which several internal call sites
                // bypass by calling player.play() directly. Abandon it
                // once playback genuinely stops, EXCEPT when we ourselves
                // just paused it for a focus loss — abandoning focus there
                // would prevent us from ever hearing AUDIOFOCUS_GAIN to
                // resume (transient case) or would just be redundant
                // (sustained case, where the OS already took focus away).
                if (isPlaying) {
                    requestAudioFocus()
                } else if (!pausedForTransientFocusLoss && !pausedForSustainedFocusLoss) {
                    abandonAudioFocus()
                }
            }
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
        // Ticker starts only when playback actually begins — see
        // updateTickerState(), driven off onIsPlayingChanged above.
    }

    // Ticker job is only alive while something is actually playing. Before,
    // this loop ran unconditionally from init() for the lifetime of the
    // engine — meaning it kept polling every 200ms and pushing a fresh
    // NativeEngineState (→ notifyListeners() → full widget rebuild) even
    // while paused, while the app was backgrounded, or with the screen off.
    // That was the single biggest battery/CPU drain in the app.
    private var tickerJob: Job? = null

    private fun updateTickerState(isPlaying: Boolean) {
        if (isPlaying) {
            startPositionTicker()
        } else {
            tickerJob?.cancel()
            tickerJob = null
        }
    }

    private fun startPositionTicker() {
        if (tickerJob?.isActive == true) return
        tickerJob = scope.launch {
            var last = -1L
            while (isActive) {
                delay(1000)
                val pos = player.currentPosition
                if (pos != last) { last = pos; pushState() }
            }
        }
    }

    private fun pushState() {
        _state.value = NativeEngineState(
            processingState = when {
                // Reported first: a resolve is in flight and ExoPlayer has no
                // MediaItem yet, so player.playbackState would otherwise say
                // "idle" — which Dart reads as "not loading". This is the
                // actual fix for the silent 10-20s gap.
                isResolving && player.playbackState == Player.STATE_IDLE -> "loading"
                player.playbackState == Player.STATE_IDLE -> "idle"
                player.playbackState == Player.STATE_BUFFERING -> "buffering"
                player.playbackState == Player.STATE_READY -> "ready"
                player.playbackState == Player.STATE_ENDED -> "completed"
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

            isResolving = true
            pushState()
            var url = try {
                withTimeoutOrNull(hardCapFor(songs[safeIndex])) { resolveFast(songs[safeIndex], mySession) }
            } catch (e: CancellationException) { throw e }
            if (mySession != playSessionId) return

            var resolvedSong = songs[safeIndex]
            if (url == null) {
                val found = try {
                    withTimeoutOrNull(RESOLVE_HARD_CAP_YOUTUBE_MS) { findFirstPlayableFrom(songs, safeIndex + 1, mySession) }
                } catch (e: CancellationException) { throw e }
                if (mySession != playSessionId) return
                if (found == null) {
                    isResolving = false
                    failPlayback(songs[safeIndex], "stream URL could not be resolved for this song or any other in the queue (last: ${YoutubeInnertube.lastFailureReason})")
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
                isResolving = false
                failPlayback(resolvedSong, e.message ?: "setMediaItem failed")
                return
            }
            isResolving = false
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
            // Belt-and-suspenders: no matter which branch/exception path we
            // took above, isResolving must never be left true past this
            // point — that would leave the spinner spinning forever on the
            // NEXT unrelated state change too, not just this one.
            isResolving = false
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

            // FIX (loading-stuck, 10-20s no-feedback window): this is the
            // direct single-tap path (_SongCard._handleTap -> playSong).
            // isResolving=true the instant we start awaiting the worker,
            // so pushState() reports "loading" for the ENTIRE span below —
            // including the 700ms gap + second resolveFast attempt — not
            // just once ExoPlayer has a MediaItem. Each individual attempt
            // is still wrapped in its own hard cap so one dead attempt
            // can't silently eat the whole budget before the retry runs.
            isResolving = true
            pushState()

            var url = try {
                withTimeoutOrNull(hardCapFor(song)) { resolveFast(song, mySession) }
            } catch (e: CancellationException) { throw e }
            if (mySession != playSessionId) return

            if (url == null) {
                delay(700)
                if (mySession != playSessionId) return
                resolver.invalidate(song)
                url = try {
                    withTimeoutOrNull(hardCapFor(song)) { resolveFast(song, mySession) }
                } catch (e: CancellationException) { throw e }
                if (mySession != playSessionId) return
            }

            if (url == null) {
                isResolving = false
                failPlayback(song, "stream URL could not be resolved after retries, or local file missing (last: ${YoutubeInnertube.lastFailureReason})")
                return
            }

            if (mySession != playSessionId) return
            try {
                setSingleMediaItemInternal(url, song)
            } catch (e: Exception) {
                isResolving = false
                failPlayback(song, e.message ?: "setMediaItem failed")
                return
            }
            isResolving = false
            if (mySession != playSessionId) return

            delay(600)
            reapplySpeed()
            restoreVolume()
            player.play()
        } catch (e: Exception) {
            emitError("playSong failed for \"${song.title}\" — ${e.message}")
        } finally {
            isResolving = false
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
        // Local/downloaded songs: the file is already on disk, nothing to
        // resolve over the network or via the Dart MethodChannel bridge.
        // Returning the file URI directly here means a downloaded song
        // plays instantly and can never get stuck behind a slow/stuck
        // resolver call the way a streamed song can.
        if (song.isLocal) {
            val path = song.localPath
            if (path.isNullOrEmpty()) return null
            return if (path.startsWith("file://") || path.startsWith("content://")) path
            else "file://$path"
        }

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

        // FIX (2026-07-07) — "downloaded songs just sit on loading forever":
        // this used to be a flat `if (songAtIdle.isLocal) return` — correct
        // in intent (never try to re-resolve a local file over the
        // network/Dart bridge, since resolveFast() already returns its
        // file:// URI directly with nothing to "resolve"), but it also
        // meant that if the local file itself was missing, deleted (e.g.
        // storage cleanup, app cache cleared, download never actually
        // completed despite Hive metadata saying "completed"), corrupt, or
        // otherwise unreadable, we returned immediately with NO recovery
        // and NO error surfaced — the player just sat in STATE_IDLE
        // forever, which is exactly what shows up in the UI as an
        // infinite loading spinner with nothing happening.
        //
        // Fix: for local songs, don't re-resolve (still correct — there's
        // nothing to resolve), but DO check whether the file genuinely
        // exists and is non-empty before giving up silently. If it
        // doesn't, treat it exactly like a dead stream: surface a real
        // error and advance the queue past it, same as the network-song
        // recovery path below already does.
        if (songAtIdle.isLocal) {
            val sessionAtIdle = playSessionId
            val path = songAtIdle.localPath?.removePrefix("file://")?.removePrefix("content://")
            val fileOk = try {
                path != null && java.io.File(path).let { it.exists() && it.length() > 0 }
            } catch (_: Exception) {
                false
            }
            if (fileOk) {
                // File is genuinely fine; this STATE_IDLE was likely a
                // transient blip (e.g. brief MediaCodec hiccup) rather than
                // a missing file. Give ExoPlayer one silent nudge instead
                // of leaving it stuck — cheap and avoids a false "skipping
                // song" error for what may just be a one-off glitch.
                delay(400)
                if (sessionAtIdle == playSessionId &&
                    queueSongs.getOrNull(currentIndex)?.id == songAtIdle.id &&
                    player.playbackState == Player.STATE_IDLE
                ) {
                    try {
                        player.prepare()
                        player.play()
                    } catch (_: Exception) { /* falls through to advancePastDeadSong below */ }
                }
                return
            }
            emitError("Downloaded file for \"${songAtIdle.title}\" is missing or unreadable — skipping to next song.", true)
            advancePastDeadSong(songAtIdle, sessionAtIdle)
            return
        }

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

        // FIX (2026-07-07) — same "downloaded song sits on loading forever"
        // bug as handleFreshStartIdle: a local file going idle mid-stream
        // (e.g. a genuinely corrupt/truncated download, or storage
        // reclaiming the underlying file) used to just return here with no
        // recovery. There's nothing to re-resolve for a local file, but we
        // can still detect a broken file and skip it instead of leaving
        // the player stuck.
        if (song.isLocal) {
            val sessionNow = playSessionId
            val path = song.localPath?.removePrefix("file://")?.removePrefix("content://")
            val fileOk = try {
                path != null && java.io.File(path).let { it.exists() && it.length() > 0 }
            } catch (_: Exception) {
                false
            }
            if (fileOk) {
                // Likely a transient decoder hiccup rather than a genuinely
                // broken file — give it one silent retry from the same
                // position instead of leaving playback stuck.
                delay(400)
                if (sessionNow == playSessionId &&
                    queueSongs.getOrNull(currentIndex)?.id == song.id &&
                    player.playbackState == Player.STATE_IDLE
                ) {
                    try {
                        player.prepare()
                        player.seekTo(pos)
                        player.play()
                    } catch (_: Exception) { /* falls through to advancePastDeadSong below */ }
                }
                return
            }
            emitError("Downloaded file for \"${song.title}\" could not continue playing — skipping to next song.", true)
            advancePastDeadSong(song, sessionNow)
            return
        }

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
    fun play() {
        restoredSilently = false
        player.play()
    }
    fun pause() { player.pause() }
    fun stop() {
        try { player.stop() } catch (e: Exception) { }
    }
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
        abandonAudioFocus()
        player.release()
    }
}
