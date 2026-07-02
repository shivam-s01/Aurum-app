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

    private val resolver = MethodChannelStreamResolver(messenger)
    val engine: AurumAudioEngine = AurumMediaSessionService.sharedEngine
        ?: AurumAudioEngine(context.applicationContext, resolver)
    private val appContext = context.applicationContext
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
        // Queue/song changes are also the signal to (re)start the
        // foreground MediaSessionService — Media3 needs the service
        // actually started (not just bound) to keep it alive and
        // foreground-promoted while music plays in the background,
        // mirroring what AudioService.init()/androidNotificationOngoing
        // used to do for us automatically.
        engine.onQueueChanged = {
            androidx.core.content.ContextCompat.startForegroundService(
                appContext,
                android.content.Intent(appContext, AurumMediaSessionService::class.java),
            )
        }

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
                "lookaheadResolve" -> {
                    engine.lookaheadResolve(parseSong(call.argument<Map<String, Any?>>("song")!!))
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
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("AUDIO_ENGINE_ERROR", e.message, null)
        }
    }

    fun release() {
        stateJob?.cancel()
        engine.release()
    }
}
