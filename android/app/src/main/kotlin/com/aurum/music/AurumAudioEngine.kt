package com.aurum.music

import android.app.ActivityManager
import android.content.Context
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.cast.CastPlayer
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
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
    // True while the current song's stream URL has been retrying to
    // resolve for longer than a normal connection should ever need, but
    // the engine has NOT given up — it keeps retrying in the background
    // for as long as there's any network path at all (see
    // hasAnyNetworkConnection/RESOLVE_PATIENCE_THRESHOLD_MS). Dart uses
    // this purely to show a "check your connection" message; it is never
    // a signal to skip or change songs — only the user's own Next/Previous
    // action does that.
    val resolveTakingLong: Boolean = false,
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

    // BUG FIX ("tap a queue item, wrong song plays / next click plays out
    // of order"): addToQueue/removeFromQueue/moveQueueItem each launched
    // their own independent coroutine with NO serialization between them.
    // addToQueue in particular returned success to Dart the instant the
    // coroutine was launched — NOT once player.addMediaItem() had actually
    // run — so a fast-following moveQueueItem (e.g. from playNext()) could
    // execute against the native ExoPlayer media-item list BEFORE the add
    // had landed, moving/seeking an index that didn't exist yet. That one
    // race permanently desynced queueSongs (this Kotlin list) from the
    // ExoPlayer media item list from then on, so every later index-based
    // op — including skipToQueueItem's player.seekTo(index, 0) — pointed
    // at the wrong physical item even though the index "looked" correct.
    // Routing every queue-mutating op through this same mutex forces them
    // to run one at a time, each fully completing its native mutation
    // before the next one starts, so queueSongs and the real player list
    // never drift apart.
    private val queueMutex = Mutex()

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
    //
    // bufferForPlaybackMs / bufferForPlaybackAfterRebufferMs (Spotify-
    // style slow-network tolerance): on a fast connection 1.5s/3s of
    // buffer is plenty before starting/resuming playback. On a genuinely
    // slow connection, starting that early just means the player catches
    // up to its own buffer again within a couple of seconds and drops
    // back into STATE_BUFFERING — which is the exact "song keeps
    // stopping and starting" feeling this is meant to avoid. A slightly
    // larger cushion (3s initial / 5s after a rebuffer) costs a small
    // amount of extra wait before sound starts, but lets a slow
    // connection build up enough of a lead to actually keep playing
    // through, instead of oscillating between BUFFERING and READY.
    private val loadControl = DefaultLoadControl.Builder()
        .setBufferDurationsMs(15_000, 30_000, 3_000, 5_000)
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

    // Live network throughput estimate, fed by every ExoPlayer HTTP
    // transfer via .setTransferListener() below. Used by Smart Saver
    // (Dart side, AudioPrefs.qualityOrder()) to pick a bitrate tier
    // based on the connection's ACTUAL measured speed rather than a
    // static "Data Saver on/off" guess — so a genuinely fast connection
    // isn't held to 48kbps forever, and a genuinely slow one (2G/EDGE)
    // doesn't get stuck retrying a 320kbps stream it can never keep up
    // with. Single instance for the engine's lifetime: DefaultBandwidthMeter
    // is explicitly designed to be shared across every data source so its
    // estimate reflects real aggregate traffic, not just one song's reads.
    // DefaultBandwidthMeter.Builder is @UnstableApi — opt-in required here,
    // same tier as the cache/media-source builders already opted into
    // elsewhere in this file.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private val bandwidthMeter: DefaultBandwidthMeter by lazy {
        DefaultBandwidthMeter.Builder(context).build()
    }

    /**
     * Current estimate in bits/sec (0 until enough data has flowed to
     * estimate). BandwidthMeter#getBitrateEstimate() itself is stable API —
     * only the Builder used to construct [bandwidthMeter] above is unstable —
     * so this accessor needs no opt-in of its own.
     */
    fun getEstimatedBandwidthBitsPerSec(): Long = bandwidthMeter.bitrateEstimate

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
    // FIX (Spotify-style slow-network tolerance): on a genuinely slow
    // connection (throttled mobile data, weak WiFi), individual chunk
    // reads can legitimately take longer than a "normal" connection
    // without the stream actually being dead — the old 8s read timeout
    // was killing perfectly-recoverable slow reads and forcing the
    // idle/dead-URL recovery path to kick in purely because of latency,
    // not an actual failure. Read timeout bumped to give slow connections
    // real room to keep delivering bytes; connect timeout also has a bit
    // more headroom for a slow initial handshake. This does not weaken
    // recovery for a genuinely dead stream — handleMidStreamIdle/
    // handleFreshStartIdle/the buffering watchdog still catch that, just
    // without punishing "slow but working" along the way.
    // .setTransferListener(bandwidthMeter) is what feeds the meter — every
    // byte read through this factory (i.e. every streamed song) reports its
    // size and duration to it, which is how getEstimatedBandwidthBitsPerSec()
    // stays live. Purely additive: DefaultHttpDataSource forwards these
    // events to the listener AFTER performing the actual read, so this has
    // no effect on timeouts, retries, or the bytes returned to the caller.
    // setTransferListener() is @UnstableApi (same annotation tier as the
    // cache/media-source calls opted into elsewhere in this file) — opt-in
    // required here or this fails to compile, not just a lint warning.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun createHttpFactory() = DefaultHttpDataSource.Factory()
        .setConnectTimeoutMs(20_000)
        .setReadTimeoutMs(20_000)
        .setUserAgent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36")
        .setTransferListener(bandwidthMeter)

    private fun createUpstreamFactory() = DefaultDataSource.Factory(context, createHttpFactory())

    // Wraps the upstream factory with the disk cache. Every read first
    // checks streamCache; only genuinely missing bytes hit the network.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun createCacheDataSourceFactory() = CacheDataSource.Factory()
        .setCache(streamCache)
        .setUpstreamDataSourceFactory(createUpstreamFactory())

    private val cachedMediaSourceFactory = DefaultMediaSourceFactory(createCacheDataSourceFactory())

    // FIX ("phone heat ho raha hai aur battery jaldi drain ho rahi hai
    // gaana chalate waqt"): builds the AudioOffloadPreferences that
    // request offload — decoding on the device's low-power audio DSP
    // instead of the main CPU, which is what actually stops the phone
    // from staying warm during long playback sessions. This is the
    // modern, non-experimental replacement for the older
    // DefaultRenderersFactory.setEnableAudioOffload() /
    // ExoPlayer.experimentalSetOffloadSchedulingEnabled() pair (Media3
    // <1.6) — Google folded both of those into this single
    // TrackSelectionParameters-based API starting in Media3 1.6.0.
    // setIsGaplessSupportRequired/setIsSpeedChangeSupportRequired keep
    // gapless playback and speed changes (both already used elsewhere in
    // this file) working correctly even while offload is active — Media3
    // automatically falls back to normal decode on any track/device
    // combination that can't satisfy every requested condition, so this
    // can never break playback, only help where it can.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun buildAudioOffloadPreferences() =
        androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences.Builder()
            .setAudioOffloadMode(
                androidx.media3.common.TrackSelectionParameters.AudioOffloadPreferences.AUDIO_OFFLOAD_MODE_ENABLED
            )
            .setIsGaplessSupportRequired(true)
            .setIsSpeedChangeSupportRequired(true)
            .build()

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
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
        .also { p ->
            // AudioOffloadPreferences is applied via trackSelectionParameters
            // rather than a Builder method — same pattern as every other
            // Media3 app currently shipping this (e.g. Echo Nightly's
            // PlayerService.kt), verified against Media3 1.8.0's actual API
            // surface rather than the older experimental methods.
            p.trackSelectionParameters = p.trackSelectionParameters
                .buildUpon()
                .setAudioOffloadPreferences(buildAudioOffloadPreferences())
                .build()

            // ─────────────────────────────────────────────────────────
            // SMOOTHNESS FIXES — everything below is purely about making
            // playback feel instant/responsive (Echo Nightly / Spotify /
            // YT Music level), on top of the offload work above. None of
            // this touches correctness or the resolve/queue logic
            // elsewhere in this file — only player-level tuning.
            // ─────────────────────────────────────────────────────────

            // Lets ExoPlayer start fetching/buffering the NEXT media item
            // in the timeline while the current one is still playing,
            // instead of waiting until the current item finishes before
            // even starting to prepare the next one. This is what makes
            // track-to-track transitions and forward skips feel instant
            // rather than having a beat of buffering right at the
            // boundary. TIME_UNSET here means "no artificial delay before
            // starting to preload" — start as early as ExoPlayer's own
            // internal heuristics allow.
            p.preloadConfiguration = ExoPlayer.PreloadConfiguration(androidx.media3.common.C.TIME_UNSET)

            // Trims silence at the start/end of tracks during playback.
            // Same effect Spotify/YT Music apply — back-to-back songs
            // feel tighter with no dead-air gap, and it also shortens the
            // perceived tap-to-sound delay on tracks that have a silent
            // lead-in. Safe no-op on tracks that don't have any silence
            // to trim.
            p.skipSilenceEnabled = true

            // Explicit false (matches ExoPlayer's own default, made
            // explicit here so it can never regress): without this, some
            // gapless-adjacent code paths can introduce a hairline pause
            // exactly at a track boundary. Keeping it force-false
            // guarantees gapless transitions stay a true zero-gap handoff.
            p.setPauseAtEndOfMediaItems(false)

            // Seeks (scrubbing the seek bar, tapping ahead in a track,
            // skip-with-position-carry in the crossfade/dead-song-recovery
            // paths elsewhere in this file) default to EXACT frame-accurate
            // seeking, which requires decoding forward from the nearest
            // keyframe to the exact requested position — slower, and the
            // main source of a seek "feeling laggy". CLOSEST_SYNC instead
            // jumps straight to the nearest keyframe and starts playing
            // immediately from there. For music (no visual frame to keep
            // in sync with), the few hundred milliseconds of drift this
            // can introduce is inaudible, while the responsiveness gain
            // is exactly what makes scrubbing feel "premium/instant"
            // instead of sluggish.
            p.setSeekParameters(androidx.media3.exoplayer.SeekParameters.CLOSEST_SYNC)

            // NOTE: Media3 1.8.0's scrubbing mode (ExoPlayer.
            // setScrubbingModeEnabled) is intentionally NOT enabled here.
            // It is a TEMPORARY, drag-duration-only mode meant to be
            // toggled on right when the user starts dragging the seek bar
            // and back off the instant they release it — turning it on
            // once at player construction time keeps the player
            // permanently in scrubbing mode, which silently prevented
            // normal playback from ever starting (song loads/shows
            // metadata but audio never plays — exactly the "0:00 forever"
            // bug this caused). Wiring it correctly requires a call from
            // the seek-bar's drag-start/drag-end handlers on the Dart
            // side through the method channel, which is future work —
            // left out for now so playback stays correct.
        }
        .also { p ->
            // DIAGNOSTIC (heating investigation): AUDIO_OFFLOAD_MODE_ENABLED
            // above is a REQUEST, not a guarantee — Media3 silently falls
            // back to normal main-CPU decode whenever the device/track
            // combo can't satisfy offload (codec not offload-capable on
            // this device, or the gapless/speed-change requirements can't
            // be met for this specific format). There's no error and no
            // visible signal when that fallback happens — it just quietly
            // decodes on the CPU instead of the low-power DSP, which reads
            // exactly like "heats up on every song" with no other symptom.
            // This listener logs which path is actually taken per track so
            // that can be confirmed from logcat instead of guessed at.
            p.addAnalyticsListener(object : androidx.media3.exoplayer.analytics.AnalyticsListener {
                override fun onAudioTrackInitialized(
                    eventTime: androidx.media3.exoplayer.analytics.AnalyticsListener.EventTime,
                    audioTrackConfig: androidx.media3.exoplayer.audio.AudioSink.AudioTrackConfig,
                ) {
                    android.util.Log.i("AurumAudioEngine", "[offload-check] AudioTrack init — offload=${audioTrackConfig.offload} " +
                        "encoding=${audioTrackConfig.encoding} sampleRate=${audioTrackConfig.sampleRate} " +
                        "channelConfig=${audioTrackConfig.channelConfig}")
                    AurumDiagnosticLog.logOffload(
                        audioTrackConfig.offload,
                        audioTrackConfig.encoding,
                        audioTrackConfig.sampleRate,
                        currentSong()?.id,
                    )
                    onOffloadStatus?.invoke(
                        audioTrackConfig.offload,
                        audioTrackConfig.encoding,
                        audioTrackConfig.sampleRate,
                    )
                }
            })
        }

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
    private var volumeFadeJob: Job? = null

    // FIX — "music dabta/dab jaata hai baar baar" during long listening
    // sessions: AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK fires for lots of brief,
    // completely normal system/OEM sounds (keyboard clicks, nav-bar taps,
    // other apps' notification pings) — that's expected and can happen
    // often, especially with the keyboard open. The duck handling itself
    // was correct (never pausing for this case), but it snapped volume
    // straight to 30% and back INSTANTLY on the very next frame — an
    // abrupt, audible jolt every time, which on a long session with lots
    // of these transient dips reads exactly like "the song keeps getting
    // pushed down". Fading both directions over a couple hundred ms makes
    // every duck/restore smooth and far less noticeable, and raising the
    // floor from 30%→55% means even mid-duck it's a gentle dip, not a
    // near-mute.
    private fun fadeVolumeTo(target: Float, durationMs: Long = 220L) {
        cancelAllVolumeFades()
        volumeFadeJob = scope.launch {
            val start = player.volume
            if (start == target) return@launch
            val steps = 12
            val stepDelay = durationMs / steps
            for (i in 1..steps) {
                val t = i / steps.toFloat()
                player.volume = start + (target - start) * t
                delay(stepDelay)
            }
            player.volume = target
        }
    }

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Sustained loss — another app has taken over audio
                // entirely (rare: another music player, screen recording,
                // etc). Pause and require an explicit user tap to resume.
                // The OS has genuinely taken focus away from us here, so
                // hasAudioFocus must flip back to false — otherwise the
                // later requestAudioFocus() call (once the user taps play
                // again) would wrongly no-op and never actually re-acquire it.
                hasAudioFocus = false
                cancelAllVolumeFades()
                if (duckedForTransientFocusLoss) {
                    player.volume = preduckVolume
                    duckedForTransientFocusLoss = false
                }
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
                // Same reasoning as AUDIOFOCUS_LOSS above: the OS took focus
                // away, so reflect that here too.
                hasAudioFocus = false
                cancelAllVolumeFades()
                if (duckedForTransientFocusLoss) {
                    player.volume = preduckVolume
                    duckedForTransientFocusLoss = false
                }
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
                    duckedForTransientFocusLoss = true
                    // BUGFIX: 0.55 was still an audible "tick/ring" dip on
                    // every routine system sound (keyboard clicks, nav taps,
                    // notification pings) since these fire constantly during
                    // normal phone use. 0.85 keeps the OS contract (get
                    // quieter, don't stop) while staying close enough to
                    // full volume that the dip is no longer perceptible as
                    // an interruption during playback.
                    fadeVolumeTo(preduckVolume * 0.85f)
                }
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                hasAudioFocus = true
                if (duckedForTransientFocusLoss) {
                    fadeVolumeTo(preduckVolume)
                    duckedForTransientFocusLoss = false
                }
                if (pausedForTransientFocusLoss) {
                    // Auto-resume — this was a call/transient interruption,
                    // not the user or another app deliberately taking over.
                    // FIX ("pause karo, khud restart ho jaata hai"): but not
                    // if the user also explicitly paused during the call —
                    // their pause always wins over an auto-resume here.
                    if (!userPaused) player.play()
                    pausedForTransientFocusLoss = false
                }
                // pausedForSustainedFocusLoss is intentionally NOT
                // auto-resumed here — see comment on the field above.
                pausedForSustainedFocusLoss = false
            }
        }
    }

    private var focusRequest: AudioFocusRequest? = null

    // FIX — THE actual root cause of "song pauses for 1-2s then auto-resumes
    // by itself, repeatedly, chahe screen on ho ya off": onIsPlayingChanged
    // below was calling requestAudioFocus() on EVERY single isPlaying=true
    // event — initial play, every track transition, every crossfade, every
    // resume-after-buffering, even the resume that our own AUDIOFOCUS_GAIN
    // handler itself triggers. We already held focus continuously through
    // all of that; calling AudioManager.requestAudioFocus() again while
    // already holding it is what caused the repeated pause/resume cycles —
    // on many OEM audio stacks, re-requesting AUDIOFOCUS_GAIN for a stream
    // that already has it makes the system briefly cycle the focus state
    // (a transient loss/gain echo straight back to our own listener), which
    // is exactly what pauses/ducks and then auto-resumes 1-2s later. This
    // flag tracks whether we currently hold focus so requestAudioFocus()
    // becomes a genuine no-op when we already do, instead of re-requesting
    // on every single playback event.
    private var hasAudioFocus = false

    // FIX ("har song shuru hote waqt halka sa glitch/blip hota hai" — on
    // essentially every play, not just literal first-ever-tap): the
    // isFreshFocusGrab mute-then-180ms-fade below in onIsPlayingChanged
    // was REACTIVE — it only ran after ExoPlayer had already started
    // actually rendering audio (player.play() already returned, the
    // listener fires off ExoPlayer's own async internal looper). That
    // meant real, audible sound played for a brief moment at full volume,
    // THEN got stomped to silent and faded back in — an audible
    // mute/fade-in blip layered on top of audio that had already started,
    // on every single play() where focus needed re-acquiring. Since
    // hasAudioFocus flips false on ANY focus loss (a pause long enough
    // for the OS to reclaim it, a phone call, tapping X on the mini
    // player), that covers the overwhelming majority of real listening
    // sessions, not just a one-time first-launch edge case — matching
    // "sabhi songs mein ye problem hai".
    //
    // Fix: request focus PROACTIVELY, before player.play(), at the two
    // real song-start points (playQueueInternal/playSongInternal) while
    // player.volume is still 0f from hardStopAndMute() — so the OEM-chime
    // silent-window trick still works exactly as before, but the mute
    // happens BEFORE any audio is rendered, not after. This flag records
    // that we already did that hand-off for the in-flight transition, so
    // the reactive listener (still needed as a safety net for the
    // handful of call sites that call player.play() directly, per the
    // comment on it below) skips its own redundant mute-and-fade instead
    // of stomping on audio that's already correctly playing.
    private var focusPreHandledForThisStart = false

    private fun requestAudioFocus(): Boolean {
        if (hasAudioFocus) return true
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
        val granted = audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        hasAudioFocus = granted
        return granted
    }

    // Called right before player.play() at the two genuine song-start
    // entry points, while volume is still 0f (see focusPreHandledForThisStart
    // doc comment above for the full reasoning). If this is a fresh focus
    // grab, requests it and fades in from silence HERE — before any audio
    // renders — so the reactive onIsPlayingChanged listener has nothing
    // left to do for this transition.
    private fun ensureFocusBeforePlay() {
        val isFreshFocusGrab = !hasAudioFocus
        requestAudioFocus()
        // Only set when there's actually a fresh-grab mute+fade for the
        // reactive listener to skip — on a normal resume (focus already
        // held) that listener's mute+fade branch never runs anyway
        // regardless of this flag, so leaving it false here removes any
        // window for a stale `true` to survive past this call (e.g. if
        // player.play() right after this never actually triggers
        // onIsPlayingChanged — a thrown exception, a silent ExoPlayer
        // failure) and wrongly suppress a LATER, genuinely-reactive
        // fresh-grab dance from one of the direct-player.play() call
        // sites (togglePlay, skipToNext, etc.) that don't go through this
        // function at all.
        if (isFreshFocusGrab) {
            focusPreHandledForThisStart = true
            fadeVolumeTo(1f, durationMs = 180L)
        }
    }

    private fun abandonAudioFocus() {
        focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        hasAudioFocus = false
    }


    // Native replacement for the old just_audio AndroidEqualizer/
    // AndroidLoudnessEnhancer (audio_effects_controller.dart, now
    // orphaned). Same self-healing/one-way-dependency guarantees, attached
    // to this ExoPlayer's audioSessionId instead of built into the
    // AudioPipeline at construction time.
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    val effects: AurumAudioEffects = AurumAudioEffects(player, context)

    private val _state = MutableStateFlow(NativeEngineState())
    val state: StateFlow<NativeEngineState> = _state

    var onPlaybackError: ((String, Boolean) -> Unit)? = null // (message, silent)
    var onQueueChanged: (() -> Unit)? = null

    // DIAGNOSTIC (heating investigation, see AnalyticsListener registered
    // on the player builder below): fired every time ExoPlayer actually
    // initializes an AudioTrack, reporting whether hardware offload (the
    // low-power DSP decode path) was actually granted for that track, or
    // whether it silently fell back to normal main-CPU decode.
    // (offloaded, encoding, sampleRate) — forwarded to Dart so it's visible
    // on-device without needing logcat/adb.
    var onOffloadStatus: ((Boolean, Int, Int) -> Unit)? = null

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

    // Mirrors Dart's AudioPrefs.batterySaverActiveNotifier — pushed down via
    // setBatterySaverActive() whenever it changes on the Dart side (battery
    // level crossing the user's threshold, or the feature toggled). Read
    // only by resolveQueueInBackground()'s forward-window size below; every
    // other battery-saver behavior (animations, bg style) is Dart-only and
    // untouched by this flag. Defaults false so a cold app start (before
    // the first native battery broadcast arrives) behaves exactly as
    // before — full-smoothness pre-buffering — and only narrows once we
    // hear otherwise.
    @Volatile private var batterySaverActive = false

    // Android's own "is this a genuinely low-RAM device" signal — set once
    // by the OS at install/build time from actual device specs (see
    // ActivityManager.isLowRamDevice docs: true on devices below the
    // platform's minimum recommended RAM for a "full" experience,
    // independent of current battery level). Reading it once at
    // construction — it can never change for a given device — instead of
    // inventing any new detection/polling of our own. This is a SEPARATE
    // signal from batterySaverActive: a low-end device on 80% battery
    // still benefits from the lighter pre-buffer window (less RAM held
    // for queued MediaItems/buffers, less concurrent network/decode
    // work), which battery-level-only gating would never catch.
    private val isLowRamDevice: Boolean =
        (context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager)
            ?.isLowRamDevice ?: false

    private val priorityForwardWindow: Int
        get() = if (batterySaverActive || isLowRamDevice) PRIORITY_FORWARD_WINDOW_SAVER else PRIORITY_FORWARD_WINDOW_NORMAL

    fun setBatterySaverActive(active: Boolean) {
        batterySaverActive = active
    }

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
    // Backing field for NativeEngineState.resolveTakingLong — see that
    // field's doc comment. Only ever read/written from the resolve loop
    // below (single-threaded via `scope`), same as isResolving.
    private var resolveTakingLong = false

    // FIX ("pause karo, khud restart ho jaata hai" — player silently
    // resuming on its own after a pause): pause() previously only ever
    // called player.pause() — it never recorded that the user explicitly
    // wanted playback stopped. Three background recovery paths run on
    // their own coroutine timeline, independent of user taps: the
    // network-reconnect listener (registerReconnectListener), and the
    // mid-resolve recovery handlers handleFreshStartIdle/
    // handleMidStreamIdle. All three call player.play() unconditionally
    // once a stuck resolve/retry finally succeeds — with nothing to tell
    // them the user paused sometime during that retry window. A pause
    // that happened to land while a stream was mid-resolve (a common
    // moment to pause — the user is waiting on a slow network) got
    // silently overridden the instant that retry completed, which looks
    // exactly like the player randomly restarting itself with no tap
    // from the user. Set true in pause(), cleared in play() and in
    // playQueueInternal/skip paths (a fresh explicit play always wins),
    // and checked immediately before every recovery-triggered
    // player.play() call below — a paused user is never resumed out from
    // under them by a background retry.
    private var userPaused = false

    // Media3's playlist == the "ConcatenatingAudioSource" equivalent.
    // We track song IDs in the same order as player.mediaItemCount to
    // detect drift, same purpose as Dart's _queue vs sequence checks.
    private var liveMediaIds: MutableList<String> = mutableListOf()

    private var fadeJob: Job? = null
    // Both fadeJob (crossfade ramp) and volumeFadeJob (focus-duck fade,
    // declared below) independently write to player.volume over time, but
    // used to only ever cancel THEMSELVES before starting — never each
    // other. If a duck/restore fade and a crossfade ramp ever overlapped
    // (e.g. a notification sound fires while a crossfade transition is
    // still ramping in), both coroutines kept ticking and stomped on
    // player.volume simultaneously — an audible fight between two fades
    // that reads exactly like the volume randomly dipping and climbing on
    // its own. cancelAllVolumeFades() is the single choke point every
    // fade-starting site now goes through first, so starting either kind
    // of fade always guarantees the other one is dead first.
    private fun cancelAllVolumeFades() {
        fadeJob?.cancel()
        volumeFadeJob?.cancel()
        sleepFadeJob?.cancel()
    }
    private var idleWatchdogJob: Job? = null
    // Safety net for the one gap the existing IDLE-recovery paths don't
    // cover: the player sitting in STATE_BUFFERING indefinitely with no
    // exception ever thrown and no transition to STATE_IDLE. This happens
    // rarely but really — e.g. an Android network-stack connection that
    // goes half-open during a WiFi↔mobile-data handover and never fires
    // the HTTP read timeout because no FIN/RST ever arrives. Without this,
    // that specific case has no recovery path at all: not an error (so
    // onPlayerError never fires), not idle (so handleIdleEvent never
    // fires) — playback just silently never continues.
    private var bufferingWatchdogJob: Job? = null
    private var currentSongLiked = false
    private var crossfadeSecs = 0.0
    private var stopAfterCurrentSong = false
    // Tracks the sleep-timer fade-out coroutine specifically (separate from
    // fadeJob/volumeFadeJob above) so cancelAllVolumeFades() can kill it too
    // if a duck/crossfade fade needs to take over mid-fade-out, and so a
    // second sleepFadeOutAndPause() call (e.g. timer restarted) cancels any
    // fade already in flight instead of running two at once.
    private var sleepFadeJob: Job? = null

    companion object {
        // Prewarm window: how many songs ahead/behind the current one get
        // resolved + added to ExoPlayer's timeline immediately (vs. paced
        // resolution further out). Forward window is 4 by default so
        // several rapid next-taps in a row all land on an already-buffered
        // song — Spotify-style instant skip. This trades a bit more
        // background data/battery for that extra smoothness. Under Battery
        // Saver Mode (see batterySaverActive below) this drops to 2 —
        // enough for one instant skip in a row, capping the background
        // resolve/network work on low-end or low-battery devices.
        private const val PRIORITY_FORWARD_WINDOW_NORMAL = 4
        private const val PRIORITY_FORWARD_WINDOW_SAVER = 2
        private const val PRIORITY_BACKWARD_WINDOW = 1
        private const val PACED_RESOLVE_DELAY_MS = 2500L

        // FIX (Spotify-style slow-network tolerance): both caps sized to
        // actually cover resolveFast()'s own inner budget instead of
        // cutting it off mid-attempt. resolveFast() defaults to 2
        // attempts internally, each with its own per-attempt timeout
        // (perAttemptTimeoutMs below) plus a short gap between them —
        // YouTube: up to ~18s × 2 + gap ≈ 36.5s; other sources: up to
        // ~12s × 2 + gap ≈ 24.5s. The outer cap must be at least that
        // large or it fires before the inner logic gets its real,
        // documented number of attempts — which on a slow connection is
        // indistinguishable from the song being dead even though the
        // request was still genuinely in flight.
        private const val RESOLVE_HARD_CAP_MS = 26_000L
        private const val RESOLVE_HARD_CAP_YOUTUBE_MS = 38_000L

        private fun hardCapFor(song: NativeSong): Long =
            if (song.source == "youtube") RESOLVE_HARD_CAP_YOUTUBE_MS else RESOLVE_HARD_CAP_MS

        // No-auto-skip policy: a slow (but real) connection must never
        // cause the engine to give up on the song the user actually
        // chose and silently move to a different one — that's the exact
        // "songs keep skipping and nothing ever plays" failure mode on a
        // weak connection. So resolveWithPatience() below retries
        // indefinitely as long as there's any network path at all
        // (hasAnyNetworkConnection); this threshold only controls when
        // resolveTakingLong flips to true so Dart can surface a "check
        // your connection" message — it is not a giving-up point.
        private const val RESOLVE_WARNING_THRESHOLD_MS = 20_000L

        // Backoff between retry attempts once the first attempt has
        // already failed/timed out: starts short, ramps up, caps at 8s
        // so a long-standing outage doesn't hammer the resolver.
        private fun retryBackoffMs(attempt: Int): Long =
            2_000L * minOf(attempt + 1, 4)
    }

    init {
        registerReconnectListener()
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                pushState()
                if (playbackState == Player.STATE_IDLE) handleIdleEvent()
                if (playbackState == Player.STATE_BUFFERING) {
                    startBufferingWatchdog()
                } else {
                    bufferingWatchdogJob?.cancel()
                    bufferingWatchdogJob = null
                }
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
                    // FIX: "ding/chime plays right as a song starts, before
                    // any audio content — happens on song tap from home/
                    // search, every time." Root cause: several OEM Android
                    // skins (MIUI, ColorOS, FuntouchOS, etc.) play their own
                    // system-level "audio route switching" chime the moment
                    // an app is FIRST granted AUDIOFOCUS_GAIN after not
                    // holding it — this is generated by the OS/OEM audio
                    // stack itself, not by anything this app plays, which is
                    // why no sound asset or MediaPlayer/ToneGenerator call
                    // exists anywhere in this codebase to explain it. It
                    // only happens on a genuinely FRESH focus grab (hence
                    // "just tap a song from home/search" triggering it,
                    // consistent with hasAudioFocus transitioning false→true
                    // here), not on a resume where focus was already held.
                    //
                    // Actual fix: since we can't suppress an OS-level sound
                    // from inside our own audio session, we instead make
                    // sure our own output is silent for the brief instant
                    // that chime would occur, then fade the real song in —
                    // so the chime (if the OEM plays one) has nothing of
                    // ours to overlap/collide with, and the fade masks the
                    // output-route "pop" some OEMs produce on the same
                    // transition. Only applied on the genuine false→true
                    // focus transition, not on every play() call, so normal
                    // resume-after-pause (focus already held) stays instant
                    // with no fade, matching every other player's feel.
                    //
                    // FIX ("blip/glitch at the start of every song"): this
                    // used to unconditionally do the mute+fade dance right
                    // here — but by the time onIsPlayingChanged fires,
                    // ExoPlayer has typically already started rendering
                    // real audio (this listener is asynchronous/reactive).
                    // That meant a moment of real audible sound, THEN a
                    // stomp to silent, THEN a fade back in — an audible
                    // artifact on essentially every play. The real
                    // song-start entry points (playQueueInternal/
                    // playSongInternal) now call ensureFocusBeforePlay()
                    // themselves, BEFORE player.play(), while volume is
                    // still 0f from hardStopAndMute() — so the mute+fade
                    // already happened at the correct time for those paths,
                    // with nothing audible to interrupt. This block now
                    // only runs the fallback dance for the handful of call
                    // sites that call player.play() directly and skipped
                    // that pre-handling (see focusPreHandledForThisStart's
                    // doc comment) — same safety net as before, just no
                    // longer double-firing on top of an already-correct
                    // fade-in.
                    if (focusPreHandledForThisStart) {
                        focusPreHandledForThisStart = false
                    } else {
                        val isFreshFocusGrab = !hasAudioFocus
                        if (isFreshFocusGrab) {
                            cancelAllVolumeFades()
                            player.volume = 0f
                        }
                        requestAudioFocus()
                        if (isFreshFocusGrab) {
                            fadeVolumeTo(1f, durationMs = 180L)
                        }
                    }
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
            // FIX — "notification/lock-screen skip plays the new song
            // instantly and correctly, but if you then open the app it
            // shows the OLD song stuck": onPositionDiscontinuity above only
            // called handleCurrentIndexChanged() for
            // DISCONTINUITY_REASON_AUTO_TRANSITION (natural song-end
            // auto-advance). Skipping via the notification/lock-screen
            // buttons goes through Media3's own default MediaSession
            // command handling, which calls player.seekToNext()/
            // seekToPrevious() directly on the shared ExoPlayer instance —
            // entirely bypassing any Dart-triggered method-channel call —
            // and that fires DISCONTINUITY_REASON_SEEK, not
            // AUTO_TRANSITION. That branch was silently ignored, so
            // `currentIndex` (and therefore `currentSongId` sent to Dart in
            // pushState()) never updated for that path: the notification
            // itself updated correctly (Media3 drives it straight off the
            // player), but our own state stream kept reporting the old
            // song/index until some OTHER event happened to also touch
            // currentIndex.
            //
            // onMediaItemTransition fires for every track change regardless
            // of cause (auto-advance, seek-based skip, or a manual
            // setMediaItem/seekTo call) and gives us the definitive new
            // index directly — this is the single correct funnel for
            // "the current song changed", so route ALL cases through here
            // instead of only auto-transition.
            override fun onMediaItemTransition(
                mediaItem: androidx.media3.common.MediaItem?,
                reason: Int,
            ) {
                handleCurrentIndexChanged(player.currentMediaItemIndex)
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
        // Push once immediately — without this, Dart's mirrored position/
        // duration could sit at whatever the last event happened to be
        // (possibly 0/null right at playback start) for up to a full
        // second before the loop below's first tick, which is the exact
        // "seek bar frozen at 00:00 for a beat" gap this ticker exists to
        // prevent in the first place.
        pushState()
        tickerJob = scope.launch {
            var last = -1L
            while (isActive) {
                delay(1000)
                val pos = player.currentPosition
                if (pos != last) { last = pos; pushState() }
            }
        }
    }

    // FIX (root cause of "isPlaying=true but isLoading stays true forever,
    // position/duration stuck at 0, audio genuinely playing" — confirmed
    // via on-device debug overlay: expectedSongId==currentSongId,
    // isPlaying=true, isLoading=true, position=0/duration=0, with no
    // further state event ever arriving): player.play() was followed by
    // exactly one immediate pushState() call in the calling function's
    // finally block. ExoPlayer processes play() on its own internal
    // handler/looper — the playbackState transition to STATE_READY and
    // the isPlaying flip don't necessarily land synchronously the instant
    // play() returns. That one pushState() call could race ahead of
    // ExoPlayer's actual internal state settling, snapshotting
    // "isPlaying=true (already flipped) but playbackState still
    // STATE_BUFFERING (not yet flipped) / position+duration still 0"
    // — exactly the frozen state reported. Player.Listener callbacks
    // (onIsPlayingChanged/onPlaybackStateChanged) SHOULD fire again once
    // ExoPlayer's internal state genuinely settles and correct this on
    // their own, but if either callback gets coalesced/dropped for that
    // particular transition, nothing else was scheduled to catch it —
    // this was a pure race, not a guaranteed-safe read.
    //
    // Fix: fire a couple of short delayed re-pushes after starting
    // playback, so even if the listener callbacks never refire, a fresh
    // pushState() runs shortly after once ExoPlayer's state has had time
    // to actually settle. Cheap (just a state re-read + emit, no I/O) and
    // self-cancels naturally if playSessionId has already moved on.
    private fun scheduleSettlePushStates(mySession: Int) {
        scope.launch {
            delay(150)
            if (mySession == playSessionId) pushState()
            delay(500)
            if (mySession == playSessionId) pushState()
        }
    }

    private fun pushState() {
        // While casting, the local ExoPlayer is intentionally paused/muted
        // (see AurumEngineChannelHandler's session-started handoff) and
        // its position/duration are stale the moment the receiver starts
        // playing — so every position-like field below reads from
        // castManager's CastPlayer instead. currentIndex/queueIds/
        // currentSongId stay sourced from this engine's own queue
        // tracking either way since Dart's queue UI (up-next list, etc.)
        // should keep showing Aurum's queue regardless of where audio is
        // routing.
        val casting = _castManager?.isCasting == true
        val activePlayer: Player = if (casting) _castManager!!.castPlayer!! else player

        // FIX ("UI shows new song, notification/lock-screen shows a
        // DIFFERENT older song — worse the faster you skip, esp. on
        // offline/local songs"): currentSongId used to be derived purely
        // from queueSongs.getOrNull(currentIndex) — the Dart-mirrored
        // queue state, which playQueueInternal updates OPTIMISTICALLY the
        // instant a skip starts (before hardStopAndMute/setMediaItem have
        // actually run). Meanwhile the Media3-driven notification reads
        // player.currentMediaItem directly — the REAL ExoPlayer state,
        // which lags behind queueSongs/currentIndex until
        // setSingleMediaItemInternal actually completes. Under a fast
        // skip (or a second skip landing while the first is still
        // resolving), pushState() could report a currentSongId newer than
        // what the player had actually loaded — Dart's UI (driven by
        // this pushState) would show the new song while the notification
        // (driven by the real player) still showed the old one, exactly
        // the mismatch reported. Local/offline songs resolve near-
        // instantly, which shrinks the window but doesn't close it — the
        // optimistic currentIndex write still happens before
        // setMediaItem, so the race is still there, just tighter.
        //
        // Fix: prefer the player's OWN current media item id — the same
        // source of truth the notification already uses — so pushState()
        // can never report a song to Dart that the player hasn't actually
        // switched to yet. Only fall back to the queue-mirror id while the
        // player genuinely has no media item yet (mid-transition, e.g.
        // right after hardStopAndMute's clearMediaItems()), so a legitimate
        // "loading" state doesn't just report null/stale.
        val liveMediaItemId = activePlayer.currentMediaItem?.mediaId
        val effectiveCurrentSongId = liveMediaItemId
            ?: queueSongs.getOrNull(currentIndex)?.id

        _state.value = NativeEngineState(
            processingState = when {
                // Reported first: a resolve is in flight and ExoPlayer has no
                // MediaItem yet, so player.playbackState would otherwise say
                // "idle" — which Dart reads as "not loading". This is the
                // actual fix for the silent 10-20s gap.
                !casting && isResolving && player.playbackState == Player.STATE_IDLE -> "loading"
                activePlayer.playbackState == Player.STATE_IDLE -> "idle"
                activePlayer.playbackState == Player.STATE_BUFFERING -> "buffering"
                activePlayer.playbackState == Player.STATE_READY -> "ready"
                activePlayer.playbackState == Player.STATE_ENDED -> "completed"
                else -> "idle"
            },
            playing = activePlayer.isPlaying,
            positionMs = activePlayer.currentPosition,
            bufferedPositionMs = activePlayer.bufferedPosition,
            durationMs = activePlayer.duration.takeIf { it != C.TIME_UNSET },
            currentIndex = currentIndex,
            speed = activePlayer.playbackParameters.speed,
            queueIds = queueSongs.map { it.id },
            currentSongId = effectiveCurrentSongId,
            liked = currentSongLiked,
            resolveTakingLong = resolveTakingLong,
        )
    }

    private fun emitError(message: String, silent: Boolean = false) {
        AurumDiagnosticLog.logPlaybackError(message, currentSong()?.id)
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
    // Counts sessions currently between hardStopAndMute()'s volume=0f step
    // and their own restoreVolume() — i.e. how many in-flight
    // playQueueInternal calls currently want the player muted. Needed
    // because sessionId alone (mySession == playSessionId) can't safely
    // gate restoreVolume() in the finally block below: if it did, an
    // ABANDONED session (superseded by a newer tap before it finished)
    // would skip restoreVolume() entirely, since by the time its finally
    // ran, playSessionId already pointed at the newer session. Nobody else
    // was ever going to restore volume on that abandoned session's behalf
    // — hardStopAndMute() only touches player.volume, it's never restored
    // except in this same finally. That dangling mute is exactly the
    // reported bug: "skip jaldi jaldi karta hu to volume automatically
    // gir jata hai, dubara thik ho jata hai" — a session muted the player,
    // got abandoned mid-flight by a fast follow-up tap, and nothing ever
    // un-muted it; audio (or the next fast skipToNext()/skipToQueueItem
    // call, which take a "already buffered" path that never touches
    // volume, assuming it's already 1f) played silently until whichever
    // session eventually DID finish and restore it.
    private var mutedSessionCount = 0

    // Returns true if this call actually set player.volume = 0f (i.e. it
    // was still the current session at that instant) — false if it bailed
    // before ever touching volume (superseded before even starting). Only
    // a call that returns true has a mute contribution that later needs
    // releasing via restoreVolume(); see mutedSessionCount's doc comment.
    private suspend fun hardStopAndMute(sessionId: Int): Boolean {
        cancelAllVolumeFades()
        fadeJob = null
        fun stillCurrent() = sessionId == playSessionId
        if (!stillCurrent()) return false
        player.volume = 0f
        mutedSessionCount++
        // Safety-net reset: a NEW transition is starting here, so any
        // stale `true` left over from a previous ensureFocusBeforePlay()
        // call whose player.play() never actually reached
        // onIsPlayingChanged (thrown exception, silent ExoPlayer failure —
        // see ensureFocusBeforePlay's doc comment) can't survive to wrongly
        // suppress a later, unrelated fresh-focus-grab dance. Cheap and
        // always correct to clear here: if THIS transition's own
        // ensureFocusBeforePlay() call needs it set, that happens later,
        // right before player.play(), well after this point.
        focusPreHandledForThisStart = false
        if (!stillCurrent()) return true
        player.pause()
        if (!stillCurrent()) return true
        player.stop()
        if (!stillCurrent()) return true
        player.clearMediaItems()
        liveMediaIds.clear()
        return true
    }

    // Only actually restores player.volume once every session that muted
    // it has also called this — see mutedSessionCount doc comment above.
    // Guards against going negative (a session finishing without ever
    // successfully muting — e.g. it bailed at hardStopAndMute's very
    // first stillCurrent() check, before player.volume=0f ever ran) so
    // this can never over-decrement and force a phantom restore while a
    // real mute is still legitimately in flight.
    //
    // releaseVolumeToOne controls whether a genuine restore (down to
    // mutedSessionCount == 0) actually snaps player.volume = 1f here, or
    // leaves it alone. Needed for the fresh-focus-grab path in
    // playQueueInternal/playSongInternal: ensureFocusBeforePlay() already
    // started a 180ms fade up to 1f in that case (see its doc comment) —
    // this function still MUST run (to release this session's counted
    // mute contribution, or mutedSessionCount would leak and permanently
    // block every future restore) but must NOT also snap volume to 1f
    // itself, which would race/fight the fade already in progress.
    private fun restoreVolume(releaseVolumeToOne: Boolean = true) {
        if (mutedSessionCount > 0) mutedSessionCount--
        if (mutedSessionCount == 0 && releaseVolumeToOne) player.volume = 1f
    }

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
        // A fresh explicit play/queue start is unambiguous "user wants
        // this playing" intent — always clears any stale userPaused left
        // over from whatever was playing before (see userPaused doc
        // comment above play()/pause()).
        userPaused = false

        val safeIndex = if (songs.isEmpty()) 0 else startIndex.coerceIn(0, songs.size - 1)
        var effectiveIndex = safeIndex

        queueSongs = songs
        currentIndex = safeIndex
        splicingInProgress = true
        onQueueChanged?.invoke()
        pushState()

        var started = false
        // FIX (finally-override race): the old unconditional
        // `finally { isResolving = false }` below used to stomp this back
        // to false even on the "network genuinely absent, stay pending"
        // return path just above it — silently killing the loading UI the
        // moment that return fired. This flag lets that specific return
        // path opt OUT of the finally's reset, while every other
        // exit/exception still gets the safety-net reset.
        var keepResolvingOnExit = false
        // Tracks whether hardStopAndMute() below actually incremented
        // mutedSessionCount for THIS call — only then does this session
        // owe a matching restoreVolume() in finally. See both methods'
        // doc comments.
        var didMute = false
        try {
            didMute = hardStopAndMute(mySession)
            if (mySession != playSessionId) return

            isResolving = true
            pushState()

            // FIX ("check your internet connection" / long white-layer loading
            // when playing from Home, Liked, Up Next, History — but smooth from
            // Search): this used to skip straight to resolveWithPatience(),
            // whose very first attempt already uses hardCapFor() (26s Saavn /
            // 38s YouTube) instead of resolveFast()'s short 12s/18s-per-attempt
            // budget. So every queue-originated tap paid a much longer worst-case
            // stall before anything played — and resolveTakingLong (which drives
            // the "check your connection" message) couldn't flip true until 20s
            // in, on TOP of that longer first attempt. playSongInternal (the
            // search/single-tap path) already tries resolveFast() first for
            // exactly this reason. Mirroring that here means queue-originated
            // taps get the same fast first attempt search taps do, and only
            // fall into the indefinite-patience retry loop if that quick
            // attempt genuinely fails.
            val resolvedSong = songs[safeIndex]
            var url = resolveFast(resolvedSong, mySession)
            if (mySession != playSessionId) return
            if (url == null) {
                url = resolveWithPatience(resolvedSong, mySession)
                if (mySession != playSessionId) return
            }

            if (url == null) {
                // Network is genuinely, completely absent (not just
                // slow) — nothing left to try right now. Leave the song
                // loaded/pending rather than failing the queue out from
                // under the user; SourceProvider's offline handling on
                // the Dart side already reflects this in the UI, and
                // resolveTakingLong (still true) keeps the "check your
                // connection" message up. isResolving stays true so the
                // UI keeps showing loading, not a dead state — the user
                // can always back out via a manual Next/Previous.
                keepResolvingOnExit = true
                pushState()
                return
            }

            resolveTakingLong = false
            if (mySession != playSessionId) return
            try {
                setSingleMediaItemInternal(url, resolvedSong)
            } catch (e: Exception) {
                isResolving = false
                failPlayback(resolvedSong, e.message ?: "setMediaItem failed")
                return
            }
            isResolving = false
            if (mySession != playSessionId) return

            // FIX (premium-feel latency) — this used to be followed by a
            // flat delay(600) before play() with a comment claiming it
            // "verified ExoPlayer opened the source". The block did
            // nothing (no-op if branch, no actual check) — it was pure
            // dead-weight latency added to every single queue start on
            // top of whatever the resolve chain above already took. Real
            // idle/dead-URL detection already runs independently via the
            // player listener wired in init{} (handleIdleEvent), so this
            // wait was never load-bearing. Removing it shaves ~600ms off
            // tap-to-sound time for every queue play — this is the single
            // biggest "does it feel instant like Spotify" win available
            // in this file.
            reapplySpeed()
            // FIX ("blip/glitch at the start of every song"): call
            // ensureFocusBeforePlay() FIRST, while volume is still 0f from
            // hardStopAndMute() — it decides whether this needs the
            // OEM-chime-masking fade (fresh focus grab) and, if so, starts
            // that fade right here before any audio renders. restoreVolume()
            // still runs unconditionally right after (its mutedSessionCount
            // release must always happen, or the counter leaks — see its
            // doc comment), but with releaseVolumeToOne=false on a fresh
            // grab so it doesn't ALSO snap volume to 1f and race/fight the
            // fade ensureFocusBeforePlay() just started. On a normal resume
            // (focus already held — the common case for back-to-back songs
            // in one session), ensureFocusBeforePlay() does nothing to
            // volume, so the instant restoreVolume() is exactly what's
            // needed — same zero-latency feel as before.
            val freshGrab = !hasAudioFocus
            ensureFocusBeforePlay()
            restoreVolume(releaseVolumeToOne = !freshGrab)
            didMute = false
            player.play()
            started = true
            scheduleSettlePushStates(mySession)
        } catch (e: Exception) {
            emitError("playQueue failed for \"${songs[safeIndex].title}\" — ${e.message}")
        } finally {
            // Belt-and-suspenders: any branch/exception path we took above
            // resets isResolving, EXCEPT the deliberate "network genuinely
            // absent, stay pending" return (keepResolvingOnExit) — that one
            // needs isResolving to stay true so the UI keeps showing
            // loading instead of snapping back to a dead state. Also skip
            // the reset if a newer session has already superseded us —
            // stomping isResolving here would clobber whatever state the
            // newer session is now legitimately driving.
            if (!keepResolvingOnExit && mySession == playSessionId) {
                isResolving = false
            }
            // FIX ("skip jaldi jaldi karta hu to volume automatically gir
            // jata hai, dubara thik ho jata hai"): restoreVolume() used to
            // be gated behind `mySession == playSessionId` — an abandoned
            // session (superseded by a fast follow-up tap before it
            // finished) skipped it entirely, permanently leaving
            // player.volume at whatever hardStopAndMute() had set it to
            // (0f), since nothing else was ever responsible for restoring
            // on that abandoned session's behalf. Every session that
            // ACTUALLY MUTED (didMute — see hardStopAndMute's doc comment;
            // a session that was already superseded before hardStopAndMute
            // even ran never touched volume in the first place, so it must
            // NOT call restoreVolume, or it would wrongly release a
            // different session's still-active mute) calls restoreVolume()
            // here unconditionally so its own contribution always gets
            // released — restoreVolume()'s mutedSessionCount tracking (see
            // its doc comment) is what safely prevents this from
            // clobbering a genuinely newer session's still-active mute.
            if (didMute) restoreVolume()
            if (mySession == playSessionId) {
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

        // FIX (finally-override race): same pattern as playQueueInternal —
        // lets the deliberate "network genuinely absent, stay pending"
        // return below opt out of the finally block's isResolving reset.
        var keepResolvingOnExit = false
        // Tracks whether hardStopAndMute() below actually incremented
        // mutedSessionCount for THIS call — see hardStopAndMute's and
        // restoreVolume()'s doc comments (AurumAudioEngine.kt, near
        // playQueueInternal's matching field for the full reasoning).
        var didMute = false
        try {
            isLoadingNewSong = true
            didMute = hardStopAndMute(mySession)
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
                // First attempt missed — nudge the resolver's cache once
                // before falling into the indefinite-patience loop below,
                // in case a stale cached (dead) URL was the actual cause
                // rather than the connection itself.
                delay(700)
                if (mySession != playSessionId) return
                resolver.invalidate(song)
            }

            // No-auto-skip policy: retries the tapped song indefinitely
            // as long as there's any network path at all — see
            // resolveWithPatience(). A single-song tap has nothing to
            // fall back to anyway, so this is the only sane behavior:
            // keep trying, never silently fail the tap out from under
            // the user.
            if (url == null) {
                url = resolveWithPatience(song, mySession)
                if (mySession != playSessionId) return
            }

            if (url == null) {
                // Network genuinely, completely absent — leave the tap
                // pending rather than failing it. isResolving stays true
                // (loading state); resolveTakingLong (still true) keeps
                // the "check your connection" message up. The user can
                // always back out by tapping something else.
                keepResolvingOnExit = true
                pushState()
                return
            }

            resolveTakingLong = false
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

            // FIX (premium-feel latency) — same dead delay(600) removed as
            // in playQueueInternal above; see that comment for the full
            // reasoning. This is the direct single-song-tap path, so this
            // 600ms was the single most-hit artificial delay in the whole
            // engine — every home/search tap paid it.
            reapplySpeed()
            // FIX ("blip/glitch at the start of every song") — same fix as
            // playQueueInternal's matching call site; see that comment for
            // the full reasoning. ensureFocusBeforePlay() runs first, while
            // volume is still 0f, and handles the fresh-focus-grab fade
            // itself; restoreVolume() still always runs (releasing this
            // session's mutedSessionCount contribution) but is told not to
            // also snap volume to 1f when a fade is already in flight.
            val freshGrab = !hasAudioFocus
            ensureFocusBeforePlay()
            restoreVolume(releaseVolumeToOne = !freshGrab)
            didMute = false
            player.play()
            scheduleSettlePushStates(mySession)
        } catch (e: Exception) {
            emitError("playSong failed for \"${song.title}\" — ${e.message}")
        } finally {
            // See keepResolvingOnExit comment above playQueueInternal's
            // matching finally block — same override-race fix, mirrored
            // here for the single-tap path.
            if (!keepResolvingOnExit && mySession == playSessionId) {
                isResolving = false
            }
            // FIX — this used to only reset isLoadingNewSong inside the
            // `mySession == playSessionId` branch. When this call was
            // superseded by a newer tap (mySession != playSessionId,
            // e.g. via the `if (mySession != playSessionId) return`
            // early-outs above), isLoadingNewSong stayed stuck true
            // forever from THIS coroutine's perspective — and since it's
            // a single shared field, that stuck true value could survive
            // past the winning session's own completion in some
            // interleavings, silently blocking handleFreshStartIdle/
            // handleMidStreamIdle/startBufferingWatchdog (all gated on
            // `if (isLoadingNewSong) return`) from ever recovering a
            // genuinely stuck/dead stream until this orphaned coroutine's
            // own hard-cap timeout (8-20s) finally elapsed. Mirrors the
            // symmetric else-branch playQueueInternal's finally already
            // has for exactly this reason.
            if (mySession == playSessionId) {
                if (didMute) restoreVolume()
                isLoadingNewSong = false
                maybeAutoExtendQueue()
            } else {
                if (didMute) restoreVolume()
                isLoadingNewSong = false
            }
            pushState()
        }
    }

    private fun setSingleMediaItemInternal(url: String, song: NativeSong) {
        val item = buildMediaItem(song, url)
        // BUGFIX: setMediaItem() can synchronously fire
        // onMediaItemTransition -> handleCurrentIndexChanged before this
        // function's next line runs. liveMediaIds must already reflect
        // the new song by the time that happens, or handleCurrentIndexChanged
        // resolves index 0 against a stale/empty liveMediaIds and falls
        // through to the wrong branch — reintroducing the same wrong-song
        // flash the isLoadingNewSong/mediaItemCount guard above was meant
        // to close, just in this one-call-later window instead.
        liveMediaIds = mutableListOf(song.id)
        player.setMediaItem(item)
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

        // TIMEOUT-MISMATCH FIX (matches the 2026-09-01 fix in api_service.dart):
        // resolver.resolve() for a youtube song is HybridStreamResolver —
        // native YoutubeInnertube.resolve() first (unbounded, no internal
        // timeout; can itself take several seconds across its 2 transient-
        // error retries), THEN on native failure it falls through to
        // MethodChannelStreamResolver, which round-trips into Dart's
        // ApiService.resolveStreamUrl() — whose Worker route alone now
        // budgets a full 16s (see api_service.dart's routeTimeout). Both
        // legs run inside this ONE withTimeoutOrNull, so the old 18_000L
        // cap left native almost no room before cutting off a Dart resolve
        // that was still correctly working — exactly the "can't resolve
        // url" failures reported after the Dart timeout went 6s -> 16s.
        // Fix: give native's worst case (~6-8s) + Dart's full 16s Worker
        // budget real headroom instead of racing them against a cap that
        // was sized for the old, shorter Dart timeout.
        val perAttemptTimeoutMs = if (song.source == "youtube") 26_000L else 12_000L
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

    // No-auto-skip resolve policy (Spotify-style): the song the user
    // actually chose is never silently swapped out just because the
    // connection is slow. This keeps retrying resolveFast() for [song]
    // for as long as there's any network path at all — no attempt-count
    // ceiling, no wall-clock giving-up point. It only stops retrying if:
    //   - the session moves on (user skipped/changed songs — checked via
    //     mySession/playSessionId, same invariant as everywhere else),
    //   - or the network genuinely disappears entirely (no interface at
    //     all — retrying literally cannot succeed in that state).
    // resolveTakingLong flips true once RESOLVE_WARNING_THRESHOLD_MS has
    // passed with no success, purely so Dart can show a "check your
    // connection" message; it has no effect on retry behavior itself.
    // Callers are responsible for clearing resolveTakingLong + pushState()
    // once this returns (both the success and the network-lost-null path).
    private suspend fun resolveWithPatience(song: NativeSong, sessionId: Int): String? {
        // BUGFIX (offline/downloaded songs stuck on loading forever): this
        // loop used to check hasAnyNetworkConnection() before ever calling
        // resolveFast() — but resolveFast() has its own isLocal shortcut
        // that reads the file straight off disk and never touches the
        // network at all. With the phone offline (the normal case while
        // actually listening to downloaded songs), hasAnyNetworkConnection()
        // returned false immediately and this function bailed with null
        // before resolveFast() ever got a chance to hand back the local
        // file:// URI — so playQueueInternal/playSongInternal treated it
        // as "network absent, stay pending" and the UI sat on the loading
        // spinner forever, even though nothing here needed the network.
        // Local/downloaded songs must resolve instantly regardless of
        // connectivity, so check isLocal first and skip the network gate
        // (and the whole retry loop) entirely for them.
        if (song.isLocal) {
            return resolveFast(song, sessionId, maxAttempts = 1)
        }
        val startedAt = SystemClock.elapsedRealtime()
        var attempt = 0
        while (true) {
            if (sessionId != playSessionId) return null
            if (!hasAnyNetworkConnection()) {
                // No network path at all right now — nothing to retry
                // against. Not a skip: the caller keeps the song loaded/
                // pending and this same call site will naturally be
                // re-entered on the next play/retry trigger once
                // connectivity actually returns.
                return null
            }
            val url = try {
                withTimeoutOrNull(hardCapFor(song)) { resolveFast(song, sessionId) }
            } catch (e: CancellationException) {
                throw e
            }
            if (sessionId != playSessionId) return null
            if (!url.isNullOrEmpty()) return url

            if (!resolveTakingLong &&
                SystemClock.elapsedRealtime() - startedAt >= RESOLVE_WARNING_THRESHOLD_MS
            ) {
                resolveTakingLong = true
                pushState()
            }

            delay(retryBackoffMs(attempt))
            attempt++
        }
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

    // See bufferingWatchdogJob declaration above for why this exists.
    // Generous grace period — this must never fire for normal buffering
    // (slow-start on a fresh connection, brief rebuffer on a rough patch
    // of network), only for playback that's genuinely stuck. 20s is well
    // beyond both the 16s HTTP connect timeout and 8s read timeout
    // already configured above, so if either of those was going to fire
    // on its own and hand off to the existing error/idle recovery paths,
    // it already would have by the time this watchdog acts.
    private fun startBufferingWatchdog() {
        bufferingWatchdogJob?.cancel()
        val sessionAtStart = playSessionId
        val songAtStart = queueSongs.getOrNull(currentIndex)
        val posAtStart = player.currentPosition
        bufferingWatchdogJob = scope.launch {
            delay(20_000)
            if (sessionAtStart != playSessionId) return@launch
            if (player.playbackState != Player.STATE_BUFFERING) return@launch
            if (!player.playWhenReady) return@launch
            if (isLoadingNewSong) return@launch
            val song = queueSongs.getOrNull(currentIndex) ?: return@launch
            if (songAtStart == null || song.id != songAtStart.id) return@launch
            _log("[watchdog] Stuck buffering 20s+ on \"${song.title}\" — forcing recovery")
            // Reuses the exact same "splice a fresh URL in at the current
            // position" recovery handleMidStreamIdle already does for a
            // dead/expired CDN link — this is that same failure, just
            // detected by elapsed time instead of by an IDLE transition.
            handleMidStreamIdle(posAtStart.coerceAtLeast(player.currentPosition))
        }
    }

    private fun _log(msg: String) {
        if (BuildConfig.DEBUG) android.util.Log.d("AurumAudioEngine", msg)
    }

    // Spotify-style distinction: a device with an active network interface
    // but a genuinely slow/patchy connection should never see the song
    // change out from under it — it should just keep buffering/retrying
    // quietly until the data actually arrives. Only a real absence of any
    // network path (airplane mode, no SIM/WiFi at all) is treated as
    // unrecoverable-right-now, since no amount of waiting fixes that.
    // This is a coarse, synchronous check (link existence, not a live
    // reachability probe) deliberately — it only needs to answer "is there
    // any network path at all", which is exactly the same signal
    // SourceProvider on the Dart side already keys off of.
    private fun hasAnyNetworkConnection(): Boolean {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return true // fail open — never let a lookup failure masquerade as "offline"
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        } catch (_: Exception) {
            true // fail open — same reasoning as above
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Auto-retry-on-reconnect: resolveWithPatience() stops retrying (and
    // leaves the song sitting in its current "loading" state, per the
    // no-auto-skip policy) when the network is genuinely, completely
    // absent — there's nothing left to retry against at that point. But
    // once the network comes back, the user shouldn't have to notice and
    // manually tap something to resume; this listener catches that
    // transition and re-drives the resolve for whatever's pending, the
    // same way Spotify silently picks a stalled track back up the moment
    // connectivity returns.
    // ─────────────────────────────────────────────────────────────────
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private fun registerReconnectListener() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                // Only worth acting on if something is actually stuck
                // waiting — isResolving is the same flag pushState()
                // uses to report "loading" to Dart, so this only fires
                // work when the UI itself would be showing a spinner.
                // No-op otherwise, so this callback is cheap on every
                // ordinary network flap (screen off/on, wifi roaming)
                // that doesn't coincide with a stuck resolve.
                if (!isResolving) return
                val songToRetry = queueSongs.getOrNull(currentIndex) ?: return
                val sessionNow = playSessionId
                scope.launch {
                    // onAvailable can fire a beat before the network is
                    // actually fully usable for requests — a short delay
                    // avoids immediately re-failing into another "no
                    // network" result the instant this listener fires.
                    delay(500)
                    if (sessionNow != playSessionId) return@launch
                    if (!isResolving) return@launch
                    if (!hasAnyNetworkConnection()) return@launch
                    val freshUrl = resolveWithPatience(songToRetry, sessionNow)
                    if (sessionNow != playSessionId) return@launch
                    if (freshUrl == null) {
                        // Still nothing (e.g. flapped straight back off) —
                        // leave state as-is, pushState() already reflects
                        // "still trying" via isResolving/resolveTakingLong.
                        return@launch
                    }
                    resolveTakingLong = false
                    if (queueSongs.getOrNull(currentIndex)?.id != songToRetry.id) return@launch
                    try {
                        setSingleMediaItemInternal(freshUrl, songToRetry)
                        isResolving = false
                        // FIX ("pause karo, khud restart ho jaata hai"): only
                        // resume if the user hasn't paused since this retry
                        // started — see userPaused doc comment above.
                        if (!userPaused) player.play()
                        pushState()
                    } catch (e: Exception) {
                        isResolving = false
                        failPlayback(songToRetry, e.message ?: "setMediaItem failed after reconnect")
                    }
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (_: Exception) {
            // Registration failing (e.g. missing ACCESS_NETWORK_STATE on
            // some OEM lockdown) just means auto-retry-on-reconnect won't
            // fire — resolveWithPatience()'s own retry loop still covers
            // every other case, so this is a soft degradation, not fatal.
        }
    }

    private fun unregisterReconnectListener() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val callback = networkCallback
        if (cm != null && callback != null) {
            try { cm.unregisterNetworkCallback(callback) } catch (_: Exception) { /* already gone */ }
        }
        networkCallback = null
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
                        if (!userPaused) player.play()
                        pushState()
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

        // No-auto-skip policy: retries indefinitely while any network
        // path exists (see resolveWithPatience) instead of giving up
        // after 2 quick attempts and jumping to the next song. A slow
        // connection must never look identical to a dead song.
        isResolving = true
        pushState()
        val freshUrl = resolveWithPatience(songNow, sessionAtIdle)
        if (sessionAtIdle != playSessionId) return

        if (freshUrl == null) {
            // Network genuinely, completely absent — nothing left to try
            // right now. Leave this song loaded/pending (not skipped);
            // isResolving/resolveTakingLong keep the UI honestly showing
            // "still trying" rather than silently moving on.
            pushState()
            return
        }
        resolveTakingLong = false
        isResolving = false

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
            // FIX ("pause karo, khud restart ho jaata hai"): only resume
            // if the user hasn't paused since this retry started.
            if (!userPaused) player.play()
            // FIX (same spinner-stuck fix as handleMidStreamIdle's success
            // path below): explicit push instead of relying solely on the
            // player listener's own callbacks for this recovery-specific
            // state transition.
            pushState()
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
                        if (!userPaused) player.play()
                        pushState()
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

        // No-auto-skip policy: a genuinely slow (but real) connection
        // must never cause the song to change out from under the user —
        // keep quietly retrying with the loading state visible until the
        // data actually shows up (see resolveWithPatience). Only a
        // complete, genuine absence of network is unrecoverable right
        // now, and even then this doesn't skip — it just leaves the song
        // as-is until connectivity returns (see the null-freshUrl branch
        // below).
        isResolving = true
        pushState()
        val freshUrl = resolveWithPatience(song, sessionAtError)

        if (sessionAtError != playSessionId) return
        if (!stillOnThisSong()) { isResolving = false; return }

        if (freshUrl == null) {
            // Network genuinely, completely absent — leave the song
            // as-is rather than skipping; isResolving/resolveTakingLong
            // keep the UI honestly reflecting "still trying".
            pushState()
            return
        }
        resolveTakingLong = false

        try {
            val idx = player.currentMediaItemIndex
            if (idx < player.mediaItemCount && stillOnThisSong()) {
                val item = buildMediaItem(song, freshUrl)
                player.replaceMediaItem(idx, item)
                player.seekTo(idx, pos)
                // FIX ("pause karo, khud restart ho jaata hai"): only
                // resume if the user hasn't paused since this retry
                // started — see userPaused doc comment above. This is
                // the most commonly-hit of the three recovery paths
                // (fires on any expired/dead stream URL, which YouTube/
                // Saavn CDN links commonly become after sitting idle),
                // so this guard is the one most likely to fix the
                // reported "randomly restarts after I pause" behavior.
                if (!userPaused) player.play()
                isResolving = false
                // FIX (spinner stuck forever after a successful
                // expired-URL recovery — the one case this whole
                // function exists for): every other exit path here
                // either calls emitError (which pushes state via the
                // error stream) or falls all the way through to the
                // emitError call below. This success path was the
                // only one with no explicit pushState() of its own,
                // relying entirely on the player's own onIsPlaying/
                // onPlaybackStateChanged listener callbacks to notice
                // the IDLE→BUFFERING→READY cycle and push fresh state
                // to Dart. That's usually true, but isn't guaranteed
                // for every device/ExoPlayer version's exact callback
                // timing on this specific replaceMediaItem+seek+play
                // sequence — and when it doesn't fire, Dart's
                // optimistic isLoading (set right before the play()
                // call that triggered this whole recovery) never
                // receives the state event that would close it, even
                // though audio has genuinely resumed playing in the
                // background. Pushing explicitly here costs nothing
                // and removes that dependency entirely.
                pushState()
                return
            }
        } catch (e: Exception) { /* fall through to error below */ }

        // Reached only if applying the resolved URL to the player itself
        // failed (replaceMediaItem/seekTo/play threw, or the player's
        // media item index moved out from under us) — a genuine,
        // unrecoverable-right-now failure distinct from "still resolving
        // slowly", so this (and only this) path still advances the queue.
        isResolving = false
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
            // NOTE: no restoreVolume() here (deliberately removed) — this
            // recovery path runs mid-stream, after a song that was already
            // playing failed; player.volume was never muted for this flow
            // in the first place (only playQueueInternal/playSongInternal
            // ever call hardStopAndMute, and neither is on this call path),
            // so there is nothing here to restore. Calling it anyway would
            // incorrectly decrement mutedSessionCount for a mute this
            // function never took out — see restoreVolume()'s doc comment
            // for why that's unsafe: it could release a DIFFERENT,
            // genuinely in-flight session's still-active mute early.
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

        // BUGFIX: "tap a song, full player opens, correct audio plays in
        // the background, but the title/artwork show a DIFFERENT song
        // from the same list for ~2-3 seconds before snapping to the
        // right one." Root cause: hardStopAndMute() (called at the start
        // of every playSong/playQueue) calls player.stop() and
        // player.clearMediaItems() to tear down the previous track — and
        // both of those fire onMediaItemTransition, which routes here.
        // But queueSongs has ALREADY been reassigned to the NEW queue by
        // that point (set eagerly, before hardStopAndMute runs, so the UI
        // updates instantly) — so the leftover/reset index from the just-
        // cleared OLD player timeline (usually 0) got resolved against
        // the NEW queueSongs list, landing on whatever song happens to
        // sit at that index in the new queue — almost always NOT the one
        // that was actually tapped. That wrong id got pushed to Dart,
        // which briefly displayed it until the real song's MediaItem was
        // set and this fired again with the correct index.
        //
        // Fix: while a load is in flight (isLoadingNewSong / isResolving),
        // only trust an index that actually corresponds to a MediaItem
        // ExoPlayer currently holds. player.mediaItemCount == 0 is exactly
        // the stop()/clearMediaItems() case above — there is no real
        // "current song" to report yet, so skip pushing state for it
        // entirely and let the eventual setMediaItem() call fire the
        // correct transition once the new song is actually loaded.
        if ((isLoadingNewSong || isResolving) && player.mediaItemCount == 0) {
            return
        }

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
            ensureNextResolved(playSessionId)
            pushState()
            return
        }

        if (index != currentIndex && index < queueSongs.size) {
            currentIndex = index
        }
        maybeAutoExtendQueue()
        ensureNextResolved(playSessionId)
        pushState()
    }

    private fun applyCrossfadeFadeIn() {
        cancelAllVolumeFades()
        val mySession = playSessionId
        val steps = (crossfadeSecs * 10).toInt().coerceIn(1, 120)
        val stepMs = (crossfadeSecs * 1000 / steps).toLong()
        // BUGFIX: "changed the crossfade slider to max, and playback started
        // randomly dipping in volume for ~2s then slowly climbing back up,
        // on its own, without skipping tracks — until the app was
        // restarted." Root cause: this function used to hard-set
        // player.volume = 0f before starting the ramp. Every real track
        // change correctly starts silent and ramps up, so that was fine —
        // but onMediaItemTransition (which calls into here via
        // handleCurrentIndexChanged) can also fire from internal ExoPlayer
        // repositioning that ISN'T a genuine user-facing track change
        // (seek-based repositioning, buffering-state churn right after a
        // setCrossfadeSeconds() call touches player state). When that
        // spurious fire happened while a song was already mid-playback at
        // full volume, slamming volume to 0 and ramping back up over
        // crossfadeSecs produced exactly that dip-then-slowly-recover
        // artifact on a track that never actually changed.
        //
        // Fix: start the ramp from wherever player.volume ACTUALLY is
        // right now, not from a hardcoded 0f. A genuine track change still
        // starts the new MediaItem at volume 0 (ExoPlayer resets volume to
        // 1f on its own for a fresh item in some paths, but ties into
        // hardStopAndMute()'s explicit 0f below, so real transitions still
        // fade in from silence exactly as before). A spurious same-song
        // re-fire now ramps from whatever the current audible volume is
        // (typically already ~1f) up to 1f — a no-op in practice — instead
        // of audibly dipping first.
        val startVolume = player.volume
        fadeJob = scope.launch {
            for (step in 1..steps) {
                if (mySession != playSessionId) return@launch
                delay(stepMs)
                val progress = step.toFloat() / steps
                player.volume = (startVolume + (1f - startVolume) * progress).coerceIn(0f, 1f)
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
    // FIX: these are now suspend functions serialized on queueMutex (see
    // the mutex's doc comment above) instead of each firing an unawaited
    // scope.launch{}. The channel handler now calls these via
    // scope.launch { ... ; result.success(null) }, so Dart's `await
    // _engine.addToQueue(...)` genuinely doesn't resolve until the native
    // media-item list has actually been updated — closing the race that
    // let a fast-following moveQueueItem/skipToQueueItem run against a
    // still-mutating queue.
    suspend fun addToQueue(song: NativeSong) = queueMutex.withLock {
        addToQueueInternal(song, playSessionId)
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

    suspend fun removeFromQueue(index: Int) = queueMutex.withLock {
        if (index !in queueSongs.indices) return@withLock
        queueSongs = queueSongs.filterIndexed { i, _ -> i != index }
        if (index < liveMediaIds.size) {
            player.removeMediaItem(index)
            liveMediaIds.removeAt(index)
        }
        if (currentIndex > index) currentIndex--
        onQueueChanged?.invoke()
        pushState()
    }

    suspend fun moveQueueItem(from: Int, to: Int) = queueMutex.withLock {
        if (from !in queueSongs.indices || to !in queueSongs.indices) return@withLock
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

    // FIX ("UI badal jata hai, purana gaana kuch sec chalta reh jaata hai"
    // on mid-session skips): resolveQueueInBackground()'s priority window
    // only runs once, from the index playback STARTED at. A skip later in
    // the same session moves currentIndex well past that original window —
    // the paced tail (one song every PACED_RESOLVE_DELAY_MS) may not have
    // reached the new currentIndex+1 yet, so it isn't in liveMediaIds when
    // the user taps Next, and skipToQueueItemAwaitable falls back to a
    // full playQueueInternal() resolve — exactly the visible lag reported.
    // Fix: every time currentIndex actually changes, opportunistically
    // resolve just the ONE immediate-next song outside the paced walk, so
    // "next" is essentially always pre-buffered regardless of where the
    // paced tail currently is. Cheap and idempotent — no-ops instantly if
    // that song is already in liveMediaIds, and reuses the same `scope` /
    // queueMutex-guarded splice path as the main resolver, so it adds no
    // new thread, wake-lock, or polling loop.
    private fun ensureNextResolved(sessionId: Int) {
        val nextIdx = currentIndex + 1
        if (nextIdx >= queueSongs.size) return
        val nextSong = queueSongs[nextIdx]
        if (liveMediaIds.contains(nextSong.id)) return // already buffered, nothing to do
        scope.launch {
            if (sessionId != playSessionId) return@launch
            try {
                val url = resolveFast(nextSong, sessionId, maxAttempts = 1) ?: return@launch
                if (sessionId != playSessionId) return@launch
                queueMutex.withLock {
                    if (sessionId != playSessionId) return@withLock
                    if (liveMediaIds.contains(nextSong.id)) return@withLock // resolved elsewhere meanwhile
                    player.addMediaItem(buildMediaItem(nextSong, url))
                    liveMediaIds.add(nextSong.id)
                    handleCurrentIndexChanged(player.currentMediaItemIndex)
                }
            } catch (e: Exception) { /* best-effort — normal paced walk still covers it */ }
        }
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
                    if (i - startIndex > priorityForwardWindow) {
                        delay(PACED_RESOLVE_DELAY_MS)
                        if (sessionId != playSessionId) return@launch
                    }
                    try {
                        val url = resolveFast(songs[i], sessionId, maxAttempts = 1)
                        if (sessionId != playSessionId) return@launch
                        if (url != null && sessionId == playSessionId) {
                            // FIX ("Up Next tap during the first few seconds of
                            // a queue occasionally still landed on the wrong
                            // song even after the liveMediaIds-based lookup
                            // fix in skipToQueueItemAwaitable"): the splice
                            // here (addMediaItem + liveMediaIds mutation) ran
                            // with no lock at all, while skipToQueueItemAwaitable
                            // (and addToQueue/removeFromQueue/moveQueueItem)
                            // all read/mutate the exact same liveMediaIds under
                            // queueMutex. A tap landing in the split-second
                            // between this addMediaItem() call and the
                            // liveMediaIds.add() right after it could compute
                            // a livePos against a liveMediaIds that didn't yet
                            // match player's real timeline, seeking to the
                            // wrong item. Wrapping just this one splice step
                            // (not the resolveFast() network call above it) in
                            // queueMutex closes that window without holding
                            // the lock for the slow network part — a skip tap
                            // still only ever waits for a single fast splice
                            // step, never a whole resolve.
                            queueMutex.withLock {
                                if (sessionId != playSessionId) return@withLock
                                player.addMediaItem(buildMediaItem(songs[i], url))
                                liveMediaIds.add(songs[i].id)
                                handleCurrentIndexChanged(player.currentMediaItemIndex)
                            }
                        }
                    } catch (e: Exception) { /* skip this song, continue */ }
                }

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
                            // FIX (2026-07-09) — "song ruk ruk jata hai, 1-2
                            // sec ke liye": this used to follow addMediaItem(0,
                            // ...) with an explicit player.seekTo(playerIndex,
                            // player.currentPosition) "to correct the index
                            // shift". That seek is not just unnecessary —
                            // ExoPlayer ALREADY keeps playing the same item
                            // and auto-adjusts currentMediaItemIndex on its
                            // own whenever items are inserted before the
                            // current one; the timeline shifts, playback does
                            // not. Calling seekTo() on the item that is
                            // ACTIVELY PLAYING — even to its own current
                            // position — forces ExoPlayer to treat it as a
                            // real seek: it re-evaluates/reconstructs the
                            // buffered window around that position, which
                            // audibly interrupts rendering for ~1-2s. Because
                            // this fires once per song walked in the backward
                            // prewarm window (every PACED_RESOLVE_DELAY_MS
                            // during ordinary playback, not just at queue
                            // edges), it reproduced as periodic,
                            // seemingly-random stutter throughout a song —
                            // exactly the reported symptom. Simply not
                            // seeking after the insert removes the bogus
                            // seek while leaving the insert (and therefore
                            // the backward instant-skip window it exists
                            // for) fully intact.
                            //
                            // Same queueMutex-around-splice-only fix as the
                            // forward loop above — see that comment for why.
                            queueMutex.withLock {
                                if (sessionId != playSessionId) return@withLock
                                player.addMediaItem(0, buildMediaItem(songs[i], url))
                                liveMediaIds.add(0, songs[i].id)
                                handleCurrentIndexChanged(player.currentMediaItemIndex)
                            }
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
    /** True once a Cast session has actually started receiving media —
     *  checked at the top of every transport control below so cast
     *  routing never touches the local `player`'s carefully-tuned skip/
     *  resolve/splice logic. Deliberately checks _castManager (the
     *  nullable backing field, not the lazy-init getter) so simply
     *  reading it before any cast usage doesn't construct a CastManager
     *  that was never needed. */
    private val isCastActive: Boolean
        get() = activeCastPlayer != null

    /** Safe accessor for the active CastPlayer — never throws, unlike a
     *  chain of !! assertions. Returns null (rather than crashing) in
     *  the defensive edge case where isCasting reports true but
     *  castPlayer somehow isn't available; every call site below already
     *  falls through to local playback if this is null, so that edge
     *  case degrades gracefully instead of crashing playback entirely. */
    private val activeCastPlayer: CastPlayer?
        get() {
            val mgr = _castManager ?: return null
            if (!mgr.isCasting) return null
            return mgr.castPlayer
        }

    fun play() {
        userPaused = false
        activeCastPlayer?.let { it.play(); return }
        restoredSilently = false
        player.play()
    }
    fun pause() {
        userPaused = true
        activeCastPlayer?.let { it.pause(); return }
        player.pause()
    }
    fun stop() {
        activeCastPlayer?.let { try { it.stop() } catch (e: Exception) { }; return }
        try { player.stop() } catch (e: Exception) { }
    }
    fun seek(positionMs: Long) {
        activeCastPlayer?.let { it.seekTo(positionMs); return }
        player.seekTo(positionMs)
    }

    // FIX — "spam-tapping skip fast makes UI/audio lag behind, catches up
    // late": skipToNext()/skipToPrevious() previously launched a brand new
    // coroutine per call, each of which queued on skipMutex and ran to
    // completion in full sequence. Rapid-tapping skip 5 times in a row used
    // to queue 5 FULL sequential skip operations back-to-back — each one
    // doing a real seekToNext()/play() (and, at queue edges,
    // playQueueInternal's real resolve/prepare) — so the visible song only
    // "arrived" after all 5 had finished executing one after another,
    // reading as UI lag no matter how fast the taps actually were.
    //
    // FIX: a generation token, bumped on every skip call. Each queued
    // coroutine checks — right after acquiring the mutex — whether it's
    // still the LATEST request; if a newer skip came in while it was
    // waiting, it abandons immediately without touching the player. This
    // means no matter how many times the user taps in a burst, only the
    // very last tap's target actually executes — the UI/audio always jumps
    // straight to wherever the user's fastest final tap landed, instantly,
    // with zero queued catch-up lag.
    private var skipGen = 0

    fun skipToNext() {
        val cp = activeCastPlayer
        if (cp != null) {
            if (cp.hasNextMediaItem()) { cp.seekToNext(); cp.play() }
            else if (cp.repeatMode == Player.REPEAT_MODE_ALL && cp.mediaItemCount > 0) { cp.seekTo(0, 0); cp.play() }
            return
        }
        val gen = ++skipGen
        scope.launch {
            skipMutex.withLock {
                if (gen != skipGen) return@withLock
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
        val cp = activeCastPlayer
        if (cp != null) {
            if (cp.currentPosition > 3000) cp.seekTo(0)
            else if (cp.hasPreviousMediaItem()) cp.seekToPrevious()
            return
        }
        val gen = ++skipGen
        scope.launch {
            skipMutex.withLock {
                if (gen != skipGen) return@withLock
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

    // FIX (Up Next "plays the wrong song"): this used to be fire-and-forget
    // — the MethodChannel handler called it and replied success() to Dart
    // IMMEDIATELY, before the queueMutex-protected seek below ever ran.
    // Dart's `await` on skipToQueueItem therefore resolved before the
    // native engine had actually moved, so a fast next tap (or a queue
    // read) could land while the real seek was still in flight against a
    // stale/mid-mutation queue snapshot — the same class of race that
    // addToQueue/removeFromQueue/moveQueueItem were already fixed for by
    // being made suspend + queueMutex-serialized. Now suspend, so the
    // channel handler's coroutine — and therefore Dart's await — only
    // completes once the seek has genuinely happened.
    suspend fun skipToQueueItemAwaitable(index: Int) {
        val cp = activeCastPlayer
        if (cp != null) {
            // FIX: this cast branch used to run outside queueMutex entirely
            // — a queue mutation (addToQueue/moveQueueItem) firing while
            // casting could still race this seekTo the same way the local
            // ExoPlayer path below was already fixed for. Wrapping it in
            // the same queueMutex closes that gap for casting too.
            queueMutex.withLock {
                if (index < cp.mediaItemCount) {
                    currentIndex = index
                    pushState()
                    cp.seekTo(index, 0)
                    cp.play()
                }
            }
            return
        }
        val gen = ++skipGen
        // FIX: also serialize against queueMutex — without this, a
        // skipToQueueItem could still run its seekTo(index, 0) WHILE
        // an addToQueue/moveQueueItem from the same burst of taps
        // (e.g. Up Next "play this now") was mid-mutation on the
        // native media-item list, seeking to an index whose meaning
        // was about to change underneath it.
        queueMutex.withLock {
            skipMutex.withLock {
                if (gen != skipGen) return@withLock
                if (index !in queueSongs.indices) return@withLock

                // FIX ("tap a song in Up Next, a DIFFERENT song plays; full
                // player briefly shows the tapped song's title/artwork then
                // reverts to the old one still playing"): `index` here is a
                // position in `queueSongs` (Dart's full queue). This used to
                // be fed straight into `player.seekTo(index, 0)` as if it
                // were ExoPlayer's OWN timeline position — but ExoPlayer's
                // timeline only ever holds `liveMediaIds`, a partial mirror
                // of `queueSongs` that grows/reorders asynchronously via
                // resolveQueueInBackground (forward AND backward splicing,
                // the latter literally inserting at position 0 — see the
                // addMediaItem(0, ...) call above). Right after any
                // playQueue/playSong start, ExoPlayer often holds only the
                // ONE just-played song while the rest of the queue is still
                // being spliced in, so `queueSongs` and ExoPlayer's timeline
                // are frequently NOT index-aligned — tapping Up Next row 4
                // could genuinely seek to whatever unrelated song ExoPlayer
                // currently has loaded at raw position 4.
                //
                // Fix: resolve the tapped song's actual id to its REAL
                // position in ExoPlayer's timeline via liveMediaIds (the
                // exact same id-based lookup handleCurrentIndexChanged
                // already uses in the opposite direction). Only seek
                // directly if that id is already loaded; otherwise this is
                // a song ExoPlayer hasn't spliced in yet, so — same as
                // before — fall back to a full playQueueInternal restart
                // from that song, which resolves and loads it properly
                // instead of seeking to a wrong/unrelated media item.
                val targetSong = queueSongs[index]
                val livePos = liveMediaIds.indexOf(targetSong.id)
                if (livePos != -1 && livePos < player.mediaItemCount && !splicingInProgress) {
                    currentIndex = index
                    pushState()
                    player.seekTo(livePos, 0)
                    userPaused = false
                    player.play()
                } else {
                    playQueueInternal(queueSongs, index)
                }
            }
        }
    }

    fun setRepeatMode(mode: String) { // "none" | "one" | "all"
        val repeatMode = when (mode) {
            "one" -> Player.REPEAT_MODE_ONE
            "all" -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
        player.repeatMode = repeatMode
        activeCastPlayer?.repeatMode = repeatMode
    }

    fun setShuffleMode(enabled: Boolean) {
        player.shuffleModeEnabled = enabled
        activeCastPlayer?.shuffleModeEnabled = enabled
    }
    fun setSpeed(speed: Float) {
        // Cast SDK / most Cast receivers don't support arbitrary playback
        // speed the way local ExoPlayer does — silently a no-op on
        // CastPlayer if unsupported, so we still update local `player`'s
        // speed (takes effect immediately if/when casting ends) but don't
        // bother forwarding to castPlayer.
        player.setPlaybackSpeed(speed)
    }
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

    /** Sleep-timer expiry with a smooth volume fade instead of an abrupt
     *  cut — matches the fade-in/out feel already used for ducking/
     *  crossfade above, rather than the jarring instant player.pause()
     *  a plain timer-fires-pause() would give.
     *
     *  Goes through cancelAllVolumeFades() first (same choke point as
     *  every other fade) so a duck or crossfade in flight can't fight
     *  this one for control of player.volume.
     *
     *  Fades whichever player is actually driving playback right now.
     *  Cast is resolved ONCE up front (not re-checked every step) — if
     *  the target flipped mid-fade the fade would tear across two
     *  different Player objects and neither would land at a clean 0,
     *  so we commit to one target for the whole run. CastPlayer exposes
     *  the same Media3 `volume` property as the local player (routed
     *  through the Cast Remote Media Client), so the identical ramp
     *  logic applies to both — previously this only ever faded the
     *  local player and cast sessions got an abrupt cut with no fade.
     *
     *  Restores volume to 1f right after pausing — pause() does not
     *  touch volume on its own, so without this the *next* time the
     *  user presses play, playback would silently resume at 0 volume,
     *  looking exactly like a playback-is-broken bug. */
    fun sleepFadeOutAndPause(fadeMs: Long = 8000L) {
        cancelAllVolumeFades()
        val target: Player = activeCastPlayer ?: player
        sleepFadeJob = scope.launch {
            val start = target.volume
            val steps = 40
            val stepDelay = (fadeMs / steps).coerceAtLeast(1L)
            for (i in 1..steps) {
                val t = i / steps.toFloat()
                target.volume = start * (1f - t)
                delay(stepDelay)
            }
            target.volume = 0f
            target.pause()
            target.volume = 1f
        }
    }

    fun currentQueue(): List<NativeSong> = queueSongs
    fun currentSongIndex(): Int = currentIndex
    fun currentSong(): NativeSong? = queueSongs.getOrNull(currentIndex)

    /** Snapshot of the current queue paired with each song's already-
     *  resolved stream URL, for handing off to CastPlayer when a Cast
     *  session starts. Only includes songs Media3 has actually loaded a
     *  MediaItem for (i.e. `player.getMediaItemAt`'s URI) — songs further
     *  ahead in queueSongs that haven't been resolved/spliced in yet are
     *  simply skipped rather than triggering a fresh resolve here; they'll
     *  get added as playback reaches them normally (see maybeAutoExtendQueue/
     *  splicing elsewhere), same lazy-resolve behavior as local playback. */
    fun currentQueueForCast(): List<Pair<NativeSong, String>> {
        val result = mutableListOf<Pair<NativeSong, String>>()
        for (i in 0 until player.mediaItemCount) {
            val song = queueSongs.getOrNull(i) ?: continue
            val uri = player.getMediaItemAt(i).localConfiguration?.uri?.toString() ?: continue
            result.add(song to uri)
        }
        return result
    }

    /** Index into currentQueueForCast()'s result matching currentIndex —
     *  since some early queue entries may be skipped (see above) if
     *  Media3 hasn't resolved them yet, this recomputes the offset rather
     *  than assuming it equals currentIndex directly. */
    fun currentCastStartIndex(): Int {
        var idx = 0
        for (i in 0 until player.mediaItemCount) {
            if (queueSongs.getOrNull(i) == null) continue
            if (player.getMediaItemAt(i).localConfiguration?.uri == null) continue
            if (i == currentIndex) return idx
            idx++
        }
        return 0
    }

    /** Full-queue variant for Cast handoff: unlike [currentQueueForCast]
     *  (which only includes songs the LOCAL player has already loaded),
     *  this resolves EVERY song in queueSongs, reusing the already-
     *  loaded local URL where Media3 has one and falling back to
     *  [resolver] (the same HybridStreamResolver/YoutubeInnertube chain
     *  playback itself uses) for the rest. This matters because once
     *  handed off, CastPlayer navigates its OWN queue independently —
     *  it has no way to call back into this engine mid-cast to lazily
     *  resolve a song the way maybeAutoExtendQueue does for local
     *  playback, so every song needs a working URL up front or skip/
     *  next on the receiver will land on a track with nothing to play.
     *  Songs that fail to resolve are dropped from the cast queue
     *  entirely (rather than sent with a null/broken URL that would
     *  silently stall the receiver) — same "graceful skip" behavior as
     *  a resolve failure during normal local playback.
     *
     *  Also updates [_lastCastStartIndex] as a side effect, so a caller
     *  reads that AFTER awaiting this function to get the correct start
     *  offset even when earlier songs were dropped — see
     *  currentCastStartIndexInFullQueue(). */
    suspend fun currentFullQueueForCast(resolver: StreamResolver): List<Pair<NativeSong, String>> {
        val loadedUrls = mutableMapOf<Int, String>()
        for (i in 0 until player.mediaItemCount) {
            player.getMediaItemAt(i).localConfiguration?.uri?.toString()?.let { loadedUrls[i] = it }
        }
        val result = mutableListOf<Pair<NativeSong, String>>()
        var resolvedStartIndex = 0
        for (i in queueSongs.indices) {
            val song = queueSongs[i]
            val url = loadedUrls[i] ?: try {
                resolver.resolve(song, forceRefresh = false)
            } catch (e: Exception) {
                null
            }
            if (url != null) {
                result.add(song to url)
                if (i < currentIndex) resolvedStartIndex++
            }
        }
        _lastCastStartIndex = resolvedStartIndex
        return result
    }

    private var _lastCastStartIndex = 0

    /** Start index into [currentFullQueueForCast]'s result, correctly
     *  accounting for any songs dropped before currentIndex due to
     *  resolve failures. MUST be read only after awaiting
     *  currentFullQueueForCast — it's a side-channel result rather than
     *  a return value only because the channel-handler call site awaits
     *  the queue first and needs the matching index right after,
     *  mirroring how currentCastStartIndex() pairs with
     *  currentQueueForCast() above. */
    fun currentCastStartIndexInFullQueue(): Int = _lastCastStartIndex

    /** Current local playback position — read once at the moment a Cast
     *  session starts, so the receiver can resume from where the phone
     *  left off instead of restarting the song from 0. */
    fun currentLocalPositionMs(): Long = player.currentPosition

    /** Pauses (does not stop/clear) the local player — used when a Cast
     *  session starts, so local playback is silent while casting but the
     *  queue/position stays intact for an instant, clean handoff back if
     *  the Cast session ends. */
    fun pauseLocalForCastHandoff() { player.pause() }

    // ─────────────────────────────────────────────────────────────────
    // In-app audio output device picker (speaker/wired/Bluetooth/USB) —
    // see AurumAudioOutputManager for the full rationale. Built lazily so
    // it's constructed after `player` and `audioManager` above already
    // exist (Kotlin property initialization order requires this, since
    // both are declared earlier in this class).
    // ─────────────────────────────────────────────────────────────────
    private var _outputManager: AurumAudioOutputManager? = null
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    val outputManager: AurumAudioOutputManager
        get() = _outputManager ?: AurumAudioOutputManager(context, audioManager, player).also {
            _outputManager = it
        }

    // ─────────────────────────────────────────────────────────────────
    // Chromecast — see AurumCastManager for the full rationale. Built
    // lazily for the same Kotlin property-init-order reason as
    // outputManager above. AurumEngineChannelHandler owns wiring
    // onSessionStarted/onSessionEnded to actually hand off playback
    // (loading the current queue into castPlayer / pausing local
    // player), since that handoff needs the channel handler's queue
    // snapshot — this engine only exposes the manager + a way to push a
    // fresh state snapshot so the cast connect/disconnect moment is
    // reflected in the very next EventChannel tick.
    // ─────────────────────────────────────────────────────────────────
    private var _castManager: AurumCastManager? = null
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    val castManager: AurumCastManager
        get() = _castManager ?: AurumCastManager(context).also {
            _castManager = it
        }

    /** Re-emits state immediately — used after a cast session starts/ends
     *  so the "casting to X" UI updates without waiting for the next
     *  natural playback tick (which may be several seconds away, or may
     *  never come again if local `player` is now paused/idle because
     *  audio moved to the cast receiver). */
    fun refreshState() = pushState()

    fun release() {
        fadeJob?.cancel()
        idleWatchdogJob?.cancel()
        unregisterReconnectListener()
        scope.cancel()
        effects.dispose()
        abandonAudioFocus()
        _outputManager?.release()
        _castManager?.release()
        player.release()
    }
}
