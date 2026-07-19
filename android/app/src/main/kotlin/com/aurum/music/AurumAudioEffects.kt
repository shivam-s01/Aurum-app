package com.aurum.music

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

@UnstableApi
class AurumAudioEffects(
    private val player: ExoPlayer,
    private val context: Context,
) {

    companion object {
        private const val TAG = "AurumAudioEffects"
        private const val BASS_BOOST_LOUDNESS_GAIN_MB = 1000
        private const val BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB = 600
        private const val BASS_BOOST_SUB_BASS_EXTRA_MB = 700
        private const val BASS_BOOST_BASS_EXTRA_MB = 500

        private const val PREMIUM_BASS_BOOST_STRENGTH_BASE = 320
        private const val PREMIUM_VIRTUALIZER_STRENGTH_BASE = 380
        private const val PREMIUM_LOUDNESS_GAIN_MB_BASE = 150
        private val PREMIUM_CURVE_MB_BASE = listOf(
            100, 50, -80, 0, 120, 180, 150, 100, 100, 120,
        )

        private const val SCALE_SPEAKER = 0.55f
        private const val SCALE_WIRED_HEADPHONES = 1.0f
        private const val SCALE_BLUETOOTH = 0.85f
        private const val SCALE_UNKNOWN = 0.75f

        private const val LOW_BATTERY_THRESHOLD_PERCENT = 20
        private const val SCALE_LOW_BATTERY = 0.5f

        private const val ADAPTIVE_MIN_SCALE = 0.7f
        private const val ADAPTIVE_MAX_SCALE = 1.0f

        private const val FADE_STEPS = 10
        private const val FADE_TOTAL_MS = 1400L
    }

    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var virtualizer: Virtualizer? = null
    private var nativeBassBoost: BassBoost? = null
    private var currentSessionId: Int = 0

    private var loudnessHealthy = true
    private var equalizerHealthy = true
    private var virtualizerHealthy = true
    private var nativeBassBoostHealthy = true

    private var virtualizerSupported = true
    private var nativeBassBoostSupported = true

    private var lastBassBoost = false
    private var lastVolNorm = false
    private var lastBandGains: List<Int>? = null
    private var lastPremiumSound = false

    private var fadeHandler = Handler(Looper.getMainLooper())
    private var fadeRunnable: Runnable? = null
    private var currentFadeFraction = 0f

    private val audioManager: AudioManager? by lazy {
        try { context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager } catch (_: Exception) { null }
    }

    private val sessionIdListener = object : Player.Listener {
        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            if (audioSessionId == currentSessionId) return
            attachEffects(audioSessionId)
        }
    }

    private val audioDeviceCallback: android.media.AudioDeviceCallback? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                    if (lastPremiumSound) applyPremiumSound(true, forceReapply = true)
                }
                override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                    if (lastPremiumSound) applyPremiumSound(true, forceReapply = true)
                }
            }
        } else null

    init {
        player.addListener(sessionIdListener)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager?.registerAudioDeviceCallback(audioDeviceCallback, Handler(Looper.getMainLooper()))
            }
        } catch (e: Exception) {
            Log.w(TAG, "registerAudioDeviceCallback failed: $e")
        }
        val sid = player.audioSessionId
        if (sid != androidx.media3.common.C.AUDIO_SESSION_ID_UNSET) {
            attachEffects(sid)
        }
    }

    private enum class OutputRoute { WIRED_HEADPHONES, BLUETOOTH, SPEAKER, UNKNOWN }

    private fun detectOutputRoute(): OutputRoute {
        val am = audioManager ?: return OutputRoute.UNKNOWN
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                val hasWired = devices.any {
                    it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                        it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                }
                val hasBluetooth = devices.any {
                    it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
                }
                when {
                    hasWired -> OutputRoute.WIRED_HEADPHONES
                    hasBluetooth -> OutputRoute.BLUETOOTH
                    else -> OutputRoute.SPEAKER
                }
            } else {
                @Suppress("DEPRECATION")
                when {
                    am.isWiredHeadsetOn -> OutputRoute.WIRED_HEADPHONES
                    am.isBluetoothA2dpOn || am.isBluetoothScoOn -> OutputRoute.BLUETOOTH
                    else -> OutputRoute.SPEAKER
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "detectOutputRoute failed: $e")
            OutputRoute.UNKNOWN
        }
    }

    private fun deviceScale(): Float = when (detectOutputRoute()) {
        OutputRoute.WIRED_HEADPHONES -> SCALE_WIRED_HEADPHONES
        OutputRoute.BLUETOOTH -> SCALE_BLUETOOTH
        OutputRoute.SPEAKER -> SCALE_SPEAKER
        OutputRoute.UNKNOWN -> SCALE_UNKNOWN
    }

    private fun isLowBattery(): Boolean {
        return try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && bm != null) {
                val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                val isCharging = bm.isCharging
                pct in 0..LOW_BATTERY_THRESHOLD_PERCENT && !isCharging
            } else {
                val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                val batteryStatus = context.registerReceiver(null, filter)
                val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                val plugged = batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
                if (level < 0 || scale <= 0) return false
                val pct = (level * 100) / scale
                pct in 0..LOW_BATTERY_THRESHOLD_PERCENT && plugged == 0
            }
        } catch (e: Exception) {
            Log.w(TAG, "isLowBattery check failed: $e")
            false
        }
    }

    private fun batteryScale(): Float = if (isLowBattery()) SCALE_LOW_BATTERY else 1.0f

    private fun contentAdaptiveScale(): Float {
        val am = audioManager ?: return ADAPTIVE_MAX_SCALE
        return try {
            val current = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat()
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()
            if (max <= 0f) return ADAPTIVE_MAX_SCALE
            val volumeFraction = (current / max).coerceIn(0f, 1f)
            ADAPTIVE_MAX_SCALE - (volumeFraction * (ADAPTIVE_MAX_SCALE - ADAPTIVE_MIN_SCALE))
        } catch (e: Exception) {
            Log.w(TAG, "contentAdaptiveScale failed: $e")
            ADAPTIVE_MAX_SCALE
        }
    }

    private fun combinedIntensityScale(): Float =
        (deviceScale() * batteryScale() * contentAdaptiveScale()).coerceIn(0.15f, 1.0f)

    private fun attachEffects(sessionId: Int) {
        releaseEffects()
        currentSessionId = sessionId
        loudnessHealthy = true
        equalizerHealthy = true
        virtualizerHealthy = true
        nativeBassBoostHealthy = true
        virtualizerSupported = true
        nativeBassBoostSupported = true

        try {
            equalizer = Equalizer(0, sessionId)
        } catch (e: Exception) {
            Log.w(TAG, "Equalizer attach failed for session $sessionId: $e — disabling for this session")
            equalizerHealthy = false
        }

        try {
            loudnessEnhancer = LoudnessEnhancer(sessionId)
        } catch (e: Exception) {
            Log.w(TAG, "LoudnessEnhancer attach failed for session $sessionId: $e — disabling for this session")
            loudnessHealthy = false
        }

        try {
            virtualizer = Virtualizer(0, sessionId).apply {
                try { forceVirtualizationMode(Virtualizer.VIRTUALIZATION_MODE_AUTO) } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Virtualizer attach failed for session $sessionId: $e — disabling for this session")
            virtualizerHealthy = false
            virtualizerSupported = false
        }

        try {
            nativeBassBoost = BassBoost(0, sessionId)
        } catch (e: Exception) {
            Log.w(TAG, "BassBoost attach failed for session $sessionId: $e — disabling for this session")
            nativeBassBoostHealthy = false
            nativeBassBoostSupported = false
        }

        virtualizer?.let { v ->
            try {
                v.strengthSupported
            } catch (e: Exception) {
                Log.w(TAG, "Virtualizer.strengthSupported probe failed: $e — marking unsupported")
                virtualizerSupported = false
                virtualizerHealthy = false
            }
        }
        nativeBassBoost?.let { bb ->
            try {
                bb.strengthSupported
            } catch (e: Exception) {
                Log.w(TAG, "BassBoost.strengthSupported probe failed: $e — marking unsupported")
                nativeBassBoostSupported = false
                nativeBassBoostHealthy = false
            }
        }

        applySettings(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
        )
        if (lastPremiumSound) {
            currentFadeFraction = 1f
            applyPremiumSoundAtFraction(1f)
        } else {
            currentFadeFraction = 0f
            applyPremiumSoundAtFraction(0f)
        }
    }

    private fun releaseEffects() {
        cancelFade()
        try { equalizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        try { virtualizer?.release() } catch (_: Exception) {}
        try { nativeBassBoost?.release() } catch (_: Exception) {}
        equalizer = null
        loudnessEnhancer = null
        virtualizer = null
        nativeBassBoost = null
    }

    fun applySettings(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?) {
        lastBassBoost = bassBoost
        lastVolNorm = volNorm
        lastBandGains = bandGainsMb

        applyLoudnessEnhancer(bassBoost)
        applyEqualizer(bassBoost = bassBoost, volNorm = volNorm, bandGainsMb = bandGainsMb, intensityFraction = currentFadeFraction)
    }

    fun applyPremiumSound(enabled: Boolean, forceReapply: Boolean = false) {
        if (enabled == lastPremiumSound && !forceReapply) return
        lastPremiumSound = enabled
        startFadeTo(if (enabled) 1f else 0f)
    }

    private fun cancelFade() {
        fadeRunnable?.let { fadeHandler.removeCallbacks(it) }
        fadeRunnable = null
    }

    private fun startFadeTo(target: Float) {
        cancelFade()
        val startFraction = currentFadeFraction
        val stepMs = FADE_TOTAL_MS / FADE_STEPS
        var step = 0

        val runnable = object : Runnable {
            override fun run() {
                step++
                val t = (step.toFloat() / FADE_STEPS).coerceIn(0f, 1f)
                currentFadeFraction = startFraction + (target - startFraction) * t
                applyPremiumSoundAtFraction(currentFadeFraction)
                if (t < 1f) {
                    fadeHandler.postDelayed(this, stepMs)
                }
            }
        }
        fadeRunnable = runnable
        fadeHandler.post(runnable)
    }

    private fun applyPremiumSoundAtFraction(fraction: Float) {
        val ceiling = if (fraction > 0f) combinedIntensityScale() else 0f
        val effectiveFraction = (fraction * ceiling).coerceIn(0f, 1f)
        val active = effectiveFraction > 0.001f

        if (virtualizerHealthy && virtualizerSupported) {
            virtualizer?.let { v ->
                try {
                    v.enabled = active
                    if (active) {
                        val strength = (PREMIUM_VIRTUALIZER_STRENGTH_BASE * effectiveFraction)
                            .toInt().coerceIn(0, 1000).toShort()
                        try {
                            v.setStrength(strength)
                        } catch (e: Exception) {
                            Log.w(TAG, "Virtualizer setStrength rejected ($e) — disabling for this session")
                            virtualizerHealthy = false
                            try { v.enabled = false } catch (_: Exception) {}
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Virtualizer enable failed: $e — disabling for this session")
                    virtualizerHealthy = false
                }
            }
        }

        if (nativeBassBoostHealthy && nativeBassBoostSupported) {
            nativeBassBoost?.let { bb ->
                try {
                    bb.enabled = active
                    if (active) {
                        val strength = (PREMIUM_BASS_BOOST_STRENGTH_BASE * effectiveFraction)
                            .toInt().coerceIn(0, 1000).toShort()
                        try {
                            bb.setStrength(strength)
                        } catch (e: Exception) {
                            Log.w(TAG, "BassBoost setStrength rejected ($e) — disabling for this session")
                            nativeBassBoostHealthy = false
                            try { bb.enabled = false } catch (_: Exception) {}
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "BassBoost enable failed: $e — disabling for this session")
                    nativeBassBoostHealthy = false
                }
            }
        }

        if (loudnessHealthy) {
            loudnessEnhancer?.let { enhancer ->
                try {
                    val bassBoostOn = lastBassBoost
                    val premiumGain = (PREMIUM_LOUDNESS_GAIN_MB_BASE * effectiveFraction).toInt()
                    val targetGain = when {
                        active && bassBoostOn -> maxOf(premiumGain, BASS_BOOST_LOUDNESS_GAIN_MB)
                        active -> premiumGain
                        bassBoostOn -> BASS_BOOST_LOUDNESS_GAIN_MB
                        else -> null
                    }
                    if (targetGain != null && targetGain > 0) {
                        enhancer.enabled = true
                        try {
                            enhancer.setTargetGain(targetGain)
                        } catch (e: Exception) {
                            Log.w(TAG, "LoudnessEnhancer premium gain rejected ($e)")
                        }
                    } else {
                        enhancer.enabled = false
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "LoudnessEnhancer premium apply failed: $e — disabling for this session")
                    loudnessHealthy = false
                }
            }
        }

        applyEqualizer(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
            intensityFraction = effectiveFraction,
        )
    }

    private fun applyLoudnessEnhancer(bassBoost: Boolean) {
        if (!loudnessHealthy) return
        val enhancer = loudnessEnhancer ?: return

        try {
            if (lastPremiumSound) return
            enhancer.enabled = bassBoost
            if (!bassBoost) return

            try {
                enhancer.setTargetGain(BASS_BOOST_LOUDNESS_GAIN_MB)
            } catch (e: Exception) {
                Log.w(TAG, "LoudnessEnhancer ${BASS_BOOST_LOUDNESS_GAIN_MB}mB rejected ($e) — retrying at ${BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB}mB")
                try {
                    enhancer.setTargetGain(BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB)
                } catch (e2: Exception) {
                    Log.w(TAG, "LoudnessEnhancer fallback gain also rejected ($e2) — disabling for this session")
                    loudnessHealthy = false
                    try { enhancer.enabled = false } catch (_: Exception) {}
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "LoudnessEnhancer apply failed: $e — disabling for this session")
            loudnessHealthy = false
        }
    }

    private fun applyEqualizer(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?, intensityFraction: Float = 1f) {
        if (!equalizerHealthy) return
        val eq = equalizer ?: return

        try {
            val bandCount = eq.numberOfBands.toInt()
            if (bandCount <= 0) return

            val savedBandsPreview = (0 until bandCount).map { i ->
                bandGainsMb?.getOrNull(i) ?: 0
            }
            val hasCustomCurve = savedBandsPreview.any { it != 0 }
            val premiumActive = lastPremiumSound && intensityFraction > 0.001f

            if (!hasCustomCurve && !bassBoost && !premiumActive) {
                eq.enabled = false
                return
            }

            eq.enabled = true

            val range = eq.bandLevelRange
            val minMb = range[0].toInt()
            val maxMb = range[1].toInt()

            val savedBands = savedBandsPreview

            fun premiumGainFor(bandIndex: Int): Int {
                if (!premiumActive) return 0
                val base = if (bandCount <= 1) {
                    PREMIUM_CURVE_MB_BASE[0]
                } else {
                    val fraction = bandIndex.toFloat() / (bandCount - 1).toFloat()
                    val srcIndex = (fraction * (PREMIUM_CURVE_MB_BASE.size - 1)).toInt()
                        .coerceIn(0, PREMIUM_CURVE_MB_BASE.size - 1)
                    PREMIUM_CURVE_MB_BASE[srcIndex]
                }
                return (base * intensityFraction).toInt()
            }

            var rejectedBands = 0
            for (i in 0 until bandCount) {
                var gain = if (volNorm && !hasCustomCurve) 0 else savedBands[i]

                if (bassBoost) {
                    if (i == 0) gain += BASS_BOOST_SUB_BASS_EXTRA_MB
                    if (i == 1) gain += BASS_BOOST_BASS_EXTRA_MB
                }

                gain += premiumGainFor(i)
                gain = gain.coerceIn(minMb, maxMb)

                try {
                    eq.setBandLevel(i.toShort(), gain.toShort())
                } catch (e: Exception) {
                    rejectedBands++
                    Log.w(TAG, "Band $i setBandLevel($gain) rejected ($e) — skipping band")
                }
            }

            if (rejectedBands == bandCount) {
                Log.w(TAG, "All EQ bands rejected — disabling Equalizer for this session")
                equalizerHealthy = false
                try { eq.enabled = false } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            Log.w(TAG, "Equalizer apply failed: $e — disabling for this session")
            equalizerHealthy = false
        }
    }

    fun describeBands(): Map<String, Any>? {
        val eq = equalizer ?: return null
        return try {
            val bandCount = eq.numberOfBands.toInt()
            val range = eq.bandLevelRange
            mapOf(
                "bandCount" to bandCount,
                "minMb" to range[0].toInt(),
                "maxMb" to range[1].toInt(),
                "centerFreqsHz" to (0 until bandCount).map { eq.getCenterFreq(it.toShort()) / 1000 },
            )
        } catch (e: Exception) {
            Log.w(TAG, "describeBands failed: $e")
            null
        }
    }

    fun describeCapabilities(): Map<String, Any> = mapOf(
        "virtualizerSupported" to (virtualizerSupported && virtualizerHealthy),
        "bassBoostSupported" to (nativeBassBoostSupported && nativeBassBoostHealthy),
        "outputRoute" to detectOutputRoute().name,
    )

    fun dispose() {
        cancelFade()
        player.removeListener(sessionIdListener)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
            }
        } catch (_: Exception) {}
        releaseEffects()
    }
}
