package com.aurum.music

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class AurumEngineChannelHandler(context: Context, messenger: BinaryMessenger) {

    companion object {
        private const val METHOD_CHANNEL = "com.aurum.music/audio_engine"
        private const val EVENT_CHANNEL = "com.aurum.music/audio_engine_state"
        private const val ERROR_CHANNEL = "com.aurum.music/audio_engine_errors"
    }

    private val resolver = HybridStreamResolver(messenger)
    val engine: AurumAudioEngine = AurumMediaSessionService.sharedEngine
        ?: AurumAudioEngine(context.applicationContext, resolver)
    private val scope = CoroutineScope(Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var errorSink: EventChannel.EventSink? = null
    private val callbackChannel = MethodChannel(messenger, METHOD_CHANNEL)

    init {
        // Publish the engine BEFORE the service can possibly start, so
        // AurumMediaSessionService.onCreate() always finds a non-null
        // sharedEngine (see the defensive stopSelf() fallback there).
        AurumMediaSessionService.sharedEngine = engine

        engine.onPlaybackError = { message, silent ->
            errorSink?.success(mapOf("message" to message, "silent" to silent))
        }
        // NOTE: we do NOT manually call startForegroundService() here.
        //
        // Media3's MediaSessionService promotes itself to a foreground
        // service automatically — internally, whenever the MediaSession's
        // player starts actually playing, MediaSessionService calls
        // startForeground() itself via its MediaNotificationManager,
        // using the notification built from the player's current
        // MediaMetadata (see AurumMediaSessionService, which does not
        // override onUpdateNotification — that's what leaves this default
        // behavior in place).
        //
        // The PREVIOUS version of this code called
        // ContextCompat.startForegroundService(...) manually on every
        // queue change, racing Media3's own foreground promotion: Android
        // requires startForeground() within ~5s of startForegroundService()
        // being called, but a manual call here could fire before playback
        // (and therefore Media3's own notification) was actually ready,
        // producing an intermittent
        // android.app.ForegroundServiceDidNotStartInTimeException crash —
        // exactly the "keeps stopping" / no background playback / no lock
        // screen controls symptom this fixes. Removing the manual call
        // lets Media3 own the entire foreground lifecycle, which is the
        // documented/supported pattern.
        engine.onQueueChanged = { /* no-op — Media3 handles foreground promotion internally */ }

        // Reverse channel: notification/lock-screen heart tap → Dart's
        // FavoritesProvider.toggleFavorite(). Dart is expected to call
        // setCurrentSongLiked() back once the toggle completes so the icon
        // reflects the authoritative (persisted) state rather than an
        // optimistic native-side flip.
        engine.onLikeToggleRequested = { songId ->
            callbackChannel.invokeMethod("onLikeToggleRequested", mapOf("songId" to songId))
        }

        callbackChannel.setMethodCallHandler(::onMethodCall)

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                stateJob = scope.launch {
                    engine.state.collect { s ->
                        sink.success(
                            mapOf(
                                "processingState" to s.processingState,
                                "playing" to s.playing,
                                "positionMs" to s.positionMs,
                                "bufferedPositionMs" to s.bufferedPositionMs,
                                "durationMs" to s.durationMs,
                                "currentIndex" to s.currentIndex,
                                "speed" to s.speed,
                                "queueIds" to s.queueIds,
                                "currentSongId" to s.currentSongId,
                                "liked" to s.liked,
                            )
                        )
                    }
                }
            }
            override fun onCancel(args: Any?) { stateJob?.cancel(); stateJob = null }
        })

        EventChannel(messenger, ERROR_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) { errorSink = sink }
            override fun onCancel(args: Any?) { errorSink = null }
        })
    }

    private fun parseSong(map: Map<*, *>): NativeSong = NativeSong(
        id = map["id"] as String,
        title = map["title"] as? String ?: "",
        artist = map["artist"] as? String ?: "",
        album = map["album"] as? String ?: "",
        artworkUrl = map["artworkUrl"] as? String ?: "",
        source = map["source"] as? String ?: "saavn",
        isLocal = map["isLocal"] as? Boolean ?: false,
        localPath = map["localPath"] as? String,
    )

    @Suppress("UNCHECKED_CAST")
    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "playQueue" -> {
                    val songs = (call.argument<List<Map<String, Any?>>>("songs") ?: emptyList()).map(::parseSong)
                    val startIndex = call.argument<Int>("startIndex") ?: 0
                    engine.playQueue(songs, startIndex)
                    result.success(null)
                }
                "playSong" -> {
                    engine.playSong(parseSong(call.argument<Map<String, Any?>>("song")!!))
                    result.success(null)
                }
                "addToQueue" -> {
                    engine.addToQueue(parseSong(call.argument<Map<String, Any?>>("song")!!))
                    result.success(null)
                }
                "removeFromQueue" -> {
                    engine.removeFromQueue(call.argument<Int>("index") ?: -1)
                    result.success(null)
                }
                "moveQueueItem" -> {
                    engine.moveQueueItem(call.argument<Int>("from") ?: 0, call.argument<Int>("to") ?: 0)
                    result.success(null)
                }
                "clearQueue" -> { engine.clearQueue(); result.success(null) }
                "play" -> { engine.play(); result.success(null) }
                "pause" -> { engine.pause(); result.success(null) }
                "stop" -> { engine.stop(); result.success(null) }
                "seek" -> {
                    engine.seek((call.argument<Number>("positionMs") ?: 0).toLong())
                    result.success(null)
                }
                "skipToNext" -> { engine.skipToNext(); result.success(null) }
                "skipToPrevious" -> { engine.skipToPrevious(); result.success(null) }
                "skipToQueueItem" -> {
                    engine.skipToQueueItem(call.argument<Int>("index") ?: 0)
                    result.success(null)
                }
                "setRepeatMode" -> {
                    engine.setRepeatMode(call.argument<String>("mode") ?: "none")
                    result.success(null)
                }
                "setShuffleMode" -> {
                    engine.setShuffleMode(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "setSpeed" -> {
                    engine.setSpeed((call.argument<Number>("speed") ?: 1.0).toFloat())
                    result.success(null)
                }
                "setCurrentSongLiked" -> {
                    engine.setCurrentSongLiked(call.argument<Boolean>("liked") ?: false)
                    AurumMediaSessionService.instance?.onLikedStateChanged()
                    result.success(null)
                }
                "setCrossfadeSeconds" -> {
                    engine.setCrossfadeSeconds(call.argument<Double>("seconds") ?: 0.0)
                    result.success(null)
                }
                "sleepAfterCurrentSong" -> { engine.sleepAfterCurrentSong(); result.success(null) }
                "applyAudioEffects" -> {
                    val bassBoost = call.argument<Boolean>("bassBoost") ?: false
                    val volNorm = call.argument<Boolean>("volumeNormalization") ?: false
                    // Dart sends gains already converted to millibels (see
                    // NativeAudioEngine.applyAudioEffects — dB * 100).
                    @Suppress("UNCHECKED_CAST")
                    val bandGainsMb = (call.argument<List<Any>>("bandGainsMb"))
                        ?.map { (it as Number).toInt() }
                    engine.effects.applySettings(bassBoost, volNorm, bandGainsMb)
                    result.success(null)
                }
                "getEqualizerBands" -> {
                    result.success(engine.effects.describeBands())
                }
                "applyPremiumSound" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    engine.effects.applyPremiumSound(enabled)
                    result.success(null)
                }
                "reportResolvedBitrate" -> {
                    val kbps = call.argument<Int>("kbps")
                    engine.effects.reportSourceBitrate(kbps)
                    result.success(null)
                }
                "getPremiumSoundCapabilities" -> {
                    result.success(engine.effects.describeCapabilities())
                }
                "setPremiumSoundCompare" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    engine.effects.setPremiumSoundCompare(enabled)
                    result.success(null)
                }
                "exitPremiumSoundCompare" -> {
                    engine.effects.exitPremiumSoundCompare()
                    result.success(null)
                }
                // FIX (2026-07-07) — "downloads fail / stuck resolving":
                // DownloadProvider.download() (Dart) was calling
                // ApiService.resolveStreamUrl() directly — the OLD,
                // Worker-only resolve chain (Cloudflare Worker's SABR-gated
                // YouTube clients + Piped fallback), completely bypassing
                // the native YoutubeInnertube/NewPipeExtractor path that
                // HybridStreamResolver already gives live playback. Live
                // playback got reliable once NewPipeExtractor was bumped to
                // v0.26.3, but downloads never benefited from that fix
                // because they never went through this resolver at all.
                //
                // This exposes the SAME resolver playback uses
                // (native-first via YoutubeInnertube, falling back to the
                // Worker/Dart chain only if the native attempt genuinely
                // fails) as a standalone, one-shot method call — no queue,
                // no player state, no engine side effects. Dart's
                // DownloadProvider calls this instead of
                // ApiService.resolveStreamUrl() directly for youtube-source
                // downloads (see NativeEngineBridge.resolveForDownload +
                // the corresponding DownloadProvider change).
                "resolveForDownload" -> {
                    val song = parseSong(call.argument<Map<String, Any?>>("song")!!)
                    scope.launch {
                        val url = try {
                            resolver.resolve(song, forceRefresh = false)
                        } catch (e: Exception) {
                            null
                        }
                        result.success(url)
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("AUDIO_ENGINE_ERROR", e.message, null)
        }
    }

    /**
     * Called from MainActivity.onDestroy(). THE actual fix for
     * "background/lock-screen band ho jaata hai": this used to call
     * engine.release(), which calls player.release() on the SAME ExoPlayer
     * instance AurumMediaSessionService's MediaSession is built on (they
     * share one AurumAudioEngine — see sharedEngine). MainActivity gets
     * destroyed far more often than people expect (recents swipe, screen
     * rotation edge cases, OS reclaiming the activity while the process
     * stays alive) — every one of those was silently killing playback and
     * tearing down the MediaSession, even mid-song.
     *
     * The Activity does not own the engine's lifecycle; the foreground
     * service does. All this should do is stop forwarding state to a
     * now-dead Dart EventChannel sink. The engine/player stays alive and
     * keeps playing in the background; AurumMediaSessionService.onTaskRemoved
     * already contains the correct logic for stopping the player when
     * that's actually appropriate (nothing queued / not playing).
     */
    fun release() {
        stateJob?.cancel()
    }
}
