package com.aurum.music

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Dart<->native bridge for the Shorts feed. Dart calls playSong /
 * preloadNext / togglePlayPause / pause / resume / release; native
 * pushes status+position+isPlaying back over the event channel so
 * Dart's UI (progress bar, play/pause icon, auto-advance) stays in
 * sync without owning any player object itself.
 */
class AurumShortsChannelHandler(context: Context, messenger: BinaryMessenger) {

    companion object {
        private const val METHOD_CHANNEL = "com.aurum.music/shorts_engine"
        private const val EVENT_CHANNEL = "com.aurum.music/shorts_engine_state"
        private const val AUTO_ADVANCE_CHANNEL = "com.aurum.music/shorts_engine_advance"
    }

    val engine = AurumShortsEngine(context.applicationContext, messenger)
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
                    engine.playSong(dedupeKey, title, artist)
                    result.success(null)
                }
                "preloadNext" -> {
                    val dedupeKey = call.argument<String>("dedupeKey") ?: ""
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    engine.preloadNext(dedupeKey, title, artist)
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
