package com.aurum.music

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.BassBoost
import android.media.audiofx.DynamicsProcessing
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
        private const val BASS_BOOST_LOUDNESS_GAIN_MB = 400
        private const val BASS_BOOST_LOUDNESS_GAIN_FALLBACK_MB = 250
        private const val BASS_BOOST_SUB_BASS_EXTRA_MB = 400
        private const val BASS_BOOST_BASS_EXTRA_MB = 300

        private const val K_P1 = 160

        private const val K_P2 = 220

        private const val K_P3 = 60

        private val K_P4 = listOf(
            30, 10, -50, 20, 60, 70, 40, 10, -20, -30,
        )

        private const val K_S1 = 0.55f
        private const val K_S2 = 1.0f
        private const val K_S3 = 0.85f
        private const val K_S4 = 0.75f

        private const val K_B1 = 20
        private const val K_B2 = 0.5f

        private const val K_A1 = 0.7f
        private const val K_A2 = 1.0f

        private const val K_F1 = 10
        private const val K_F2 = 1400L

        private const val K_L1 = -1.5f
        private const val K_L2 = 6.0f // gentler ratio — avoids audible pumping/harshness when the limiter engages often
        private const val K_L3 = 5f
        private const val K_L4 = 100f
        private const val K_L5 = 0f

        // Low-bitrate compensation: below this kbps, lossy encoders have
        // already thrown away most high-frequency content and some stereo
        // detail, which is exactly what reads as "thin"/"dull"/"boxy" on a
        // 128kbps stream. Nothing here restores that lost data — it's a
        // perceptual EQ tilt only, applied ON TOP of Premium Sound's own
        // curve when active, or as a small standalone tilt when Premium
        // Sound is off. Two tiers: below K_BR1 gets the full tilt, between
        // K_BR1 and K_BR2 gets a proportionally smaller one, at/above
        // K_BR2 gets none (192kbps+ has little to compensate for).
        private const val K_BR1 = 96
        private const val K_BR2 = 192
        private val K_BR3 = listOf(
            0, 0, -20, 10, 40, 50, 30, 0, -20, -20,
        )

        // Combined per-band safety ceiling, independent of whatever the
        // device's own Equalizer.bandLevelRange happens to allow (some
        // devices report ranges as wide as ±1500mB, which is far more
        // headroom than is ever musically appropriate to actually use).
        // Bass Boost's manual EQ bump + Premium Sound's curve + bitrate
        // compensation are all additive on the same bands — without an
        // explicit cap here, three simultaneously-active boost sources
        // can stack into a harsh, fatiguing gain on the same band even
        // though each one individually looks conservative. This is what
        // was producing the reported harshness/irritation: not any single
        // constant being too high, but the SUM of several "reasonable"
        // constants landing on the same presence band at once.
        private const val K_CAP_POS = 600 // +6.0dB combined ceiling, boost side
        private const val K_CAP_NEG = -600 // -6.0dB combined ceiling, cut side
    }

    private var equalizer: Equalizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var virtualizer: Virtualizer? = null
    private var nativeBassBoost: BassBoost? = null
    private var limiter: DynamicsProcessing? = null
    private var currentSessionId: Int = 0

    private var loudnessHealthy = true
    private var equalizerHealthy = true
    private var virtualizerHealthy = true
    private var nativeBassBoostHealthy = true

    private var virtualizerSupported = true
    private var nativeBassBoostSupported = true
    private var limiterHealthy = true
    private var limiterSupported = true

    private var lastBassBoost = false
    private var lastVolNorm = false
    private var lastBandGains: List<Int>? = null
    private var lastPremiumSound = false
    private var lastKnownSourceKbps: Int? = null

    private var fadeHandler = Handler(Looper.getMainLooper())
    private var fadeRunnable: Runnable? = null
    private var currentFadeFraction = 0f

    private val audioManager: AudioManager? by lazy {
        try { context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager } catch (_: Exception) { null }
    }

    private val sessionIdListener = object : Player.Listener {
        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            if (audioSessionId == currentSessionId) return
            _at1(audioSessionId)
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
            _at1(sid)
        }
    }

    private enum class _Rt { WIRED_HEADPHONES, BLUETOOTH, SPEAKER, UNKNOWN }

    private fun _ro1(): _Rt {
        val am = audioManager ?: return _Rt.UNKNOWN
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
                    hasWired -> _Rt.WIRED_HEADPHONES
                    hasBluetooth -> _Rt.BLUETOOTH
                    else -> _Rt.SPEAKER
                }
            } else {
                @Suppress("DEPRECATION")
                when {
                    am.isWiredHeadsetOn -> _Rt.WIRED_HEADPHONES
                    am.isBluetoothA2dpOn || am.isBluetoothScoOn -> _Rt.BLUETOOTH
                    else -> _Rt.SPEAKER
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "_ro1 failed: $e")
            _Rt.UNKNOWN
        }
    }

    private fun _ro2(): Float = when (_ro1()) {
        _Rt.WIRED_HEADPHONES -> K_S2
        _Rt.BLUETOOTH -> K_S3
        _Rt.SPEAKER -> K_S1
        _Rt.UNKNOWN -> K_S4
    }

    private fun _bt1(): Boolean {
        return try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && bm != null) {
                val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                val isCharging = bm.isCharging
                pct in 0..K_B1 && !isCharging
            } else {
                val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                val batteryStatus = context.registerReceiver(null, filter)
                val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
                val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
                val plugged = batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
                if (level < 0 || scale <= 0) return false
                val pct = (level * 100) / scale
                pct in 0..K_B1 && plugged == 0
            }
        } catch (e: Exception) {
            Log.w(TAG, "_bt1 check failed: $e")
            false
        }
    }

    private fun _bt2(): Float = if (_bt1()) K_B2 else 1.0f

    private fun _cx1(): Float {
        val am = audioManager ?: return K_A2
        return try {
            val current = am.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat()
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).toFloat()
            if (max <= 0f) return K_A2
            val volumeFraction = (current / max).coerceIn(0f, 1f)
            K_A2 - (volumeFraction * (K_A2 - K_A1))
        } catch (e: Exception) {
            Log.w(TAG, "_cx1 failed: $e")
            K_A2
        }
    }

    private fun _mx1(): Float =
        (_ro2() * _bt2() * _cx1()).coerceIn(0.15f, 1.0f)

    private fun _at1(sessionId: Int) {
        _rl1()
        currentSessionId = sessionId
        loudnessHealthy = true
        equalizerHealthy = true
        virtualizerHealthy = true
        nativeBassBoostHealthy = true
        virtualizerSupported = true
        nativeBassBoostSupported = true
        limiterHealthy = true
        limiterSupported = true
        lastAppliedVirtualizerEnabled = null
        lastAppliedVirtualizerStrength = null
        lastAppliedBassBoostEnabled = null
        lastAppliedBassBoostStrength = null
        lastAppliedLoudnessGain = null
        lastAppliedLimiterEnabled = null
        lastAppliedEqGains = emptyList()

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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                limiter = _lm1(sessionId)
            } catch (e: Exception) {
                Log.w(TAG, "DynamicsProcessing limiter attach failed for session $sessionId: $e — Premium Sound gains will rely on scale-down only")
                limiterHealthy = false
                limiterSupported = false
            }
        } else {
            limiterHealthy = false
            limiterSupported = false
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
            _ap3(1f)
        } else {
            currentFadeFraction = 0f
            _ap3(0f)
        }
    }

    private fun _rl1() {
        _fd1()
        try { equalizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        try { virtualizer?.release() } catch (_: Exception) {}
        try { nativeBassBoost?.release() } catch (_: Exception) {}
        try { limiter?.release() } catch (_: Exception) {}
        equalizer = null
        loudnessEnhancer = null
        virtualizer = null
        nativeBassBoost = null
        limiter = null
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.P)
    private fun _lm1(sessionId: Int): DynamicsProcessing {
        val channelCount = 2
        val config = DynamicsProcessing.Config.Builder(
            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
            channelCount,
            false, 0, // no pre-EQ stage — Equalizer above already handles tone
            false, 0, // no multi-band compressor — a single limiter stage is enough here
            false, 0, // no post-EQ stage
            true,     // limiter stage in use
        ).build()

        val dp = DynamicsProcessing(0, sessionId, config)

        val limiterSettings = DynamicsProcessing.Limiter(
            /* inUse = */ true,
            /* enabled = */ true,
            /* linkGroup = */ 0,
            /* attackTime = */ K_L3,
            /* releaseTime = */ K_L4,
            /* ratio = */ K_L2,
            /* threshold = */ K_L1,
            /* postGain = */ K_L5,
        )
        dp.setLimiterAllChannelsTo(limiterSettings)

        dp.enabled = false
        return dp
    }

    private fun _lm2(enabled: Boolean) {
        if (!limiterHealthy || !limiterSupported) return
        val dp = limiter ?: return
        try {
            dp.enabled = enabled
        } catch (e: Exception) {
            Log.w(TAG, "DynamicsProcessing enable toggle failed: $e — disabling limiter for this session")
            limiterHealthy = false
        }
    }

    fun applySettings(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?) {
        lastBassBoost = bassBoost
        lastVolNorm = volNorm
        lastBandGains = bandGainsMb

        _ap1(bassBoost)
        _ap2(bassBoost = bassBoost, volNorm = volNorm, bandGainsMb = bandGainsMb, intensityFraction = currentFadeFraction)
    }

    fun applyPremiumSound(enabled: Boolean, forceReapply: Boolean = false) {
        if (enabled == lastPremiumSound && !forceReapply) return
        lastPremiumSound = enabled
        _fd2(if (enabled) 1f else 0f)
    }

    fun setPremiumSoundCompare(enabled: Boolean) {
        _fd1()
        currentFadeFraction = if (enabled) 1f else 0f
        _ap3(currentFadeFraction)
    }

    fun reportSourceBitrate(kbps: Int?) {
        lastKnownSourceKbps = kbps
        _ap2(bassBoost = lastBassBoost, volNorm = lastVolNorm, bandGainsMb = lastBandGains, intensityFraction = currentFadeFraction)
    }

    fun exitPremiumSoundCompare() {
        _fd2(if (lastPremiumSound) 1f else 0f)
    }

    private fun _fd1() {
        fadeRunnable?.let { fadeHandler.removeCallbacks(it) }
        fadeRunnable = null
    }

    private fun _fd2(target: Float) {
        _fd1()
        val startFraction = currentFadeFraction
        val stepMs = K_F2 / K_F1
        var step = 0

        val runnable = object : Runnable {
            override fun run() {
                step++
                val t = (step.toFloat() / K_F1).coerceIn(0f, 1f)
                currentFadeFraction = startFraction + (target - startFraction) * t
                _ap3(currentFadeFraction)
                if (t < 1f) {
                    fadeHandler.postDelayed(this, stepMs)
                }
            }
        }
        fadeRunnable = runnable
        fadeHandler.post(runnable)
    }

    private var lastAppliedVirtualizerEnabled: Boolean? = null
    private var lastAppliedVirtualizerStrength: Short? = null
    private var lastAppliedBassBoostEnabled: Boolean? = null
    private var lastAppliedBassBoostStrength: Short? = null
    private var lastAppliedLoudnessGain: Int? = null
    private var lastAppliedLimiterEnabled: Boolean? = null
    private var lastAppliedEqGains: List<Int> = emptyList()

    private fun _ap3(fraction: Float) {
        val ceiling = if (fraction > 0f) _mx1() else 0f
        val effectiveFraction = (fraction * ceiling).coerceIn(0f, 1f)
        val active = effectiveFraction > 0.001f

        if (lastAppliedLimiterEnabled != active) {
            _lm2(active)
            lastAppliedLimiterEnabled = active
        }

        if (virtualizerHealthy && virtualizerSupported) {
            virtualizer?.let { v ->
                try {
                    if (lastAppliedVirtualizerEnabled != active) {
                        v.enabled = active
                        lastAppliedVirtualizerEnabled = active
                    }
                    if (active) {
                        val strength = (K_P2 * effectiveFraction)
                            .toInt().coerceIn(0, 1000).toShort()
                        if (lastAppliedVirtualizerStrength != strength) {
                            try {
                                v.setStrength(strength)
                                lastAppliedVirtualizerStrength = strength
                            } catch (e: Exception) {
                                Log.w(TAG, "Virtualizer setStrength rejected ($e) — disabling for this session")
                                virtualizerHealthy = false
                                try { v.enabled = false } catch (_: Exception) {}
                            }
                        }
                    } else {
                        lastAppliedVirtualizerStrength = null
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
                    if (lastAppliedBassBoostEnabled != active) {
                        bb.enabled = active
                        lastAppliedBassBoostEnabled = active
                    }
                    if (active) {
                        val strength = (K_P1 * effectiveFraction)
                            .toInt().coerceIn(0, 1000).toShort()
                        if (lastAppliedBassBoostStrength != strength) {
                            try {
                                bb.setStrength(strength)
                                lastAppliedBassBoostStrength = strength
                            } catch (e: Exception) {
                                Log.w(TAG, "BassBoost setStrength rejected ($e) — disabling for this session")
                                nativeBassBoostHealthy = false
                                try { bb.enabled = false } catch (_: Exception) {}
                            }
                        }
                    } else {
                        lastAppliedBassBoostStrength = null
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
                    val premiumGain = (K_P3 * effectiveFraction).toInt()
                    val targetGain = when {
                        active && bassBoostOn -> maxOf(premiumGain, BASS_BOOST_LOUDNESS_GAIN_MB)
                        active -> premiumGain
                        bassBoostOn -> BASS_BOOST_LOUDNESS_GAIN_MB
                        else -> null
                    }
                    if (targetGain != null && targetGain > 0) {
                        if (lastAppliedLoudnessGain == null) {
                            enhancer.enabled = true
                        }
                        if (lastAppliedLoudnessGain != targetGain) {
                            try {
                                enhancer.setTargetGain(targetGain)
                                lastAppliedLoudnessGain = targetGain
                            } catch (e: Exception) {
                                Log.w(TAG, "LoudnessEnhancer premium gain rejected ($e)")
                            }
                        }
                    } else {
                        if (lastAppliedLoudnessGain != null) {
                            enhancer.enabled = false
                            lastAppliedLoudnessGain = null
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "LoudnessEnhancer premium apply failed: $e — disabling for this session")
                    loudnessHealthy = false
                }
            }
        }

        _ap2(
            bassBoost = lastBassBoost,
            volNorm = lastVolNorm,
            bandGainsMb = lastBandGains,
            intensityFraction = effectiveFraction,
        )
    }

    private fun _ap1(bassBoost: Boolean) {
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

    private fun _ap2(bassBoost: Boolean, volNorm: Boolean, bandGainsMb: List<Int>?, intensityFraction: Float = 1f) {
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

            val kbps = lastKnownSourceKbps
            val bitrateCompensationScale = when {
                kbps == null -> 0f
                kbps >= K_BR2 -> 0f
                kbps <= K_BR1 -> 1f
                else -> {
                    // Linear taper between K_BR1 (full) and K_BR2 (none) —
                    // avoids a hard on/off snap right at a tier boundary.
                    1f - ((kbps - K_BR1).toFloat() / (K_BR2 - K_BR1).toFloat())
                }
            }
            val bitrateCompensationActive = bitrateCompensationScale > 0.001f

            // The limiter is normally armed by Premium Sound's own fade
            // (_ap3), but bitrate compensation and Bass Boost can each add
            // gain independent of Premium Sound being on at all — so this
            // path arms the limiter too whenever ANY gain-adding effect is
            // active, regardless of which one. setLimiterEnabled(true) is
            // idempotent (repeated true/true calls are harmless), so this
            // never fights with _ap3's own arming.
            if ((bitrateCompensationActive || bassBoost) && lastAppliedLimiterEnabled != true) {
                _lm2(true)
                lastAppliedLimiterEnabled = true
            }

            if (!hasCustomCurve && !bassBoost && !premiumActive && !bitrateCompensationActive) {
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
                    K_P4[0]
                } else {
                    val fraction = bandIndex.toFloat() / (bandCount - 1).toFloat()
                    val srcIndex = (fraction * (K_P4.size - 1)).toInt()
                        .coerceIn(0, K_P4.size - 1)
                    K_P4[srcIndex]
                }
                return (base * intensityFraction).toInt()
            }

            fun bitrateCompensationGainFor(bandIndex: Int): Int {
                if (!bitrateCompensationActive) return 0
                val base = if (bandCount <= 1) {
                    K_BR3[0]
                } else {
                    val fraction = bandIndex.toFloat() / (bandCount - 1).toFloat()
                    val srcIndex = (fraction * (K_BR3.size - 1)).toInt()
                        .coerceIn(0, K_BR3.size - 1)
                    K_BR3[srcIndex]
                }
                // Also scaled by the fade fraction when Premium Sound is
                // transitioning/off, so a bare Bass-Boost-only or
                // no-effects-at-all session still gets a gentle standalone
                // tilt at full scale rather than riding Premium Sound's
                // fade — bitrate compensation is its own independent thing,
                // only reduced by the taper computed above, not by
                // intensityFraction.
                return (base * bitrateCompensationScale).toInt()
            }

            var rejectedBands = 0
            var unchangedBands = 0
            val newAppliedGains = IntArray(bandCount)
            for (i in 0 until bandCount) {
                var gain = if (volNorm && !hasCustomCurve) 0 else savedBands[i]

                if (bassBoost) {
                    if (i == 0) gain += BASS_BOOST_SUB_BASS_EXTRA_MB
                    if (i == 1) gain += BASS_BOOST_BASS_EXTRA_MB
                }

                gain += premiumGainFor(i)
                gain += bitrateCompensationGainFor(i)

                // Explicit combined ceiling FIRST (catches multi-source
                // stacking regardless of what this device's own range
                // allows), THEN clamp to the device's actual reported
                // range (some devices report a range narrower than the
                // ceiling, which must still win).
                gain = gain.coerceIn(K_CAP_NEG, K_CAP_POS)
                gain = gain.coerceIn(minMb, maxMb)

                if (lastAppliedEqGains.getOrNull(i) == gain) {
                    unchangedBands++
                    newAppliedGains[i] = gain
                    continue
                }

                try {
                    eq.setBandLevel(i.toShort(), gain.toShort())
                    newAppliedGains[i] = gain
                } catch (e: Exception) {
                    rejectedBands++
                    newAppliedGains[i] = lastAppliedEqGains.getOrNull(i) ?: gain
                    Log.w(TAG, "Band $i setBandLevel($gain) rejected ($e) — skipping band")
                }
            }
            lastAppliedEqGains = newAppliedGains.toList()

            if (rejectedBands > 0 && rejectedBands + unchangedBands == bandCount) {
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
        "limiterActive" to (limiterSupported && limiterHealthy),
        "outputRoute" to _ro1().name,
    )

    fun dispose() {
        _fd1()
        player.removeListener(sessionIdListener)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
            }
        } catch (_: Exception) {}
        _rl1()
    }
}
