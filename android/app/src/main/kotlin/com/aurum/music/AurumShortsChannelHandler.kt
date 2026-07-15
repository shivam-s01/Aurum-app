package com.aurum.music

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Dart<->native bridge for the Shorts feed. Dart already has the
 * playable previewUrl (from iTunes, via ItunesShortsApi) by the time
 * it calls playSong/preloadNext — there's no search/resolve step on
 * the native side anymore, this handler just passes the URL straight
 * through to AurumShortsEngine's ExoPlayer instances. Native pushes
 * status+position+isPlaying back over the event channel so Dart's UI
 * (progress bar, play/pause icon, 30s auto-advance) stays in sync.
 */
class AurumShortsChannelHandler(context: Context, messenger: BinaryMessenger) {

    companion object {
        private const val METHOD_CHANNEL = "com.aurum.music/shorts_engine"
        private const val EVENT_CHANNEL = "com.aurum.music/shorts_engine_state"
        private const val AUTO_ADVANCE_CHANNEL = "com.aurum.music/shorts_engine_advance"
    }

    val engine = AurumShortsEngine(context.applicationContext)
    private val callbackChannel = MethodChannel(messenger, AUTO_ADVANCE_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    init {
        engine.onStateChanged = { state ->
            eventSink?.success(
                mapOf(
                    "status" to state.status.name,
                    "positionMs" to state.positionMs,
                    "durationMs" to state.durationMs,
                    "isPlaying" to state.isPlaying,
                )
            )
        }
        engine.onAutoAdvance = {
            callbackChannel.invokeMethod("onAutoAdvance", null)
        }

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "playSong" -> {
                    val dedupeKey = call.argument<String>("dedupeKey") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val previewUrl = call.argument<String>("previewUrl") ?: ""
                    engine.playSong(dedupeKey, title, artist, previewUrl)
                    result.success(null)
                }
                "preloadNext" -> {
                    val dedupeKey = call.argument<String>("dedupeKey") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    val previewUrl = call.argument<String>("previewUrl") ?: ""
                    engine.preloadNext(dedupeKey, title, artist, previewUrl)
                    result.success(null)
                }
                "togglePlayPause" -> { engine.togglePlayPause(); result.success(null) }
                "pause" -> { engine.pause(); result.success(null) }
                "resume" -> { engine.resume(); result.success(null) }
                "release" -> { engine.release(); result.success(null) }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }
            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })
    }
}
