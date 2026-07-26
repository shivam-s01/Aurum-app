package com.aurum.music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/**
 * In-app audio output device picker (speaker / wired / Bluetooth / USB).
 *
 * Two responsibilities:
 *  1. Enumerate current output-capable devices so the picker sheet in Dart
 *     can render a list ([describeDevices]).
 *  2. Let the user force routing to a specific device on API 31+, where
 *     AudioManager/ExoPlayer support explicit per-app output routing
 *     ([selectDevice], [setForceSpeaker]). Below API 31 there's no public
 *     explicit-routing API — Android's own audio policy owns that decision
 *     (e.g. Bluetooth takes priority automatically once connected), so
 *     [supportsExplicitRouting] reports false and Dart shows an
 *     "automatic on this Android version" message instead of a picker.
 *
 * [onDevicesChanged] fires on Bluetooth/wired connect-disconnect so the
 * already-open picker sheet updates itself live instead of showing a
 * stale list until reopened.
 */
@UnstableApi
class AurumAudioOutputManager(
    private val context: Context,
    private val audioManager: AudioManager,
    private val player: ExoPlayer,
) {
    var onDevicesChanged: (() -> Unit)? = null

    private var forcedSpeaker = false
    private var selectedDeviceId: Int? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            onDevicesChanged?.invoke()
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_HEADSET_PLUG)
            addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(android.bluetooth.BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    /** True on API 31+, where AudioManager.communicationDevice /
     *  setPreferredDevice give real explicit per-app output routing. */
    fun supportsExplicitRouting(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    /** Current output-capable devices (speaker, wired headset/headphones,
     *  Bluetooth A2DP/SCO, USB), each as a simple id/name/type map so Dart
     *  doesn't need to know about AudioDeviceInfo at all. */
    fun describeDevices(): List<Map<String, Any?>> {
        val infos = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val currentId = currentDeviceId()
        return infos
            .filter { isRelevantOutput(it.type) }
            .map { info ->
                mapOf(
                    "id" to info.id,
                    "name" to deviceLabel(info),
                    "type" to deviceTypeName(info.type),
                    "selected" to (info.id == currentId),
                )
            }
    }

    /** Explicitly route playback to [deviceId] (from [describeDevices]).
     *  Returns false if routing failed or isn't supported. */
    fun selectDevice(deviceId: Int): Boolean {
        if (!supportsExplicitRouting()) return false
        val target = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.id == deviceId } ?: return false

        forcedSpeaker = false
        return try {
            player.setPreferredAudioDevice(target)
            selectedDeviceId = target.id
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Forces routing back to the built-in speaker even if Bluetooth/wired
     *  is connected — the "use phone speaker anyway" override. */
    fun setForceSpeaker(force: Boolean) {
        forcedSpeaker = force
        if (!supportsExplicitRouting()) return
        if (!force) {
            player.setPreferredAudioDevice(null)
            selectedDeviceId = null
            return
        }
        val speaker = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
        player.setPreferredAudioDevice(speaker)
        selectedDeviceId = speaker?.id
    }

    fun release() {
        try {
            context.unregisterReceiver(receiver)
        } catch (e: Exception) {
            // Already unregistered — safe to ignore.
        }
        onDevicesChanged = null
    }

    // Media3 1.4.1's Player interface has no getter to read back the
    // currently-active output device (that landed in a later media3
    // version), so we track our own last-explicitly-selected device
    // instead of querying the player for it.
    private fun currentDeviceId(): Int? = selectedDeviceId

    private fun isRelevantOutput(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_HEARING_AID -> true
        else -> false
    }

    private fun deviceTypeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
        else -> "unknown"
    }

    private fun deviceLabel(info: AudioDeviceInfo): String {
        val productName = info.productName?.toString()
        if (!productName.isNullOrBlank() && info.type != AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
            return productName
        }
        return when (info.type) {
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Phone speaker"
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired headphones"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "Bluetooth device"
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USB audio"
            AudioDeviceInfo.TYPE_HEARING_AID -> "Hearing aid"
            else -> "Unknown device"
        }
    }
}
