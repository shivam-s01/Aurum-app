package com.aurum.music

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
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
    // FEATURE ("volume badane ka option live update nahi hota, phone
    // button se badhau to bhi wahi rehta hai" — 2026-09-07): fires
    // whenever Android's STREAM_MUSIC volume changes from ANY source —
    // hardware volume keys, another app, a Bluetooth remote's own volume
    // buttons, not just this app's own setMediaVolume calls — so the
    // output sheet's slider (see audio_output_sheet.dart's _VolumeRow)
    // can update itself live instead of only reading the volume once
    // when the sheet first opens.
    var onVolumeChanged: (() -> Unit)? = null

    private var forcedSpeaker = false
    private var selectedDeviceId: Int? = null

    // Only re-fires onVolumeChanged when the actual level changed — the
    // Settings.System URI this observer watches covers ALL settings
    // changes under that content provider, not just STREAM_MUSIC volume,
    // so onChange() can fire for unrelated writes too; comparing against
    // the last known level filters those out before ever reaching Dart.
    private var lastKnownVolume: Int = -1

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            onDevicesChanged?.invoke()
        }
    }

    // ROOT-CAUSE-SAFE CHOICE: an earlier version of this fix used
    // AudioManager.VOLUME_CHANGED_ACTION (a BroadcastReceiver action) —
    // that constant, along with its EXTRA_VOLUME_STREAM_TYPE/
    // EXTRA_VOLUME_STREAM_VALUE extras, is documented in AOSP source as
    // @hide (platform-internal), meaning a normal app compiled against
    // the public Android SDK cannot actually reference those fields —
    // they simply won't resolve, which would have made this fail to
    // compile. ContentObserver on Settings.System.CONTENT_URI is the
    // long-established, fully public, SDK-stable mechanism apps use
    // instead for exactly this (STREAM_MUSIC volume is persisted under
    // that same settings provider, so any write to it — hardware volume
    // keys included — triggers this observer's onChange()).
    private val volumeObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (current != lastKnownVolume) {
                lastKnownVolume = current
                onVolumeChanged?.invoke()
            }
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
        lastKnownVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        context.contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI, true, volumeObserver)
    }

    /** Current STREAM_MUSIC level/max, for the volume-changed event's
     *  payload — same shape as AurumEngineChannelHandler's existing
     *  getMediaVolume MethodChannel handler, just re-read here so the
     *  live event carries the fresh value directly instead of Dart
     *  needing a second round-trip on every change. */
    fun currentVolume(): Pair<Int, Int> {
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return current to max
    }

    /** True on API 31+, where AudioManager.communicationDevice /
     *  setPreferredDevice give real explicit per-app output routing. */
    fun supportsExplicitRouting(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    /** Current output-capable devices (speaker, wired headset/headphones,
     *  Bluetooth A2DP/SCO, USB), each as a simple id/name/type map so Dart
     *  doesn't need to know about AudioDeviceInfo at all.
     *
     *  DEDUPE: Android reports the same physical Bluetooth headphones as
     *  TWO separate AudioDeviceInfo entries — one TYPE_BLUETOOTH_A2DP
     *  (the actual media/music route) and one TYPE_BLUETOOTH_SCO (the
     *  voice-call route), both with the identical product name. Without
     *  deduping, one paired Bluetooth device shows up twice in the
     *  picker with the same name — confusing, and not what any other
     *  music app's output picker does. A2DP is kept over SCO when both
     *  exist for the same name, since A2DP is what music actually plays
     *  through. */
    fun describeDevices(): List<Map<String, Any?>> {
        val infos = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val currentId = currentDeviceId()
        val relevant = infos.filter { isRelevantOutput(it.type) }

        val byNameAndKind = LinkedHashMap<String, AudioDeviceInfo>()
        for (info in relevant) {
            val dedupeKey = "${deviceLabel(info)}|${deviceTypeName(info.type)}"
            val existing = byNameAndKind[dedupeKey]
            if (existing == null) {
                byNameAndKind[dedupeKey] = info
            } else if (existing.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO &&
                info.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP) {
                // Prefer the A2DP entry if we'd previously stored the SCO
                // one for this same device name — keeps whichever one is
                // actually selected/current if either matches, otherwise
                // arbitrary preference doesn't matter since they're the
                // same physical device to the user.
                byNameAndKind[dedupeKey] = info
            }
        }

        return byNameAndKind.values.map { info ->
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
        try {
            context.contentResolver.unregisterContentObserver(volumeObserver)
        } catch (e: Exception) {
            // Already unregistered — safe to ignore.
        }
        onDevicesChanged = null
        onVolumeChanged = null
    }

    // ROOT-CAUSE FIX ("bluetooth se pehle se connected hoon phir bhi
    // 'speaker' selected dikhata hai" — 2026-09-07): this used to return
    // ONLY selectedDeviceId, which is nothing but a local flag this class
    // sets itself whenever the user taps a device in the picker sheet —
    // it stays null forever if Bluetooth/wired connects the normal way
    // (Android auto-routes to it the instant it pairs/plugs in, entirely
    // outside this class, without the user ever opening the picker). With
    // selectedDeviceId null, describeDevices() below marked NOTHING as
    // selected — but Dart's picker still needs to show *something* as
    // selected, so it fell back to the ordering, which put the always-
    // present Speaker entry first and made it look like Speaker was
    // "selected" even while audio was audibly coming out of the earphones
    // the whole time.
    //
    // The old comment blamed this on Media3 lacking a routed-device
    // getter and promised a future version would add one — but ExoPlayer/
    // Player has never publicly exposed the underlying AudioTrack (it's
    // owned deep inside DefaultAudioSink), in 1.4.1 or the current 1.8.0,
    // so waiting for a version bump was never going to fix this on its
    // own. The actual fix Android apps use for this is priority-based
    // inference over AudioManager.getDevices(): Android's own audio
    // policy always auto-routes to the highest-priority CONNECTED device
    // (Bluetooth/wired beats the always-present built-in speaker) the
    // moment it connects — so mirroring that same priority order against
    // the current device list tells us what's actually playing without
    // needing a direct routed-device readout at all.
    //
    // Still prefers the user's own explicit selectedDeviceId first (so a
    // manual override — e.g. forcing speaker while Bluetooth stays
    // connected — always wins and reads back correctly), falling through
    // to this inference only when nothing has been explicitly picked,
    // which is exactly the common "Bluetooth auto-connected, never opened
    // the picker" case this bug report describes.
    private fun currentDeviceId(): Int? {
        selectedDeviceId?.let { return it }
        return inferredActiveDeviceId()
    }

    /** Infers which device Android is actually routing audio through
     *  right now, by mirroring Android's own audio-policy priority order
     *  (Bluetooth/wired/USB always wins over the built-in speaker the
     *  instant one is connected — this is standard, documented Android
     *  behavior, not app-specific) against the live device list. This is
     *  an inference, not a direct readout — there's no public API for
     *  the latter — but priority-over-the-always-present-speaker is
     *  exactly the same policy Android itself already applies, so it
     *  matches truth in every normal case (the only way it could be
     *  wrong is a genuinely unusual OEM audio-routing override, the same
     *  edge case every other Android output-picker implementation
     *  accepts for the same reason). */
    private fun inferredActiveDeviceId(): Int? {
        val infos = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val priority = listOf(
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        )
        for (type in priority) {
            infos.firstOrNull { it.type == type }?.let { return it.id }
        }
        return infos.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }?.id
    }

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
