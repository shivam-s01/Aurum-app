package com.aurum.music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Dedicated, self-contained EventChannel exposing the device's live
 * battery percentage to Dart — powers Settings → Player & Audio →
 * "Battery Saver Mode" (see AudioPrefs.batterySaverEnabledNotifier /
 * BatterySaverController in Dart).
 *
 * Uses a sticky broadcast registration for Intent.ACTION_BATTERY_CHANGED
 * rather than any battery-reading plugin — this is the same primitive
 * every "battery_plus"-style plugin wraps internally, and keeping it
 * native avoids adding a new pub.dev dependency for a single percentage
 * value. Registering the receiver against ACTION_BATTERY_CHANGED (a
 * sticky broadcast) also means the very first onReceive() fires
 * immediately with the current battery state — no extra "get current
 * value" method call needed, the stream's first event IS the current
 * value.
 *
 * Own channel + own file, same reasoning as AurumRelatedChannelHandler:
 * a battery-level stream has nothing to do with playback commands or
 * media-store queries, so it must never compete for a slot on a channel
 * that also carries time-sensitive playback commands.
 */
class AurumBatteryChannelHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "com.aurum.music/battery"
    }

    private val eventChannel = EventChannel(messenger, CHANNEL)
    private var receiver: BroadcastReceiver? = null

    init {
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                val br = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context, intent: Intent) {
                        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                        if (level < 0 || scale <= 0) return
                        val percent = (level * 100) / scale
                        try {
                            events?.success(percent)
                        } catch (_: Exception) {
                            // Sink can throw if the Dart side has already
                            // detached between broadcasts — safe to ignore,
                            // onCancel below will unregister shortly after.
                        }
                    }
                }
                context.registerReceiver(br, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                receiver = br
            }

            override fun onCancel(arguments: Any?) {
                receiver?.let {
                    try { context.unregisterReceiver(it) } catch (_: Exception) {}
                }
                receiver = null
            }
        })
    }

    /** Call from MainActivity.onDestroy() so a lingering registration
     *  can never outlive the Activity if Dart never explicitly cancels
     *  its stream subscription (e.g. process death mid-stream). */
    fun release() {
        receiver?.let {
            try { context.unregisterReceiver(it) } catch (_: Exception) {}
        }
        receiver = null
    }
}
